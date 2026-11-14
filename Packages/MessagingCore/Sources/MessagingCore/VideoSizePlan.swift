import Foundation

/// The size, frame rate and bitrates a video is re-encoded at so the file fits a byte limit. Quality is judged in
/// bits per pixel per frame: a rung is good at 0.07, still acceptable down to 0.035, and capped at 0.12 so a short
/// clip is not inflated to the limit.
public struct VideoSizePlan: Sendable, Equatable {
    public struct Source: Sendable, Equatable {
        /// Display size, after the track's rotation.
        public var width: Int
        public var height: Int
        /// Zero when the track does not say.
        public var frameRate: Double
        public var seconds: Double
        /// The video track's own bitrate, when the container records it.
        public var videoBitRate: Int?
        public var hasAudio: Bool

        public init(width: Int, height: Int, frameRate: Double, seconds: Double, videoBitRate: Int? = nil, hasAudio: Bool = true) {
            self.width = width; self.height = height; self.frameRate = frameRate; self.seconds = seconds
            self.videoBitRate = videoBitRate; self.hasAudio = hasAudio
        }
    }

    public enum Outcome: Sendable, Equatable {
        case encode(VideoSizePlan)
        /// Only the first `maximumSeconds` fit at an acceptable quality.
        case tooLong(maximumSeconds: Int)
        /// Not even a second fits.
        case tooLarge
    }

    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let videoBitRate: Int
    public let audioBitRate: Int
    public let seconds: Double

    public var plannedBytes: Int { Int(Double(videoBitRate + audioBitRate) * seconds / 8) }

    static let shortEdges = [1080, 720, 540, 480, 360]
    static let goodBitsPerPixel = 0.07
    static let acceptableBitsPerPixel = 0.035
    static let longestClipBitsPerPixel = 0.05
    static let ceilingBitsPerPixel = 0.12
    static let budgetShare = 0.95
    static let retryShare = 0.9
    static let audioBitRate = 96_000
    static let lowAudioBitRate = 64_000
    static let lowAudioBelow = 600_000
    static let baseFrameRate = 30.0
    static let highestFrameRate = 60.0

    /// The plan for the whole source, or how much of it fits.
    public static func plan(_ source: Source, limit: Int) -> Outcome {
        let seconds = max(source.seconds, 0.001)
        let total = Int(Double(limit) * budgetShare * 8 / seconds)
        let audio = audioBitRate(total: total, hasAudio: source.hasAudio)
        if let plan = plan(source, videoBitRate: total - audio, audioBitRate: audio) { return .encode(plan) }
        let longest = longestSeconds(source, limit: limit)
        return longest >= 1 ? .tooLong(maximumSeconds: longest) : .tooLarge
    }

    /// The second attempt after `plan` came out at `actualBytes`, over `limit`; nil when nothing acceptable remains.
    public static func retry(_ plan: VideoSizePlan, source: Source, limit: Int, actualBytes: Int) -> VideoSizePlan? {
        guard actualBytes > 0 else { return nil }
        let video = Int(Double(plan.videoBitRate) * Double(limit) / Double(actualBytes) * retryShare)
        return self.plan(source, videoBitRate: video, audioBitRate: plan.audioBitRate)
    }

    static func audioBitRate(total: Int, hasAudio: Bool) -> Int {
        guard hasAudio else { return 0 }
        return total < lowAudioBelow ? lowAudioBitRate : audioBitRate
    }

    // Rungs are judged at 30 frames a second, or the source's own rate below that, which is never changed.
    static func baseRate(_ source: Source) -> Double {
        source.frameRate > 0 ? min(source.frameRate, baseFrameRate) : baseFrameRate
    }

    static func plan(_ source: Source, videoBitRate video: Int, audioBitRate audio: Int) -> VideoSizePlan? {
        guard video > 0 else { return nil }
        let base = baseRate(source)
        let rungs = sizes(source)
        let chosen = rungs.first { bitsPerPixel(video, $0, base) >= goodBitsPerPixel }
            ?? rungs.last.flatMap { bitsPerPixel(video, $0, base) >= acceptableBitsPerPixel ? $0 : nil }
        guard let size = chosen else { return nil }
        // A rate above 30 survives only when the rung picked at 30 still looks good at it.
        var rate = base
        if source.frameRate > baseFrameRate {
            let high = min(source.frameRate, highestFrameRate)
            if bitsPerPixel(video, size, high) >= goodBitsPerPixel { rate = high }
        }
        var capped = min(video, Int(ceilingBitsPerPixel * Double(size.width * size.height) * rate))
        if let own = source.videoBitRate, own > 0 { capped = min(capped, own) }
        return VideoSizePlan(width: size.width, height: size.height, frameRate: rate, videoBitRate: capped, audioBitRate: audio,
                             seconds: source.seconds)
    }

    // The longest stretch that fits at the smallest rung, 30 frames a second and 0.05 bits per pixel.
    static func longestSeconds(_ source: Source, limit: Int) -> Int {
        guard let size = sizes(source).last else { return 0 }
        let video = Int((longestClipBitsPerPixel * Double(size.width * size.height) * baseRate(source)).rounded(.up))
        let audio = audioBitRate(total: video + lowAudioBitRate, hasAudio: source.hasAudio)
        let seconds = Int(Double(limit) * budgetShare * 8 / Double(video + audio))
        return min(seconds, Int(source.seconds.rounded(.down)))
    }

    static func bitsPerPixel(_ bitRate: Int, _ size: (width: Int, height: Int), _ rate: Double) -> Double {
        Double(bitRate) / (Double(size.width * size.height) * rate)
    }

    // Largest first, never above the source: a source between rungs keeps its own size as the top rung.
    static func sizes(_ source: Source) -> [(width: Int, height: Int)] {
        let short = min(source.width, source.height), long = max(source.width, source.height)
        guard short > 0 else { return [] }
        var edges = shortEdges.filter { $0 < short }
        edges.insert(min(short, shortEdges[0]), at: 0)
        return edges.map { edge in
            let scaled = even(Double(long) * Double(edge) / Double(short))
            let side = even(Double(edge))
            return source.width >= source.height ? (scaled, side) : (side, scaled)
        }
    }

    static func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
}
