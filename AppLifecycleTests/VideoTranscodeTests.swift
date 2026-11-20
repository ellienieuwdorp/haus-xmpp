import AVFoundation
import CoreMedia
import MessagingCore
import XCTest
@testable import HausXMPP

// Source clips are uncompressed picture and sound written straight into the movie, so making one needs no encoder,
// which the simulator lacks for Motion JPEG and ProRes and can fail to start for H.264. The picture is a ramp any
// encoder fits easily; the checks hold each encode to its plan's bounds, never to one machine's exact output.
@MainActor final class VideoTranscodeTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "video-transcode-\(UUID())", directoryHint: .isDirectory)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    // At 60 frames a second the rung would fall below good quality, so the plan keeps 30, and the composition has to
    // drop every other frame.
    func testAnEncodeIsH264AndAACInMP4WithinItsPlan() async throws {
        let clip = try await makeClip(width: 640, height: 360, frameRate: 60, seconds: 2)
        let limit = 210_000
        let plan = try await Self.plan(clip, limit: limit)
        XCTAssertEqual(plan.frameRate, 30)
        let prepared = try await AttachmentPreparer.prepareVideo(clip, name: "clip.mov", limit: limit)
        let output = try await describe(prepared)
        XCTAssertLessThanOrEqual(prepared.data.count, limit)
        XCTAssertEqual(output.codec, kCMVideoCodecType_H264)
        XCTAssertEqual(output.audioCodec, kAudioFormatMPEG4AAC)
        XCTAssertLessThanOrEqual(output.size.height, CGFloat(plan.height))
        XCTAssertEqual(output.size.width / output.size.height, 16 / 9, accuracy: 0.01)
        XCTAssertEqual(output.frameRate, Float(plan.frameRate), accuracy: 0.5)
        XCTAssertEqual(output.seconds, 2, accuracy: 0.1)
        XCTAssertEqual(prepared.mediaType, "video/mp4")
        XCTAssertEqual(prepared.name, "clip.mp4")
        XCTAssertEqual(prepared.width.map(CGFloat.init), output.size.width)
        XCTAssertEqual(prepared.height.map(CGFloat.init), output.size.height)
    }

    // The limit is many times the rung's ceiling, so no encoder's overshoot brings in the retry and its lower rung.
    func testARotatedRecordingComesOutUprightAtItsDisplaySize() async throws {
        let clip = try await makeClip(width: 640, height: 360, frameRate: 30, seconds: 1, transform: CGAffineTransform(rotationAngle: .pi / 2))
        let limit = 10_000_000
        let plan = try await Self.plan(clip, limit: limit)
        XCTAssertEqual([plan.width, plan.height], [360, 640])
        let prepared = try await AttachmentPreparer.prepareVideo(clip, name: "clip.mov", limit: limit)
        let output = try await describe(prepared)
        XCTAssertEqual(output.size, CGSize(width: 360, height: 640))
        XCTAssertEqual(output.transform, .identity, "the frames themselves are upright")
        XCTAssertEqual(prepared.width, 360)
        XCTAssertEqual(prepared.height, 640)
    }

    func testAStalledEncodeEndsAtItsDeadlineAndLeavesNoFileBehind() async throws {
        let clip = try await makeClip(width: 640, height: 360, frameRate: 30, seconds: 1)
        let before = try leftovers()
        do {
            _ = try await AttachmentPreparer.prepareVideo(clip, name: "clip.mov", limit: 1_000_000, clock: ExpiredClock())
            XCTFail("the deadline has passed before the first frame")
        } catch {
            XCTAssertEqual(error as? AttachmentPreparer.Failure, .unreadable)
        }
        XCTAssertEqual(try leftovers(), before)
    }

    func testCancellingStopsTheEncodeAndLeavesNoFileBehind() async throws {
        let clip = try await makeClip(width: 640, height: 360, frameRate: 30, seconds: 2)
        let before = try leftovers()
        // A second attempt would wait on the clock again.
        let started = XCTestExpectation(description: "encoding")
        started.assertForOverFulfill = false
        let task = Task { try await AttachmentPreparer.prepareVideo(clip, name: "clip.mov", limit: 1_000_000, clock: SignallingClock(started: started)) }
        await fulfillment(of: [started], timeout: 30)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled encode delivers nothing")
        } catch {
            XCTAssertNotEqual(error as? AttachmentPreparer.Failure, .tooLarge(limit: 1_000_000), "stopped, not finished")
        }
        XCTAssertEqual(try leftovers(), before)
    }

    func testAPhotoStepsDownUntilItFits() throws {
        let noise = try XCTUnwrap(noiseImage(width: 2200, height: 1400))
        let full = try AttachmentPreparer.prepareImage(noise, name: "IMG_1.HEIC", limit: .max)
        XCTAssertEqual(full.width, 2048)
        let squeezed = try AttachmentPreparer.prepareImage(noise, name: "IMG_1.HEIC", limit: full.data.count / 2)
        XCTAssertLessThanOrEqual(squeezed.data.count, full.data.count / 2)
        XCTAssertLessThan(try XCTUnwrap(squeezed.width), 2048, "quality alone was not enough")
        XCTAssertEqual(squeezed.name, "IMG_1.jpg")
        XCTAssertThrowsError(try AttachmentPreparer.prepareImage(noise, name: "IMG_1.HEIC", limit: 1_000)) { error in
            XCTAssertEqual(error as? AttachmentPreparer.Failure, .tooLarge(limit: 1_000))
        }
    }

    func testShareCardStatesFollowTheFailure() {
        XCTAssertEqual(ShareRules.Preparation(.failure(AttachmentPreparer.Failure.tooLong(seconds: 75))).offer?.length, "1:15")
        XCTAssertEqual(ShareRules.Preparation(.failure(AttachmentPreparer.Failure.tooLarge(limit: 10))), .failed("Too large to send"))
        XCTAssertEqual(ShareRules.Preparation(.failure(AttachmentPreparer.Failure.unreadable)), .failed("Can't be read"))
        let ready = PreparedAttachment(data: Data(count: 12), name: "a.jpg", mediaType: "image/jpeg", width: 1, height: 1)
        XCTAssertEqual(ShareRules.Preparation(.success(ready)), .ready(size: 12))
        XCTAssertFalse(AttachmentPreparer.Failure.tooLarge(limit: 10 << 20).localizedDescription.contains("server"))
        let shortening = AttachmentPreparer.Shortening(seconds: 220)
        XCTAssertEqual(shortening.message, "This video is too long to send at an acceptable quality. Send the first 3:40?")
        XCTAssertEqual(shortening.confirmation, "Send First 3:40")
    }

    // MARK: Helpers

    private struct Output {
        let codec: FourCharCode
        let audioCodec: AudioFormatID?
        let size: CGSize
        let transform: CGAffineTransform
        let frameRate: Float
        let seconds: Double
    }

    private struct Unplanned: Error {
        let outcome: VideoSizePlan.Outcome
    }

    private func describe(_ prepared: PreparedAttachment) async throws -> Output {
        let url = folder.appending(path: UUID().uuidString + ".mp4")
        try prepared.data.write(to: url)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let (formats, size, transform, rate) = try await video.load(.formatDescriptions, .naturalSize, .preferredTransform, .nominalFrameRate)
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let audioFormat = try await audio?.load(.formatDescriptions).first
        return Output(codec: CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)),
                      audioCodec: audioFormat.map { CMFormatDescriptionGetMediaSubType($0) }, size: size, transform: transform,
                      frameRate: rate, seconds: try await asset.load(.duration).seconds)
    }

    private func record(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = text
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private nonisolated static func plan(_ clip: URL, limit: Int) async throws -> VideoSizePlan {
        let source = try await VideoTranscoder.source(of: AVURLAsset(url: clip), keepingFirst: nil)
        let outcome = VideoSizePlan.plan(source, limit: limit)
        guard case .encode(let plan) = outcome else { throw Unplanned(outcome: outcome) }
        return plan
    }

    private func leftovers() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasSuffix(".mp4") })
    }

    private func noiseImage(width: Int, height: Int) -> CGImageSource? {
        guard let provider = CGDataProvider(data: Data(noiseBytes(width * height * 4)) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let jpeg = AttachmentPreparer.jpegData(image, quality: 1) else { return nil }
        return CGImageSourceCreateWithData(jpeg as CFData, nil)
    }

    private func makeClip(width: Int, height: Int, frameRate: Int, seconds: Int, transform: CGAffineTransform = .identity) async throws -> URL {
        let url = folder.appending(path: UUID().uuidString + ".mov")
        let clip = try ClipWriter(url: url, width: width, height: height, frameRate: frameRate, seconds: seconds, transform: transform)
        // Not owned by the test case, so a writer still running after a missed deadline fulfils them harmlessly.
        let written = [XCTestExpectation(description: "frames"), XCTestExpectation(description: "tone")]
        try clip.start(written)
        guard await XCTWaiter().fulfillment(of: written, timeout: 60) == .completed else { throw ClipWriter.Stalled() }
        try await clip.finish()
        return url
    }
}

// Each input is driven from its own serial queue only, and finishing waits until both have marked themselves done.
private final class ClipWriter: @unchecked Sendable {
    struct Stalled: Error {}

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let frames: ClipFrames
    private let tone: ClipTone

    init(url: URL, width: Int, height: Int, frameRate: Int, seconds: Int, transform: CGAffineTransform) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        frames = try ClipFrames(width: width, height: height, count: seconds * frameRate, rate: frameRate)
        tone = try ClipTone(seconds: seconds)
        // No output settings: the samples go into the file as they are, so no encoder is involved.
        video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: frames.format)
        video.expectsMediaDataInRealTime = false
        video.transform = transform
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: tone.format)
        audio.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(audio)
    }

    func start(_ written: [XCTestExpectation]) throws {
        // A writer that cannot start ignores the session, and appending to it then raises and ends the test process.
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        video.requestMediaDataWhenReady(on: DispatchQueue(label: "clip.video")) { [self] in
            while video.isReadyForMoreMediaData {
                guard let buffer = frames.next(), video.append(buffer) else { video.markAsFinished(); written[0].fulfill(); return }
            }
        }
        audio.requestMediaDataWhenReady(on: DispatchQueue(label: "clip.audio")) { [self] in
            while audio.isReadyForMoreMediaData {
                guard let buffer = tone.next(), audio.append(buffer) else { audio.markAsFinished(); written[1].fulfill(); return }
            }
        }
    }

    func finish() async throws {
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}

// Uncompressed '2vuy' frames, two bytes a pixel with chroma before each luma byte. Luma is a triangle ramp that slides
// diagonally a few pixels a frame; chroma is neutral, so any even byte offset into the line is a valid row.
private final class ClipFrames {
    static let step = 4
    let format: CMVideoFormatDescription
    let width: Int
    let height: Int
    let count: Int
    let rate: Int
    let line: [UInt8]
    var index = 0

    init(width: Int, height: Int, count: Int, rate: Int) throws {
        self.width = width; self.height = height; self.count = count; self.rate = rate
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMPixelFormat_422YpCbCr8, width: Int32(width), height: Int32(height),
                                       extensions: [kCMFormatDescriptionExtension_BytesPerRow: width * 2] as CFDictionary, formatDescriptionOut: &format)
        self.format = try XCTUnwrap(format)
        line = (0..<(width + height + Self.step * count)).flatMap { offset -> [UInt8] in
            let phase = offset % 440
            return [128, UInt8(16 + (phase < 220 ? phase : 440 - phase))]
        }
    }

    func next() -> CMSampleBuffer? {
        guard index < count else { return nil }
        defer { index += 1 }
        let rowBytes = width * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: rowBytes * height, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: rowBytes * height, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        var pointer: UnsafeMutablePointer<CChar>?
        guard let block, CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        line.withUnsafeBytes { source in
            guard let start = source.baseAddress else { return }
            for row in 0..<height {
                UnsafeMutableRawPointer(pointer + row * rowBytes).copyMemory(from: start + 2 * (row + index * Self.step), byteCount: rowBytes)
            }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(rate)), decodeTimeStamp: .invalid)
        var size = rowBytes * height
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                  sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer)
        return buffer
    }
}

// A fixed xorshift sequence: fast enough for megabytes in a Debug build, and the same photo every run.
private func noiseBytes(_ count: Int) -> [UInt8] {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    var bytes = [UInt8](repeating: 0, count: count)
    bytes.withUnsafeMutableBytes { raw in
        let words = raw.bindMemory(to: UInt64.self)
        for index in words.indices {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            words[index] = state
        }
    }
    return bytes
}

private final class ClipTone {
    static let sampleRate = 44_100
    static let chunk = 4_410
    let total: Int
    let format: CMAudioFormatDescription
    var written = 0

    init(seconds: Int) throws {
        total = seconds * Self.sampleRate
        var description = AudioStreamBasicDescription(mSampleRate: Double(Self.sampleRate), mFormatID: kAudioFormatLinearPCM,
                                                      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                                      mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        self.format = try XCTUnwrap(format)
    }

    func next() -> CMSampleBuffer? {
        let count = min(Self.chunk, total - written)
        guard count > 0 else { return nil }
        var samples = (0..<count).map { Int16(sin(Double(written + $0) * 2 * .pi * 440 / Double(Self.sampleRate)) * 8_000) }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: count * 2, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { return nil }
        CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 2)
        var buffer: CMSampleBuffer?
        let start = CMTime(value: CMTimeValue(written), timescale: CMTimeScale(Self.sampleRate))
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
                                                             presentationTimeStamp: start, packetDescriptions: nil, sampleBufferOut: &buffer)
        written += count
        return buffer
    }
}

private struct OffsetInstant: InstantProtocol {
    var offset: Duration
    func advanced(by duration: Duration) -> OffsetInstant { OffsetInstant(offset: offset + duration) }
    func duration(to other: OffsetInstant) -> Duration { other.offset - offset }
    static func < (lhs: OffsetInstant, rhs: OffsetInstant) -> Bool { lhs.offset < rhs.offset }
}

// Every deadline has already passed, so the first sleep returns at once.
private struct ExpiredClock: Clock {
    var now: OffsetInstant { OffsetInstant(offset: .zero) }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: OffsetInstant, tolerance: Duration?) async throws {
        await Task.yield()
        try Task.checkCancellation()
    }
}

// Says when the encode starts waiting on its deadline, which then never comes; only cancellation ends the sleep.
private struct SignallingClock: Clock {
    let started: XCTestExpectation
    var now: OffsetInstant { OffsetInstant(offset: .zero) }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: OffsetInstant, tolerance: Duration?) async throws {
        started.fulfill()
        let (never, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        for await _ in never { continue }
        try Task.checkCancellation()
    }
}
