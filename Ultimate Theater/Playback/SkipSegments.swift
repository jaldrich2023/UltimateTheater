//
//  SkipSegments.swift
//  Ultimate Theater
//
//  Finds an episode's intro and end credits for Skip Intro / Skip Credits: from the file's
//  chapter names when it has them, otherwise by matching its audio against neighbouring
//  episodes of the same show (a theme or credits sequence repeats; the story doesn't).
//

import Foundation
import Accelerate
import AudioToolbox
import CoreMedia

/// Where an episode's intro and end credits are, in seconds.
nonisolated struct SkipSegments: Hashable, Sendable {
    var introStart: Double?
    var introEnd: Double?
    var creditsStart: Double?

    var hasIntro: Bool { introStart != nil && introEnd != nil }
    var isComplete: Bool { hasIntro && creditsStart != nil }
    var isEmpty: Bool { !hasIntro && creditsStart == nil }

    /// These segments, with any that are missing taken from `other`.
    func filling(from other: SkipSegments) -> SkipSegments {
        var result = self
        if !hasIntro, other.hasIntro {
            result.introStart = other.introStart
            result.introEnd = other.introEnd
        }
        if creditsStart == nil { result.creditsStart = other.creditsStart }
        return result
    }
}

// MARK: - Chapters

nonisolated enum SkipChapterKind: Hashable, Sendable {
    case intro
    case credits

    /// Whole-word phrases anywhere in a chapter name.
    private static let introPhrases = ["intro", "opening credits", "opening titles", "opening sequence", "opening theme",
                                       "title sequence", "main title", "main titles"]
    /// Names that only count on their own ("Opening", not "The Opening Night").
    private static let introNames: Set<String> = ["opening", "op", "theme", "theme song", "titles", "opening song"]
    private static let creditsPhrases = ["credits", "end credits", "closing credits", "end titles", "end credit", "outro"]
    private static let creditsNames: Set<String> = ["ending", "end", "closing", "ed", "ending theme", "ending song"]

    /// Classifies a chapter by its name, ignoring case and punctuation.
    static func classify(_ title: String) -> SkipChapterKind? {
        let words = String(title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
        guard !words.isEmpty else { return nil }
        let padded = " \(words) "
        // Intro first: "Opening Credits" is an intro.
        if introNames.contains(words) || introPhrases.contains(where: { padded.contains(" \($0) ") }) { return .intro }
        if creditsNames.contains(words) || creditsPhrases.contains(where: { padded.contains(" \($0) ") }) { return .credits }
        return nil
    }
}

nonisolated enum SkipChapters {
    /// Intros longer than this are probably misnamed chapters, not a title sequence.
    static let longestIntro: Double = 300

    /// The first intro and credits chapters. An intro runs to its own end, or to the next chapter.
    static func segments(from chapters: [(title: String, start: Double, end: Double?)], duration: Double?) -> SkipSegments {
        let sorted = chapters.sorted { $0.start < $1.start }
        var result = SkipSegments()
        for (index, chapter) in sorted.enumerated() {
            switch SkipChapterKind.classify(chapter.title) {
            case .intro where !result.hasIntro:
                let next = sorted[(index + 1)...].first { $0.start > chapter.start }?.start
                let end = chapter.end.flatMap { $0 > chapter.start ? $0 : nil } ?? next
                if let end, (5...longestIntro).contains(end - chapter.start) {
                    result.introStart = chapter.start
                    result.introEnd = end
                }
            case .credits where result.creditsStart == nil:
                // End credits are in the back half; an early "Credits" chapter is something else.
                if let duration, duration > 0, chapter.start < duration * 0.5 { continue }
                result.creditsStart = chapter.start
            default:
                break
            }
        }
        return result
    }
}

// MARK: - Fingerprints

/// A compact description of a stretch of audio: one 32-bit hash per 0.1 s. Each bit says
/// whether the energy difference between two neighbouring frequency bands rose or fell since
/// the previous frame, which survives re-encoding, level changes, and different codecs.
nonisolated struct AudioFingerprint: Sendable {
    /// Mono analysis rate: plenty for the 150–2900 Hz bands the hashes use.
    static let sampleRate = 6000.0
    static let hop = 600
    static let windowLength = 2048
    static let bandCount = 33
    /// Mean square below this (about −70 dBFS) is silence, which would match any other silence.
    static let quietLevel: Float = 1e-7

    static var frameDuration: Double { Double(hop) / sampleRate }
    /// Seconds from a frame's start to the middle of its analysis window.
    static var frameCenter: Double { Double(windowLength) / 2 / sampleRate }

    var hashes: [UInt32] = []
    /// Frames that can't identify anything: silence, and the first frame (no previous to compare).
    var isQuiet: [Bool] = []

    var count: Int { hashes.count }

    init() {}

    /// Fingerprints mono samples at `sampleRate`.
    init(samples: [Float]) {
        let length = Self.windowLength
        let half = length / 2
        guard samples.count >= length,
              let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(length), .FORWARD) else { return }
        defer { vDSP_DFT_DestroySetup(setup) }

        var window = [Float](repeating: 0, count: length)
        vDSP_hann_window(&window, vDSP_Length(length), Int32(vDSP_HANN_NORM))
        // Log-spaced band edges, in FFT bins.
        let binWidth = Self.sampleRate / Double(length)
        var edges = (0...Self.bandCount).map { band in
            Int((150 * pow(2900.0 / 150, Double(band) / Double(Self.bandCount)) / binWidth).rounded())
        }
        for band in 1..<edges.count { edges[band] = min(max(edges[band], edges[band - 1] + 1), half) }

        let frames = (samples.count - length) / Self.hop + 1
        let bands = Self.bandCount
        var energies = [Float](repeating: 0, count: frames * bands)
        var quiet = [Bool](repeating: false, count: frames)
        var evens = [Float](repeating: 0, count: half)
        var odds = [Float](repeating: 0, count: half)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        for frame in 0..<frames {
            let start = frame * Self.hop
            var power: Float = 0
            // The real DFT takes even samples as the real part and odd ones as the imaginary part.
            for index in 0..<half {
                let even = samples[start + 2 * index]
                let odd = samples[start + 2 * index + 1]
                power += even * even + odd * odd
                evens[index] = even * window[2 * index]
                odds[index] = odd * window[2 * index + 1]
            }
            quiet[frame] = power / Float(length) < Self.quietLevel
            vDSP_DFT_Execute(setup, evens, odds, &real, &imaginary)
            for band in 0..<bands {
                var sum: Float = 0
                for bin in edges[band]..<edges[band + 1] {
                    sum += real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
                }
                energies[frame * bands + band] = log10(sum + 1e-12)
            }
        }

        hashes = [UInt32](repeating: 0, count: frames)
        isQuiet = quiet
        isQuiet[0] = true
        for frame in 1..<frames {
            let now = frame * bands
            let before = now - bands
            var hash: UInt32 = 0
            for bit in 0..<(bands - 1) {
                let change = (energies[now + bit] - energies[now + bit + 1]) - (energies[before + bit] - energies[before + bit + 1])
                if change > 0 { hash |= 1 << UInt32(bit) }
            }
            hashes[frame] = hash
        }
    }
}

/// A stretch two fingerprints share, in frames.
nonisolated struct FingerprintRun: Hashable, Sendable {
    let aStart: Int
    let bStart: Int
    let length: Int

    var aEnd: Int { aStart + length }
}

nonisolated enum FingerprintMatcher {
    /// Frames match when at most this many of their 32 bits differ (unrelated audio differs by 16 on average).
    static let maximumBitErrors = 10
    /// A frame is inside a shared stretch when enough frames around it match…
    static let smoothingWindow = 10
    static let minimumMatchesInWindow = 4
    /// …and stretches separated by short gaps (dialogue over a theme, a glitch) join up.
    static let maximumGap = 20
    static let minimumDensity = 0.3

    /// Every stretch of at least `minimumLength` frames that both fingerprints share, at any
    /// alignment. Overlapping alignments can report the same stretch more than once.
    static func commonRuns(_ a: AudioFingerprint, _ b: AudioFingerprint, minimumLength: Int) -> [FingerprintRun] {
        guard minimumLength > 0, a.count >= minimumLength, b.count >= minimumLength else { return [] }
        let lag = smoothingWindow / 2 - 1
        let lead = smoothingWindow - lag - 1
        var runs: [FingerprintRun] = []
        var matches = [UInt8](repeating: 0, count: min(a.count, b.count))

        // b's frame = a's frame + offset.
        for offset in -(a.count - minimumLength)...(b.count - minimumLength) {
            if offset & 255 == 0, Task.isCancelled { return [] }
            let first = max(0, -offset)
            let length = min(a.count, b.count - offset) - first
            guard length >= minimumLength else { continue }
            for step in 0..<length {
                let i = first + step
                let j = i + offset
                let isMatch = !a.isQuiet[i] && !b.isQuiet[j] && (a.hashes[i] ^ b.hashes[j]).nonzeroBitCount <= maximumBitErrors
                matches[step] = isMatch ? 1 : 0
            }

            // Slide a window over the matches, grouping dense stretches separated by short gaps.
            var windowSum = 0
            for step in 0..<min(lead, length) { windowSum += Int(matches[step]) }
            var groupStart = -1
            var lastDense = -1
            func closeGroup() {
                guard groupStart >= 0 else { return }
                // Trim to the first and last real matches.
                guard let start = (groupStart...lastDense).first(where: { matches[$0] == 1 }),
                      let end = (groupStart...lastDense).last(where: { matches[$0] == 1 }) else { return }
                let span = end - start + 1
                guard span >= minimumLength else { return }
                let count = matches[start...end].reduce(0) { $0 + Int($1) }
                guard Double(count) / Double(span) >= minimumDensity else { return }
                runs.append(FingerprintRun(aStart: first + start, bStart: first + start + offset, length: span))
            }
            for step in 0..<length {
                if step + lead < length { windowSum += Int(matches[step + lead]) }
                if step - lag - 1 >= 0 { windowSum -= Int(matches[step - lag - 1]) }
                guard windowSum >= minimumMatchesInWindow else { continue }
                if groupStart < 0 || step - lastDense > maximumGap {
                    closeGroup()
                    groupStart = step
                }
                lastDense = step
            }
            closeGroup()
        }
        return runs
    }
}

// MARK: - Detection

/// What the detector needs from one episode file: its audio fingerprinted where an intro
/// or credits could be.
nonisolated struct EpisodeAudioPrint: Sendable {
    var duration: Double?
    /// From the start of the file.
    var intro = AudioFingerprint()
    var credits = AudioFingerprint()
    /// Where the credits fingerprint starts, in seconds.
    var creditsWindowStart: Double = 0
}

nonisolated enum SkipSegmentDetector {
    /// Bumped when detection improves, so episodes are analysed again.
    static let version = 1
    static let introLengths: ClosedRange<Double> = 15...180
    static let minimumCredits: Double = 15
    /// Shared credits must run to within this many seconds of the end of the file.
    static let creditsEndTolerance: Double = 30

    /// Intro and credits from the file's chapter names; empty when it has none (or can't be read).
    static func chapterSegments(in url: URL) -> SkipSegments {
        guard let demuxer = try? Demuxers.open(url) else { return SkipSegments() }
        return SkipChapters.segments(from: demuxer.chapters.map { ($0.title, $0.start, $0.end) }, duration: demuxer.duration)
    }

    /// Matches an episode's audio against its neighbours'. Where neighbours disagree, the
    /// tighter result wins, so a skip never jumps over part of the episode itself.
    static func detect(target: EpisodeAudioPrint, neighbours: [EpisodeAudioPrint]) -> SkipSegments {
        var result = SkipSegments()

        let intros = neighbours.compactMap { intro(target.intro, $0.intro) }
        var chosen = intros.max { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }
        if intros.count >= 2 {
            let lower = intros.map(\.lowerBound).max()!
            let upper = intros.map(\.upperBound).min()!
            if upper - lower >= introLengths.lowerBound { chosen = lower..<upper }
        }
        if let chosen {
            result.introStart = chosen.lowerBound
            result.introEnd = chosen.upperBound
        }

        if let start = neighbours.compactMap({ creditsStart(target.credits, $0.credits) }).max() {
            let credits = target.creditsWindowStart + start
            if credits > (result.introEnd ?? 0) { result.creditsStart = credits }
        }
        return result
    }

    /// The longest stretch near the start that both episodes share, in `a`'s seconds.
    static func intro(_ a: AudioFingerprint, _ b: AudioFingerprint) -> Range<Double>? {
        let frame = AudioFingerprint.frameDuration
        let runs = FingerprintMatcher.commonRuns(a, b, minimumLength: Int(introLengths.lowerBound / frame))
            .filter { Double($0.length) * frame <= introLengths.upperBound }
        guard let best = runs.max(by: { $0.length < $1.length }) else { return nil }
        let start = Double(best.aStart) * frame + AudioFingerprint.frameCenter
        let end = Double(best.aEnd - 1) * frame + AudioFingerprint.frameCenter
        return start..<end
    }

    /// Where a shared stretch that runs (nearly) to the end of `a` begins, in seconds from
    /// the start of the fingerprint.
    static func creditsStart(_ a: AudioFingerprint, _ b: AudioFingerprint) -> Double? {
        let frame = AudioFingerprint.frameDuration
        let nearEnd = a.count - Int(creditsEndTolerance / frame)
        let runs = FingerprintMatcher.commonRuns(a, b, minimumLength: Int(minimumCredits / frame))
            .filter { $0.aEnd >= nearEnd }
        guard let best = runs.max(by: { $0.length < $1.length }) else { return nil }
        return Double(best.aStart) * frame + AudioFingerprint.frameCenter
    }
}

// MARK: - Reading audio

nonisolated enum EpisodeAudioReader {
    /// The intro is looked for in the first 10 minutes, or the first 30% of a short episode.
    static let introSearch: Double = 600
    static let introFraction = 0.3
    /// Credits are looked for in the last 6 minutes.
    static let creditsSearch: Double = 360

    /// Decodes the default audio track in the intro and credits windows and fingerprints them.
    /// Files without a decodable audio track give empty fingerprints. Cancellable.
    static func read(_ url: URL) throws -> EpisodeAudioPrint {
        let demuxer = try Demuxers.open(url)
        var result = EpisodeAudioPrint(duration: demuxer.duration)
        let audio = demuxer.tracks.filter { $0.kind == .audio && $0.codec.isSupported }
        guard let track = audio.first(where: \.isDefault) ?? audio.first,
              let formatter = try? TrackFormatter(track: track) else { return result }
        demuxer.enabledTrackIDs = [track.id]
        var decoder: PCMDecoder?

        let introEnd = min(introSearch, (demuxer.duration ?? .infinity) * introFraction)
        result.intro = AudioFingerprint(samples: try samples(demuxer, formatter, track.id, &decoder, from: 0, to: introEnd))
        if let duration = demuxer.duration, duration.isFinite, duration - introEnd > 60 {
            let start = max(duration - creditsSearch, introEnd)
            result.creditsWindowStart = start
            result.credits = AudioFingerprint(samples: try samples(demuxer, formatter, track.id, &decoder, from: start, to: duration))
        }
        return result
    }

    /// Mono samples at the fingerprint rate covering `start..<end`, placed by timestamp
    /// (gaps stay silent). Channels are averaged; resampling averages each output period.
    private static func samples(_ demuxer: any MediaDemuxer, _ formatter: TrackFormatter, _ trackID: Int,
                                _ decoder: inout PCMDecoder?, from start: Double, to end: Double) throws -> [Float] {
        let rate = AudioFingerprint.sampleRate
        // Damaged durations can make the window empty, endless, or not a number.
        let span = (end - start) * rate
        guard span.isFinite, span >= 1, span <= 3_600 * rate else { return [] }
        let count = Int(span)
        var sums = [Float](repeating: 0, count: count)
        var weights = [UInt8](repeating: 0, count: count)

        try demuxer.seek(to: max(start - 1, 0))
        formatter.reset()
        decoder?.reset()
        while let packet = try demuxer.nextPacket() {
            try Task.checkCancellation()
            guard packet.trackID == trackID else { continue }
            if packet.pts > end + 1 { break }
            // Without a seek index the reader may restart from the beginning: skip ahead cheaply.
            if packet.pts < start - 3 { continue }
            for buffer in (try? formatter.sampleBuffers(for: packet)) ?? [] {
                guard let format = CMSampleBufferGetFormatDescription(buffer) else { continue }
                if decoder.map({ !CMFormatDescriptionEqual($0.format, otherFormatDescription: format) }) ?? true {
                    decoder = PCMDecoder(format: format)
                }
                guard let pcmDecoder = decoder else { continue }
                let pcm = pcmDecoder.decode(buffer)
                let channels = pcmDecoder.channels
                guard !pcm.isEmpty else { continue }
                let step = rate / pcmDecoder.sampleRate
                var position = (CMSampleBufferGetPresentationTimeStamp(buffer).seconds - start) * rate
                guard position.isFinite, step.isFinite else { continue }
                let scale = 1 / Float(channels)
                for frame in 0..<(pcm.count / channels) {
                    let place = position.rounded(.down)
                    position += step
                    guard place >= 0, place < Double(count) else { continue }
                    let index = Int(place)
                    guard weights[index] < 255 else { continue }
                    var mono: Float = 0
                    for channel in 0..<channels { mono += pcm[frame * channels + channel] }
                    sums[index] += mono * scale
                    weights[index] += 1
                }
            }
        }
        for index in 0..<count where weights[index] > 1 {
            sums[index] /= Float(weights[index])
        }
        return sums
    }
}

/// Decodes the engine's audio sample buffers (compressed or PCM) to interleaved float PCM
/// with AudioToolbox.
nonisolated final class PCMDecoder {
    let format: CMFormatDescription
    let channels: Int
    let sampleRate: Double
    private let converter: AudioConverterRef
    private let input: AudioStreamBasicDescription

    /// Input for one conversion call: every packet of one sample buffer.
    private final class Feed {
        var bytes: UnsafeMutableRawPointer?
        var byteCount = 0
        var descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
        var packetCount: UInt32 = 0
        var channels: UInt32 = 0
        var given = false
    }

    init?(format: CMFormatDescription) {
        guard var input = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              input.mChannelsPerFrame > 0, input.mSampleRate > 0 else { return nil }
        let channels = input.mChannelsPerFrame
        var output = AudioStreamBasicDescription(mSampleRate: input.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
                                                 mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return nil }
        var cookieSize = 0
        if let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &cookieSize), cookieSize > 0 {
            _ = AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(cookieSize), cookie)
        }
        self.format = format
        self.converter = converter
        self.input = input
        self.channels = Int(channels)
        self.sampleRate = input.mSampleRate
    }

    deinit {
        AudioConverterDispose(converter)
    }

    /// Clears decoder state after a seek.
    func reset() {
        AudioConverterReset(converter)
    }

    func decode(_ sample: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return [] }
        let feed = Feed()
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16)
        defer { bytes.deallocate() }
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes) == noErr else { return [] }
        feed.bytes = bytes
        feed.byteCount = length
        feed.channels = input.mChannelsPerFrame

        var descriptions: UnsafePointer<AudioStreamPacketDescription>?
        var descriptionsSize = 0
        _ = CMSampleBufferGetAudioStreamPacketDescriptionsPtr(sample, packetDescriptionsPointerOut: &descriptions,
                                                              sizeOut: &descriptionsSize)
        let descriptionCount = descriptionsSize / MemoryLayout<AudioStreamPacketDescription>.stride
        var ownedDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
        defer { ownedDescriptions?.deallocate() }
        if let descriptions, descriptionCount > 0 {
            let copy = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: descriptionCount)
            copy.initialize(from: descriptions, count: descriptionCount)
            ownedDescriptions = copy
            feed.descriptions = copy
            feed.packetCount = UInt32(descriptionCount)
        } else if input.mBytesPerPacket > 0 {
            feed.packetCount = UInt32(length / Int(input.mBytesPerPacket))
        } else {
            feed.packetCount = UInt32(CMSampleBufferGetNumSamples(sample))
        }
        guard feed.packetCount > 0 else { return [] }

        let capacity = 4096
        var chunk = [Float](repeating: 0, count: capacity * channels)
        var output: [Float] = []
        let channelCount = UInt32(channels)
        while true {
            var frames = UInt32(capacity)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channelCount,
                                                                                      mDataByteSize: UInt32(raw.count),
                                                                                      mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(converter, { _, count, data, descriptions, user in
                    let feed = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
                    // "No more for now" (not end of stream, which would flush the decoder).
                    guard !feed.given else { count.pointee = 0; return 1 }
                    feed.given = true
                    count.pointee = feed.packetCount
                    data.pointee.mNumberBuffers = 1
                    data.pointee.mBuffers.mData = feed.bytes
                    data.pointee.mBuffers.mDataByteSize = UInt32(feed.byteCount)
                    data.pointee.mBuffers.mNumberChannels = feed.channels
                    descriptions?.pointee = feed.descriptions
                    return noErr
                }, Unmanaged.passUnretained(feed).toOpaque(), &frames, &list, nil)
            }
            if frames > 0 { output.append(contentsOf: chunk[0..<(Int(frames) * channels)]) }
            if status != noErr || frames < UInt32(capacity) { break }
        }
        return output
    }
}

// MARK: - Cache

/// Fingerprints by file for this session, so an episode's neighbours aren't decoded again
/// when they're analysed in turn.
actor EpisodeAudioPrintCache {
    static let shared = EpisodeAudioPrintCache()

    private var prints: [String: EpisodeAudioPrint] = [:]
    private var order: [String] = []
    private let limit = 64

    /// Reads (or recalls) a file's fingerprints at background priority. Nil if it can't be read.
    func print(for url: URL) async -> EpisodeAudioPrint? {
        let key = url.standardizedFileURL.path
        if let cached = prints[key] { return cached }
        let task = Task.detached(priority: .background) { try? EpisodeAudioReader.read(url) }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard let result, !Task.isCancelled else { return nil }
        prints[key] = result
        order.append(key)
        if order.count > limit { prints.removeValue(forKey: order.removeFirst()) }
        return result
    }

    func removeAll() {
        prints.removeAll()
        order.removeAll()
    }
}
