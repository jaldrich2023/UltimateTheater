//
//  SkipSegmentTests.swift
//  Ultimate TheaterTests
//
//  Skip Intro / Skip Credits detection: chapter names, and audio fingerprint matching on
//  synthetic signals that share (or don't share) a stretch of "theme music".
//

import Testing
import Foundation
@testable import Ultimate_Theater

struct SkipSegmentTests {
    /// Music-like audio at the fingerprint rate: a new chord every quarter second, over a
    /// little noise.
    static func music(seconds: Double, seed: UInt64) -> [Float] {
        var random = SeededGenerator(state: seed)
        let rate = AudioFingerprint.sampleRate
        let noteLength = Int(rate / 4)
        var samples: [Float] = []
        samples.reserveCapacity(Int(seconds * rate))
        while samples.count < Int(seconds * rate) {
            let notes = (0..<3).map { _ in Double.random(in: 180...2600, using: &random) }
            let level = Float.random(in: 0.05...0.3, using: &random)
            for index in 0..<noteLength {
                let time = Double(samples.count + index) / rate
                var value: Float = 0
                for frequency in notes { value += Float(sin(2 * .pi * frequency * time)) }
                samples.append(level * value / 3 + Float.random(in: -0.01...0.01, using: &random))
            }
        }
        return Array(samples.prefix(Int(seconds * rate)))
    }

    /// Adds quiet noise, standing in for a different encode of the same audio.
    static func roughened(_ samples: [Float], seed: UInt64) -> [Float] {
        var random = SeededGenerator(state: seed)
        return samples.map { $0 * 0.9 + Float.random(in: -0.005...0.005, using: &random) }
    }

    // MARK: Chapters

    @Test(arguments: ["Intro", "Opening Credits", "OPENING", "Main Titles", "Title Sequence", "OP", "Theme Song", "Chapter 2 - Intro"])
    func introChapterNames(_ name: String) {
        #expect(SkipChapterKind.classify(name) == .intro)
    }

    @Test(arguments: ["Credits", "End Credits", "Closing Credits", "Ending", "ED", "Outro", "End Titles"])
    func creditsChapterNames(_ name: String) {
        #expect(SkipChapterKind.classify(name) == .credits)
    }

    @Test(arguments: ["Chapter 1", "Introduction", "The Opening Night", "A Happy Ending", "Theme Park", ""])
    func otherChapterNames(_ name: String) {
        #expect(SkipChapterKind.classify(name) == nil)
    }

    @Test func introRunsToTheNextChapter() {
        let chapters: [(title: String, start: Double, end: Double?)] = [
            ("Cold Open", 0, nil), ("Opening Credits", 95, nil), ("Act One", 150, nil), ("End Credits", 2500, nil),
        ]
        let segments = SkipChapters.segments(from: chapters, duration: 2600)
        #expect(segments.introStart == 95)
        #expect(segments.introEnd == 150)
        #expect(segments.creditsStart == 2500)
    }

    @Test func earlyCreditsChapterIsIgnored() {
        let chapters: [(title: String, start: Double, end: Double?)] = [("Credits", 30, nil), ("Story", 60, nil)]
        #expect(SkipChapters.segments(from: chapters, duration: 2600).creditsStart == nil)
    }

    // MARK: Fingerprints

    @Test func findsSharedIntroAtDifferentOffsets() {
        let theme = Self.music(seconds: 30, seed: 1)
        let a = Self.music(seconds: 60, seed: 2) + theme + Self.music(seconds: 40, seed: 3)
        // An offset that doesn't fall on the fingerprint's frame grid.
        let b = Self.music(seconds: 25.37, seed: 4) + Self.roughened(theme, seed: 5) + Self.music(seconds: 70, seed: 6)
        let intro = SkipSegmentDetector.intro(AudioFingerprint(samples: a), AudioFingerprint(samples: b))
        #expect(intro != nil)
        if let intro {
            #expect(abs(intro.lowerBound - 60) < 1.5)
            #expect(abs(intro.upperBound - 90) < 1.5)
        }
    }

    @Test func rejectsUnrelatedAudio() {
        let a = AudioFingerprint(samples: Self.music(seconds: 120, seed: 10))
        let b = AudioFingerprint(samples: Self.music(seconds: 120, seed: 11))
        #expect(FingerprintMatcher.commonRuns(a, b, minimumLength: 150).isEmpty)
        #expect(SkipSegmentDetector.intro(a, b) == nil)
    }

    @Test func silenceDoesNotMatchSilence() {
        let silence = [Float](repeating: 0, count: Int(60 * AudioFingerprint.sampleRate))
        let a = AudioFingerprint(samples: silence + Self.music(seconds: 30, seed: 20))
        let b = AudioFingerprint(samples: silence + Self.music(seconds: 30, seed: 21))
        #expect(SkipSegmentDetector.intro(a, b) == nil)
    }

    @Test func findsSharedCreditsAtTheEnd() {
        let credits = Self.music(seconds: 40, seed: 30)
        let a = Self.music(seconds: 200, seed: 31) + credits
        let b = Self.music(seconds: 150.55, seed: 32) + Self.roughened(credits, seed: 33)
        let start = SkipSegmentDetector.creditsStart(AudioFingerprint(samples: a), AudioFingerprint(samples: b))
        #expect(start != nil)
        if let start { #expect(abs(start - 200) < 1.5) }
    }

    @Test func neighboursAgreeOnTheTighterIntro() {
        let theme = Self.music(seconds: 40, seed: 40)
        let target = Self.music(seconds: 50, seed: 41) + theme + Self.music(seconds: 30, seed: 42)
        // The previous episode shares only the last 30 seconds of the theme.
        let previous = Self.music(seconds: 20, seed: 43) + Array(theme.suffix(Int(30 * AudioFingerprint.sampleRate)))
            + Self.music(seconds: 60, seed: 44)
        let next = Self.music(seconds: 70, seed: 45) + theme + Self.music(seconds: 20, seed: 46)
        func audio(_ samples: [Float]) -> EpisodeAudioPrint {
            EpisodeAudioPrint(duration: Double(samples.count) / AudioFingerprint.sampleRate, intro: AudioFingerprint(samples: samples))
        }
        let segments = SkipSegmentDetector.detect(target: audio(target), neighbours: [audio(previous), audio(next)])
        #expect(segments.introStart.map { abs($0 - 60) < 1.5 } == true)
        #expect(segments.introEnd.map { abs($0 - 90) < 1.5 } == true)
        #expect(segments.creditsStart == nil)
    }
}
