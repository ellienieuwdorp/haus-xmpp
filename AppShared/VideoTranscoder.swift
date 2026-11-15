import AVFoundation
import CoreMedia
import Foundation
import MessagingCore

// H.264 and AAC in MP4: web and Windows receivers cannot count on HEVC. A composition built from the asset's own
// properties applies rotation and slow-motion timing and tone-maps HDR to SDR Rec. 709. A fresh encode carries none
// of the source's metadata, location included.
enum VideoTranscoder {
    struct TimedOut: Error {}

    static let keyFrameSeconds = 2.0

    static func source(of asset: AVAsset, keepingFirst first: Int?) async throws -> VideoSizePlan.Source {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AttachmentPreparer.Failure.unreadable }
        let (size, transform, rate, dataRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate)
        let duration = try await asset.load(.duration).seconds
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        let display = CGRect(origin: .zero, size: size).applying(transform)
        let seconds = min(duration, first.map(Double.init) ?? .infinity)
        guard seconds.isFinite, seconds > 0, abs(display.width) >= 2, abs(display.height) >= 2 else { throw AttachmentPreparer.Failure.unreadable }
        return VideoSizePlan.Source(width: Int(abs(display.width).rounded()), height: Int(abs(display.height).rounded()), frameRate: Double(rate),
                                    seconds: seconds, videoBitRate: dataRate > 0 ? Int(dataRate) : nil, hasAudio: hasAudio)
    }

    // The deadline bounds a stalled decoder or encoder; reading and writing stop as soon as the task is cancelled.
    static func transcode(_ asset: AVAsset, plan: VideoSizePlan, keepingFirst first: Int?, to url: URL,
                          deadline: Duration, clock: any Clock<Duration> = ContinuousClock()) async throws {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let composition = try await self.composition(for: asset, plan: plan)
        let reader = try AVAssetReader(asset: asset)
        if let first { reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: Double(first), preferredTimescale: 600)) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(plan))
        videoInput.expectsMediaDataInRealTime = false
        var pumps = [Pump(provider: reader.outputProvider(for: videoOutput), receiver: writer.inputReceiver(for: videoInput))]
        if !audioTracks.isEmpty, plan.audioBitRate > 0 {
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: decodedAudio)
            audioOutput.alwaysCopiesSampleData = false
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings(plan))
            audioInput.expectsMediaDataInRealTime = false
            pumps.append(Pump(provider: reader.outputProvider(for: audioOutput), receiver: writer.inputReceiver(for: audioInput)))
        }

        let session = Session(reader: reader, writer: writer)
        // The providers and receivers end on task cancellation themselves; cancelling the reader from another thread
        // while a provider waits for a sample crashes AVFoundation, so the reader and writer stop only once both
        // pumps have returned. A writer that fails to start stops the reader started before it.
        do {
            try reader.start()
            try writer.start()
            writer.startSession(atSourceTime: .zero)
            try await withThrowingTaskGroup(of: Bool.self) { group in
                for pump in pumps { group.addTask { try await pump.run(); return true } }
                group.addTask { try await clock.sleep(for: deadline); return false }
                var finished = 0
                while let done = try await group.next() {
                    guard done else { throw TimedOut() }
                    finished += 1
                    if finished == pumps.count { group.cancelAll(); break }
                }
            }
            try Task.checkCancellation()
            try session.checkReader()
            try await session.finish()
        } catch {
            session.cancel()
            throw error
        }
    }

    static func composition(for asset: AVAsset, plan: VideoSizePlan) async throws -> AVVideoComposition {
        var configuration = try await AVVideoComposition.Configuration(for: asset)
        let rendered = configuration.renderSize
        guard rendered.width > 0, rendered.height > 0 else { throw AttachmentPreparer.Failure.unreadable }
        let scale = CGAffineTransform(scaleX: CGFloat(plan.width) / rendered.width, y: CGFloat(plan.height) / rendered.height)
        configuration.instructions = configuration.instructions.map { instruction in
            guard let instruction = instruction as? AVVideoCompositionInstruction else { return instruction }
            let start = instruction.timeRange.start
            let layers = instruction.layerInstructions.map { layer in
                var scaled = AVVideoCompositionLayerInstruction.Configuration(trackID: layer.trackID)
                if let ramp = layer.transformRamp(at: start), ramp.start != ramp.end {
                    scaled.addTransformRamp(.init(timeRange: ramp.timeRange, start: ramp.start.concatenating(scale), end: ramp.end.concatenating(scale)))
                } else {
                    scaled.setTransform((layer.transformRamp(at: start)?.start ?? .identity).concatenating(scale), at: start)
                }
                return AVVideoCompositionLayerInstruction(configuration: scaled)
            }
            return AVVideoCompositionInstruction(configuration: .init(layerInstructions: layers, timeRange: instruction.timeRange))
        }
        configuration.renderSize = CGSize(width: plan.width, height: plan.height)
        // Built from the asset, the composition times its frames by the source track, which would keep every frame.
        configuration.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        configuration.frameDuration = CMTime(value: 1000, timescale: CMTimeScale((plan.frameRate * 1000).rounded()))
        configuration.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        configuration.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        configuration.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return AVVideoComposition(configuration: configuration)
    }

    static func videoSettings(_ plan: VideoSizePlan) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: plan.videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoExpectedSourceFrameRateKey: plan.frameRate,
                AVVideoMaxKeyFrameIntervalKey: Int((plan.frameRate * keyFrameSeconds).rounded()),
                AVVideoMaxKeyFrameIntervalDurationKey: keyFrameSeconds,
            ] as [String: Any],
        ]
    }

    // Mixed down to stereo 44.1 kHz, which every AAC-LC decoder plays.
    static var decodedAudio: [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
         AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    }

    static func audioSettings(_ plan: VideoSizePlan) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: plan.audioBitRate]
    }
}

// One track's samples from the reader into the writer.
private struct Pump: @unchecked Sendable {
    let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
    let receiver: AVAssetWriterInput.SampleBufferReceiver

    func run() async throws {
        while let sample = try await provider.next() {
            try Task.checkCancellation()
            try await receiver.append(sample)
        }
        receiver.finish()
    }
}

private final class Session {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter

    init(reader: AVAssetReader, writer: AVAssetWriter) { self.reader = reader; self.writer = writer }

    func checkReader() throws {
        guard reader.status == .completed else { throw reader.error ?? AttachmentPreparer.Failure.unreadable }
    }

    func finish() async throws {
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? AttachmentPreparer.Failure.unreadable }
    }

    func cancel() {
        reader.cancelReading()
        if writer.status == .writing { writer.cancelWriting() }
    }
}
