import AVFoundation
import CoreMedia
import MessagingCore
import XCTest
@testable import HausXMPP

// Clips are generated here, frames of noise over a gradient with a tone, so nothing binary is checked in and the
// encoder has real work to fit.
@MainActor final class VideoTranscodeTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "video-transcode-\(UUID())", directoryHint: .isDirectory)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSixtyFramesThatCannotKeepTheirQualityDropToThirtyAtTheRungThatFits() async throws {
        let clip = try await makeClip(width: 1280, height: 720, frameRate: 60, seconds: 3)
        let limit = 500_000
        let prepared = try await AttachmentPreparer.prepareVideo(clip, name: "clip.mov", limit: limit)
        let output = try await describe(prepared)
        XCTAssertLessThanOrEqual(prepared.data.count, limit)
        XCTAssertEqual(output.codec, kCMVideoCodecType_H264)
        XCTAssertEqual(output.audioCodec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(output.size, CGSize(width: 960, height: 540))
        XCTAssertEqual(output.frameRate, 30, accuracy: 0.5)
        XCTAssertEqual(output.seconds, 3, accuracy: 0.1)
        XCTAssertEqual(prepared.mediaType, "video/mp4")
        XCTAssertEqual(prepared.name, "clip.mp4")
        XCTAssertEqual(prepared.width, 960)
        XCTAssertEqual(prepared.height, 540)
        record("540p30: planned \(try await Self.planned(clip, limit: limit)) bytes, wrote \(prepared.data.count) of \(limit)")
    }

    func testSixtyFramesThatStillLookGoodAtSixtyKeepThem() async throws {
        let clip = try await makeClip(width: 1280, height: 720, frameRate: 60, seconds: 3)
        let limit = 2_000_000
        let prepared = try await AttachmentPreparer.prepareVideo(clip, name: "clip.mov", limit: limit)
        let output = try await describe(prepared)
        XCTAssertLessThanOrEqual(prepared.data.count, limit)
        XCTAssertEqual(output.size, CGSize(width: 1280, height: 720))
        XCTAssertEqual(output.frameRate, 60, accuracy: 0.5)
        record("720p60: planned \(try await Self.planned(clip, limit: limit)) bytes, wrote \(prepared.data.count) of \(limit)")
    }

    func testARotatedRecordingComesOutUprightAtItsDisplaySize() async throws {
        let clip = try await makeClip(width: 1280, height: 720, frameRate: 30, seconds: 2, transform: CGAffineTransform(rotationAngle: .pi / 2))
        let prepared = try await AttachmentPreparer.prepareVideo(clip, name: "clip.mov", limit: 400_000)
        let output = try await describe(prepared)
        XCTAssertEqual(output.size, CGSize(width: 540, height: 960))
        XCTAssertEqual(output.transform, .identity, "the frames themselves are upright")
        XCTAssertEqual(prepared.width, 540)
        XCTAssertEqual(prepared.height, 960)
    }

    func testAClipTooLongForTheLimitOffersItsStartAndSendsJustThat() async throws {
        let clip = try await makeClip(width: 1280, height: 720, frameRate: 30, seconds: 6)
        let limit = 100_000
        do {
            _ = try await AttachmentPreparer.prepareVideo(clip, name: "clip.mov", limit: limit)
            XCTFail("six seconds do not fit at an acceptable quality")
        } catch AttachmentPreparer.Failure.tooLong(let seconds) {
            XCTAssertEqual(seconds, 1)
        }
        let start = try await AttachmentPreparer.prepareVideo(clip, name: "clip.mov", limit: limit, keepingFirst: 1)
        let output = try await describe(start)
        XCTAssertLessThanOrEqual(start.data.count, limit)
        XCTAssertEqual(output.seconds, 1, accuracy: 0.1)
        XCTAssertEqual(output.size, CGSize(width: 640, height: 360))
        let shortening = AttachmentPreparer.Shortening(seconds: 220)
        XCTAssertEqual(shortening.message, "This video is too long to send at an acceptable quality. Send the first 3:40?")
        XCTAssertEqual(shortening.confirmation, "Send First 3:40")
    }

    func testAPhotoStepsDownUntilItFits() throws {
        let noise = try XCTUnwrap(noiseImage(width: 3000, height: 2000))
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

    func testAStalledEncodeEndsAtItsDeadlineAndLeavesNoFileBehind() async throws {
        let clip = try await makeClip(width: 1280, height: 720, frameRate: 30, seconds: 3)
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
        let clip = try await makeClip(width: 1280, height: 720, frameRate: 30, seconds: 6)
        let before = try leftovers()
        let started = expectation(description: "encoding")
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

    func testShareCardStatesFollowTheFailure() {
        XCTAssertEqual(ShareRules.Preparation(.failure(AttachmentPreparer.Failure.tooLong(seconds: 75))).offer?.length, "1:15")
        XCTAssertEqual(ShareRules.Preparation(.failure(AttachmentPreparer.Failure.tooLarge(limit: 10))), .failed("Too large to send"))
        XCTAssertEqual(ShareRules.Preparation(.failure(AttachmentPreparer.Failure.unreadable)), .failed("Can't be read"))
        let ready = PreparedAttachment(data: Data(count: 12), name: "a.jpg", mediaType: "image/jpeg", width: 1, height: 1)
        XCTAssertEqual(ShareRules.Preparation(.success(ready)), .ready(size: 12))
        XCTAssertFalse(AttachmentPreparer.Failure.tooLarge(limit: 10 << 20).localizedDescription.contains("server"))
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

    private nonisolated static func planned(_ clip: URL, limit: Int) async throws -> Int {
        let source = try await VideoTranscoder.source(of: AVURLAsset(url: clip), keepingFirst: nil)
        guard case .encode(let plan) = VideoSizePlan.plan(source, limit: limit) else { return 0 }
        return plan.plannedBytes
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

    private func makeClip(width: Int, height: Int, frameRate: Int, seconds: Double, transform: CGAffineTransform = .identity) async throws -> URL {
        let url = folder.appending(path: UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000],
        ])
        video.expectsMediaDataInRealTime = false
        video.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
        ])
        audio.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(audio)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = ClipFrames(adaptor: adaptor, width: width, height: height, count: Int(seconds * Double(frameRate)), rate: frameRate)
        let tone = try ClipTone(seconds: seconds)
        let written = [expectation(description: "frames"), expectation(description: "tone")]
        video.requestMediaDataWhenReady(on: DispatchQueue(label: "clip.video")) {
            while video.isReadyForMoreMediaData {
                guard frames.appendNext() else { video.markAsFinished(); written[0].fulfill(); return }
            }
        }
        audio.requestMediaDataWhenReady(on: DispatchQueue(label: "clip.audio")) {
            while audio.isReadyForMoreMediaData {
                guard let buffer = tone.next() else { audio.markAsFinished(); written[1].fulfill(); return }
                audio.append(buffer)
            }
        }
        await fulfillment(of: written, timeout: 60)
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
        return url
    }
}

// Each source is driven from its own serial queue only.
private final class ClipFrames: @unchecked Sendable {
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let count: Int
    let rate: Int
    // Luma noise over a gradient, made once; each frame reads it from a shifted offset, so the picture keeps moving.
    let luma: [UInt8]
    var index = 0

    init(adaptor: AVAssetWriterInputPixelBufferAdaptor, width: Int, height: Int, count: Int, rate: Int) {
        self.adaptor = adaptor; self.count = count; self.rate = rate
        let noise = noiseBytes(width * height + 64 * count)
        luma = noise.enumerated().map { offset, value in UInt8(16 + (offset % width) * 160 / width + Int(value % 32)) }
    }

    func appendNext() -> Bool {
        guard index < count, let pool = adaptor.pixelBufferPool else { return false }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return false }
        CVPixelBufferLockBaseAddress(buffer, [])
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        luma.withUnsafeBufferPointer { source in
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                    let destination = base + row * rowBytes
                    if plane == 0, let start = source.baseAddress {
                        destination.copyMemory(from: start + index * 64 + row * width, byteCount: width)
                    } else {
                        destination.initializeMemory(as: UInt8.self, repeating: 128, count: rowBytes)
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        defer { index += 1 }
        return adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(rate)))
    }
}

// A fixed xorshift sequence: fast enough for megabytes in a Debug build, and the same clip every run.
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

private final class ClipTone: @unchecked Sendable {
    static let sampleRate = 44_100
    static let chunk = 4_410
    let total: Int
    let format: CMAudioFormatDescription
    var written = 0

    init(seconds: Double) throws {
        total = Int(seconds * Double(Self.sampleRate))
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
