import Testing
@testable import MessagingCore

struct VideoSizePlanTests {
    static let mebibyte = 1 << 20
    static let uhd = VideoSizePlan.Source(width: 3840, height: 2160, frameRate: 30, seconds: 0)

    private func plan(_ source: VideoSizePlan.Source, seconds: Double, limit: Int) -> VideoSizePlan.Outcome {
        var source = source
        source.seconds = seconds
        return VideoSizePlan.plan(source, limit: limit)
    }

    private func encoded(_ outcome: VideoSizePlan.Outcome) -> VideoSizePlan? {
        if case .encode(let plan) = outcome { plan } else { nil }
    }

    @Test(arguments: [
        (10, 10.0, 1920, 1080), (10, 60, 960, 540), (10, 120, 640, 360),
        (32, 10, 1920, 1080), (32, 60, 1280, 720), (32, 120, 1280, 720), (32, 300, 640, 360),
    ])
    func eachBudgetPicksTheLargestRungThatStillLooksGood(mebibytes: Int, seconds: Double, width: Int, height: Int) throws {
        let limit = mebibytes * Self.mebibyte
        let plan = try #require(encoded(plan(Self.uhd, seconds: seconds, limit: limit)))
        #expect(plan.width == width && plan.height == height)
        #expect(plan.frameRate == 30)
        #expect(plan.plannedBytes <= Int(Double(limit) * 0.95))
        #expect(plan.audioBitRate == 96_000)
    }

    @Test(arguments: [(10, 300.0, 194), (10, 1200, 194), (32, 1200, 622)])
    func aClipTooLongForAcceptableQualityOffersItsLongestStart(mebibytes: Int, seconds: Double, maximum: Int) throws {
        let limit = mebibytes * Self.mebibyte
        #expect(plan(Self.uhd, seconds: seconds, limit: limit) == .tooLong(maximumSeconds: maximum))
        // That start then encodes at the smallest rung, with the leaner audio.
        let start = try #require(encoded(plan(Self.uhd, seconds: Double(maximum), limit: limit)))
        #expect(start.width == 640 && start.height == 360 && start.frameRate == 30 && start.audioBitRate == 64_000)
        #expect(start.plannedBytes <= limit)
    }

    @Test func aSilentClipSpendsTheAudioShareOnPicturesAndFitsLonger() throws {
        let silent = VideoSizePlan.Source(width: 1920, height: 1080, frameRate: 30, seconds: 1200, hasAudio: false)
        #expect(VideoSizePlan.plan(silent, limit: 10 * Self.mebibyte) == .tooLong(maximumSeconds: 230))
        var short = silent
        short.seconds = 60
        let plan = try #require(encoded(VideoSizePlan.plan(short, limit: 10 * Self.mebibyte)))
        #expect(plan.audioBitRate == 0 && plan.videoBitRate == Int(Double(10 * Self.mebibyte) * 0.95 * 8 / 60))
    }

    @Test func aLimitTooSmallForOneSecondIsTooLarge() {
        #expect(plan(Self.uhd, seconds: 60, limit: 20_000) == .tooLarge)
    }

    @Test func sixtyFramesStayOnlyWhileTheRungStillLooksGoodAtSixty() throws {
        let sixty = VideoSizePlan.Source(width: 1920, height: 1080, frameRate: 60, seconds: 60)
        let kept = try #require(encoded(VideoSizePlan.plan(sixty, limit: 32 * Self.mebibyte)))
        #expect(kept.width == 1280 && kept.height == 720 && kept.frameRate == 60)
        let capped = try #require(encoded(VideoSizePlan.plan(sixty, limit: 10 * Self.mebibyte)))
        #expect(capped.width == 960 && capped.height == 540 && capped.frameRate == 30, "540p at 60 is 0.04 bits per pixel")
        var slowMotion = sixty
        slowMotion.frameRate = 240
        slowMotion.seconds = 10
        let fast = try #require(encoded(VideoSizePlan.plan(slowMotion, limit: 32 * Self.mebibyte)))
        #expect(fast.width == 1920 && fast.frameRate == 60, "never above 60")
    }

    @Test(arguments: [24.0, 25, 29.97, 30])
    func aRateOfThirtyOrLessIsNeverChanged(rate: Double) throws {
        let source = VideoSizePlan.Source(width: 1920, height: 1080, frameRate: rate, seconds: 60)
        for limit in [10 * Self.mebibyte, 32 * Self.mebibyte] {
            #expect(try #require(encoded(VideoSizePlan.plan(source, limit: limit))).frameRate == rate)
        }
    }

    @Test func anUnknownRateIsTakenAsThirty() throws {
        let source = VideoSizePlan.Source(width: 1920, height: 1080, frameRate: 0, seconds: 60)
        #expect(try #require(encoded(VideoSizePlan.plan(source, limit: 10 * Self.mebibyte))).frameRate == 30)
    }

    @Test func aSmallSourceIsNeverScaledUp() throws {
        let small = VideoSizePlan.Source(width: 640, height: 360, frameRate: 30, seconds: 10)
        let plan = try #require(encoded(VideoSizePlan.plan(small, limit: 32 * Self.mebibyte)))
        #expect(plan.width == 640 && plan.height == 360)
        #expect(plan.videoBitRate == Int(0.12 * Double(640 * 360) * 30))
        let tiny = VideoSizePlan.Source(width: 320, height: 240, frameRate: 30, seconds: 10)
        #expect(VideoSizePlan.sizes(tiny).map(\.width) == [320], "below the smallest rung it keeps its own size")
        let between = VideoSizePlan.Source(width: 1000, height: 600, frameRate: 30, seconds: 10)
        #expect(VideoSizePlan.sizes(between).map(\.height) == [600, 540, 480, 360])
        #expect(try #require(encoded(VideoSizePlan.plan(between, limit: 32 * Self.mebibyte))).width == 1000)
    }

    @Test func portraitKeepsItsOrientationAndEvenSides() throws {
        let portrait = VideoSizePlan.Source(width: 1080, height: 1920, frameRate: 30, seconds: 60)
        let plan = try #require(encoded(VideoSizePlan.plan(portrait, limit: 10 * Self.mebibyte)))
        #expect(plan.width == 540 && plan.height == 960)
        let odd = VideoSizePlan.Source(width: 886, height: 1920, frameRate: 30, seconds: 120)
        for size in VideoSizePlan.sizes(odd) { #expect(size.width % 2 == 0 && size.height % 2 == 0 && size.width < size.height) }
    }

    @Test func aShortClipIsCappedRatherThanFilledToTheLimit() throws {
        let clip = VideoSizePlan.Source(width: 1920, height: 1080, frameRate: 30, seconds: 5)
        let plan = try #require(encoded(VideoSizePlan.plan(clip, limit: 32 * Self.mebibyte)))
        #expect(plan.width == 1920 && plan.videoBitRate == Int(0.12 * Double(1920 * 1080) * 30))
        #expect(plan.plannedBytes < 6 * Self.mebibyte)
        var lean = clip
        lean.videoBitRate = 2_000_000
        #expect(try #require(encoded(VideoSizePlan.plan(lean, limit: 32 * Self.mebibyte))).videoBitRate == 2_000_000, "never above the source's own")
    }

    @Test func anOvershootRetriesOnceWithTheBitrateScaledDown() throws {
        let sixty = VideoSizePlan.Source(width: 1920, height: 1080, frameRate: 60, seconds: 60)
        let limit = 32 * Self.mebibyte
        let first = try #require(encoded(VideoSizePlan.plan(sixty, limit: limit)))
        let retry = try #require(VideoSizePlan.retry(first, source: sixty, limit: limit, actualBytes: limit + limit / 10))
        let scaled = Int(Double(first.videoBitRate) * Double(limit) / Double(limit + limit / 10) * 0.9)
        // The smaller bitrate no longer carries 60 frames at 720p, so the rate drops and the 30-frame cap applies.
        #expect(retry.width == 1280 && retry.frameRate == 30)
        #expect(retry.videoBitRate == min(scaled, Int(0.12 * Double(1280 * 720) * 30)))
        #expect(retry.audioBitRate == first.audioBitRate)
        let starved = VideoSizePlan.Source(width: 1920, height: 1080, frameRate: 30, seconds: 120)
        let tight = try #require(encoded(VideoSizePlan.plan(starved, limit: 10 * Self.mebibyte)))
        #expect(VideoSizePlan.retry(tight, source: starved, limit: 10 * Self.mebibyte, actualBytes: 40 * Self.mebibyte) == nil)
    }

    // The encoder's floor at the smallest rung can sit above the planned rate, so the start offered after a miss is
    // sized by the rate it measured, with the plan's margins, and is always shorter than what was tried.
    @Test func aMissAtTheEncoderFloorOffersTheStartThatFitsAtTheMeasuredRate() {
        let limit = 10 * Self.mebibyte
        #expect(VideoSizePlan.longestSeconds(measuredBytes: 12 * Self.mebibyte, plannedSeconds: 200, limit: limit, currentSeconds: 200) == 142)
        let shortened = VideoSizePlan.longestSeconds(measuredBytes: 10 * Self.mebibyte + Self.mebibyte / 2, plannedSeconds: 142, limit: limit,
                                                     currentSeconds: 142)
        #expect(shortened == 115, "an already shortened start shortens again")
        #expect(VideoSizePlan.longestSeconds(measuredBytes: 5 * Self.mebibyte, plannedSeconds: 10, limit: limit, currentSeconds: 10) == 9,
                "never the length already tried")
        #expect(VideoSizePlan.longestSeconds(measuredBytes: 5 * Self.mebibyte, plannedSeconds: 10.4, limit: limit, currentSeconds: 10.4) == 10)
        #expect(VideoSizePlan.longestSeconds(measuredBytes: 5 * Self.mebibyte, plannedSeconds: 1, limit: limit, currentSeconds: 1) == nil)
        #expect(VideoSizePlan.longestSeconds(measuredBytes: 100 * Self.mebibyte, plannedSeconds: 5, limit: limit, currentSeconds: 5) == nil,
                "not a second fits")
        #expect(VideoSizePlan.longestSeconds(measuredBytes: 0, plannedSeconds: 5, limit: limit, currentSeconds: 5) == nil)
    }
}
