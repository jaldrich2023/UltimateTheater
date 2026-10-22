//
//  TheaterEngine.swift
//  Ultimate Theater
//
//  The Theater engine plays containers AVFoundation can't open (MKV, AVI).
//  Our demuxers extract packets; the system's sample-buffer renderers decode and
//  present them in sync.
//

import Foundation
import AVFoundation
import CoreMedia

// MARK: - Pipeline

/// Messages from the pipeline to the engine.
nonisolated enum PipelineEvent: Sendable {
    case cue(track: Int, SubtitleCue)
    /// Ends the open image subtitle on a track.
    case endCue(track: Int, at: Double)
    case error(String)
}

/// Owns the demuxer and feeds the renderers. Runs off the main actor; each renderer
/// has its own feeder so neither can starve the other.
actor TheaterPipeline {
    nonisolated let tracks: [ContainerTrack]
    nonisolated let duration: Double?
    nonisolated let chapters: [ContainerChapter]

    private let demuxer: any MediaDemuxer
    private var videoReceiver: AVSampleBufferVideoRenderer.Receiver?
    private var audioReceiver: AVSampleBufferAudioRenderer.Receiver?
    private var videoFormatter: TrackFormatter?
    private var audioFormatter: TrackFormatter?
    private var subtitleTrackIDs: Set<Int> = []
    private var pgsDecoders: [Int: PGSDecoder] = [:]
    private var vobSubDecoders: [Int: VobSubDecoder] = [:]
    private var dvbDecoders: [Int: DVBSubtitleDecoder] = [:]
    private var teletextDecoders: [Int: TeletextDecoder] = [:]
    private let events: AsyncStream<PipelineEvent>.Continuation

    private var videoQueue: [MediaPacket] = []
    private var audioQueue: [MediaPacket] = []
    private var isAtEnd = false
    private var awaitingKeyframe = true
    private var reconstructor: DisplayOrderReconstructor?
    private var generation = 0
    private var feeders: [Task<Void, Never>] = []

    /// Latest timestamps handed to each renderer, for buffering decisions.
    private(set) var videoFedThrough = -Double.infinity
    private(set) var audioFedThrough = -Double.infinity

    static func open(_ url: URL, events: AsyncStream<PipelineEvent>.Continuation) async throws -> TheaterPipeline {
        try await Task.detached(priority: .userInitiated) {
            try TheaterPipeline(demuxer: Demuxers.open(url), events: events)
        }.value
    }

    private init(demuxer: any MediaDemuxer, events: AsyncStream<PipelineEvent>.Continuation) {
        self.demuxer = demuxer
        self.tracks = demuxer.tracks
        self.duration = demuxer.duration
        self.chapters = demuxer.chapters
        self.events = events
    }

    private func onError(_ message: String) {
        events.yield(.error(message))
    }

    var hasVideo: Bool { videoFormatter != nil }
    var hasAudio: Bool { audioFormatter != nil }
    var reachedEnd: Bool { isAtEnd && videoQueue.isEmpty && audioQueue.isEmpty }

    func attach(video: sending AVSampleBufferVideoRenderer.Receiver, audio: sending AVSampleBufferAudioRenderer.Receiver) {
        videoReceiver = video
        audioReceiver = audio
    }

    /// Chooses tracks. Unsupported codecs throw with a readable message.
    func configure(videoTrack: Int?, audioTrack: Int?) throws {
        videoFormatter = try videoTrack.flatMap { id in tracks.first { $0.id == id } }.map(TrackFormatter.init)
        do {
            audioFormatter = try audioTrack.flatMap { id in tracks.first { $0.id == id } }.map(TrackFormatter.init)
        } catch {
            audioFormatter = nil // Play the picture even if this audio format can't be decoded.
            onError("Audio: \(error.localizedDescription)")
        }
        subtitleTrackIDs = Set(tracks.filter { $0.kind == .subtitle && $0.codec.isSupported }.map(\.id))
        demuxer.enabledTrackIDs = Set([videoFormatter?.track.id, audioFormatter?.track.id].compactMap { $0 })
            .union(subtitleTrackIDs)
    }

    /// Positions at the keyframe at or before `time`, then starts feeding. Returns the landing time.
    func start(at time: Double) -> Double {
        stopFeeding()
        let landing = (try? demuxer.seek(to: time)) ?? 0
        videoQueue = []
        audioQueue = []
        isAtEnd = false
        awaitingKeyframe = true
        videoFedThrough = -.infinity
        audioFedThrough = -.infinity
        videoFormatter?.reset()
        audioFormatter?.reset()
        if let track = videoFormatter?.track, track.isAnnexB || track.codec == .mpeg4Part2, demuxer is AVIDemuxer {
            reconstructor = DisplayOrderReconstructor(frameDuration: track.frameDuration ?? 1.0 / 25, startTime: landing)
        } else {
            reconstructor = nil
        }
        generation += 1
        let current = generation
        if videoReceiver != nil, videoFormatter != nil {
            feeders.append(Task { await self.feedVideo(generation: current) })
        }
        if audioReceiver != nil, audioFormatter != nil {
            feeders.append(Task { await self.feedAudio(generation: current) })
        }
        return landing
    }

    func stopFeeding() {
        generation += 1
        feeders.forEach { $0.cancel() }
        feeders = []
        videoReceiver?.flush()
        audioReceiver?.flush()
    }

    /// Stops feeding and clears the last displayed frame.
    func close() async {
        stopFeeding()
        await videoReceiver?.flush(removingDisplayedImage: true)
        events.finish()
    }

    // MARK: Feeding

    private func feedVideo(generation current: Int) async {
        while current == generation, !Task.isCancelled {
            guard let packet = nextPacket(video: true), let formatter = videoFormatter, let receiver = videoReceiver else { return }
            let samples: [CMSampleBuffer]
            do {
                samples = try formatter.sampleBuffers(for: packet)
            } catch {
                onError(error.localizedDescription)
                return
            }
            for sample in samples {
                guard current == generation else { return }
                guard let result = try? await receiver.enqueue(CMReadySampleBuffer(unsafeBuffer: sample)) else { return }
                switch result {
                case .cancelledDueToFlushRequiredToResume:
                    receiver.flush()
                    awaitingKeyframe = true
                case .cancelledDueToError(let error):
                    onError(error.localizedDescription)
                    return
                default:
                    break
                }
            }
            if current == generation { videoFedThrough = max(videoFedThrough, packet.pts) }
        }
    }

    private func feedAudio(generation current: Int) async {
        while current == generation, !Task.isCancelled {
            guard let packet = nextPacket(video: false), let formatter = audioFormatter, let receiver = audioReceiver else { return }
            guard let samples = try? formatter.sampleBuffers(for: packet) else { continue }
            for sample in samples {
                guard current == generation else { return }
                guard let result = try? await receiver.enqueue(CMReadySampleBuffer(unsafeBuffer: sample)) else { return }
                if case .cancelledDueToError(let error) = result {
                    onError(error.localizedDescription)
                    return
                }
            }
            if current == generation { audioFedThrough = max(audioFedThrough, packet.pts) }
        }
    }

    /// Next packet for one renderer, demuxing (and queueing the other's packets) as needed.
    private func nextPacket(video: Bool) -> MediaPacket? {
        while true {
            if video, !videoQueue.isEmpty { return videoQueue.removeFirst() }
            if !video, !audioQueue.isEmpty { return audioQueue.removeFirst() }
            if isAtEnd { return nil }
            do {
                if let packet = try demuxer.nextPacket() {
                    route(packet)
                } else {
                    isAtEnd = true
                    if var reconstructor {
                        videoQueue += reconstructor.flush()
                        self.reconstructor = reconstructor
                    }
                }
            } catch {
                isAtEnd = true
                onError(error.localizedDescription)
            }
        }
    }

    private func route(_ packet: MediaPacket) {
        if packet.trackID == videoFormatter?.track.id {
            routeVideo(packet)
        } else if packet.trackID == audioFormatter?.track.id {
            audioQueue.append(packet)
        } else if subtitleTrackIDs.contains(packet.trackID),
                  let track = tracks.first(where: { $0.id == packet.trackID }) {
            if [.pgs, .vobSub, .dvbSubtitles].contains(track.codec) {
                routeImageSubtitle(packet, track: track)
                return
            }
            if track.codec == .teletext {
                let page = TeletextDecoder.page(fromSetup: track.codecPrivate)
                let decoder = teletextDecoders[track.id] ?? TeletextDecoder(magazine: page.magazine, page: page.page)
                teletextDecoders[track.id] = decoder
                for cue in decoder.decode(packet.data, pts: packet.pts) {
                    events.yield(.cue(track: track.id, SubtitleCue(start: cue.start, end: cue.end, text: cue.text)))
                }
                return
            }
            let raw = track.codec == .tx3g ? (MP4Demuxer.timedText(packet.data) ?? "") : String(decoding: packet.data, as: UTF8.self)
            let text = SubtitleText.plain(raw, isASS: track.codec == .textASS)
            if !text.isEmpty {
                events.yield(.cue(track: packet.trackID, SubtitleCue(start: packet.pts, end: packet.pts + (packet.duration ?? 4), text: text)))
            }
        }
    }

    private func routeImageSubtitle(_ packet: MediaPacket, track: ContainerTrack) {
        let decoded: [ImageSubtitleEvent]
        if track.codec == .pgs {
            let decoder = pgsDecoders[track.id] ?? PGSDecoder()
            pgsDecoders[track.id] = decoder
            decoded = decoder.decode(packet.data, pts: packet.pts)
        } else if track.codec == .dvbSubtitles {
            let decoder = dvbDecoders[track.id] ?? DVBSubtitleDecoder()
            dvbDecoders[track.id] = decoder
            decoded = decoder.decode(packet.data, pts: packet.pts)
        } else {
            let video = tracks.first { $0.kind == .video }
            let decoder = vobSubDecoders[track.id]
                ?? VobSubDecoder(codecPrivate: track.codecPrivate, defaultSize: (video?.width ?? 720, video?.height ?? 480))
            vobSubDecoders[track.id] = decoder
            decoded = decoder.decode(packet.data, pts: packet.pts).map { [$0] } ?? []
        }
        for event in decoded {
            switch event {
            case .show(let start, let end, let bitmaps):
                events.yield(.endCue(track: track.id, at: start))
                events.yield(.cue(track: track.id, SubtitleCue(start: start, end: end ?? .infinity, text: "", bitmaps: bitmaps)))
            case .clear(let time):
                events.yield(.endCue(track: track.id, at: time))
            }
        }
    }

    private func routeVideo(_ packet: MediaPacket) {
        if awaitingKeyframe {
            guard packet.isKeyframe else { return } // Decoders restart at a sync frame.
            awaitingKeyframe = false
        }
        guard var reconstructor, let codec = videoFormatter?.track.codec else {
            videoQueue.append(packet)
            return
        }
        // AVI stores frames in decode order with frame-rate timing; rebuild display times.
        let frames: [MediaPacket] = codec == .mpeg4Part2
            ? MPEG4Part2.splitPacked(packet.data).compactMap { data in
                MPEG4Part2.isPlaceholder(data) ? nil
                    : MediaPacket(trackID: packet.trackID, pts: packet.pts, duration: packet.duration,
                                  isKeyframe: MPEG4Part2.vopType(in: data) == .intra, data: data)
            }
            : [packet]
        for frame in frames {
            let isB = codec == .mpeg4Part2 ? MPEG4Part2.vopType(in: frame.data) == .bidirectional : AnnexB.h264IsBSlice(frame.data)
            videoQueue += reconstructor.push(frame, isBFrame: isB)
        }
        self.reconstructor = reconstructor
    }
}

// MARK: - Engine

@Observable
final class TheaterEngine {
    let displayLayer = AVSampleBufferDisplayLayer()

    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var hasStarted = false
    private(set) var isBuffering = false
    private(set) var failure: String?
    private(set) var warning: String?
    private(set) var chapters: [PlaybackChapter] = []
    private(set) var trackList = MediaTrackList()
    private(set) var selectedAudioID: String?
    private(set) var selectedSubtitleID: String?
    private(set) var subtitleText: String?
    /// Image subtitles on screen now, placed as fractions of the video picture.
    private(set) var subtitleBitmaps: [SubtitleBitmap] = []
    /// The video's display size, for placing image subtitles over the picture.
    private(set) var videoSize: CGSize?

    var volume: Float = 1 {
        didSet { audioRenderer.volume = volume }
    }

    var isMuted = false {
        didSet { audioRenderer.isMuted = isMuted }
    }

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private var pipeline: TheaterPipeline?
    private var tracks: [ContainerTrack] = []
    private var cues: [Int: [Double: SubtitleCue]] = [:]
    private var clock: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var wantsPlay = false

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor.black
    }

    /// Opens a file and starts playing from `start`, honoring a saved track selection.
    func load(_ url: URL, start: Double, selection: PlaybackSelection?) async {
        do {
            let (events, continuation) = AsyncStream.makeStream(of: PipelineEvent.self)
            let pipeline = try await TheaterPipeline.open(url, events: continuation)
            self.pipeline = pipeline
            eventTask = Task { [weak self] in
                for await event in events {
                    switch event {
                    case .cue(let track, let cue): self?.addCue(cue, track: track)
                    case .endCue(let track, let time): self?.endCue(track: track, at: time)
                    case .error(let message): self?.report(message)
                    }
                }
            }
            tracks = pipeline.tracks
            videoSize = tracks.first { $0.kind == .video }.flatMap { track in
                guard let width = track.width, let height = track.height, width > 0, height > 0 else { return nil }
                return CGSize(width: width, height: height)
            }
            duration = pipeline.duration ?? 0
            chapters = pipeline.chapters.map { PlaybackChapter(title: $0.title, start: $0.start, end: $0.end) }
            trackList = Self.trackList(for: tracks)

            guard let video = tracks.first(where: { $0.kind == .video }) else {
                failure = "This file has no video track."
                return
            }
            guard video.codec.isSupported else {
                failure = "\(video.codec.displayName) video isn't supported yet. Supported: H.264, HEVC, AV1, MPEG-4 Part 2 (Xvid/DivX), and Motion JPEG."
                return
            }

            let resolved = (selection ?? .automatic).resolve(in: trackList)
            selectedAudioID = resolved.audio?.id
            selectedSubtitleID = resolved.subtitle?.id

            let videoReceiver = synchronizer.sampleBufferReceiver(adding: displayLayer.sampleBufferRenderer)
            let audioReceiver = synchronizer.sampleBufferReceiver(adding: audioRenderer)
            await pipeline.attach(video: videoReceiver, audio: audioReceiver)
            try await pipeline.configure(videoTrack: video.id, audioTrack: selectedAudioID.flatMap(Int.init))
            if resolved.audio == nil, tracks.contains(where: { $0.kind == .audio }) {
                warning = "This file's audio format isn't supported yet, so it will play without sound."
            }

            wantsPlay = true
            await begin(at: start)
            startClock()
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: Transport

    func play() {
        wantsPlay = true
        guard hasStarted, !isBuffering else { return }
        synchronizer.setRate(1, time: synchronizer.currentTime())
        isPlaying = true
    }

    func pause() {
        wantsPlay = false
        synchronizer.rate = 0
        isPlaying = false
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), max(duration - 0.5, 0))
        currentTime = target
        seekTask?.cancel()
        seekTask = Task { await begin(at: target) }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func selectAudio(_ id: String) {
        guard id != selectedAudioID, let pipeline, let video = tracks.first(where: { $0.kind == .video }) else { return }
        selectedAudioID = id
        let resume = currentTime
        Task {
            try? await pipeline.configure(videoTrack: video.id, audioTrack: Int(id))
            await begin(at: resume)
        }
    }

    func selectSubtitle(_ id: String?) {
        selectedSubtitleID = id
        updateSubtitle()
    }

    func shutdown() {
        clock?.cancel()
        seekTask?.cancel()
        eventTask?.cancel()
        synchronizer.rate = 0
        let pipeline = pipeline
        Task { await pipeline?.close() }
    }

    // MARK: Internals

    /// Restarts feeding at `time`, waits for enough buffered media, then resumes.
    private func begin(at time: Double) async {
        guard let pipeline else { return }
        isBuffering = true
        synchronizer.rate = 0
        let landing = await pipeline.start(at: time)
        synchronizer.setRate(0, time: CMTime(seconds: landing, preferredTimescale: 90_000))
        currentTime = landing

        // Prime: about half a second of each stream (or end of file).
        let hasAudio = await pipeline.hasAudio
        for _ in 0..<200 {
            if Task.isCancelled { return }
            let video = await pipeline.videoFedThrough
            let audio = await pipeline.audioFedThrough
            let atEnd = await pipeline.reachedEnd
            if atEnd || (video >= landing + 0.4 && (!hasAudio || audio >= landing + 0.4)) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        isBuffering = false
        hasStarted = true
        if wantsPlay {
            synchronizer.setRate(1, time: CMTime(seconds: landing, preferredTimescale: 90_000))
            isPlaying = true
        }
    }

    private func startClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                await self.tick()
            }
        }
    }

    private func tick() async {
        guard !isBuffering else { return }
        let now = synchronizer.currentTime().seconds
        if now.isFinite { currentTime = now }
        updateSubtitle()

        if isPlaying, let pipeline, await pipeline.reachedEnd {
            let fedThrough = await max(pipeline.videoFedThrough, pipeline.audioFedThrough)
            if currentTime >= fedThrough - 0.05 {
                synchronizer.rate = 0
                isPlaying = false
                currentTime = max(currentTime, duration)
            }
        }
    }

    private func addCue(_ cue: SubtitleCue, track: Int) {
        cues[track, default: [:]][cue.start] = cue
    }

    /// Closes the image subtitle that was showing when a later display set began or cleared.
    private func endCue(track: Int, at time: Double) {
        guard let open = cues[track]?.values.filter({ $0.start < time && $0.end > time }).max(by: { $0.start < $1.start }) else { return }
        cues[track]?[open.start]?.end = time
    }

    private func updateSubtitle() {
        guard let id = selectedSubtitleID.flatMap(Int.init), let trackCues = cues[id] else {
            subtitleText = nil
            subtitleBitmaps = []
            return
        }
        let now = currentTime
        let cue = trackCues.values.filter { $0.start <= now && now < $0.end }.max { $0.start < $1.start }
        let text = cue?.text ?? ""
        subtitleText = text.isEmpty ? nil : text
        let bitmaps = cue?.bitmaps ?? []
        if bitmaps != subtitleBitmaps { subtitleBitmaps = bitmaps }
    }

    private func report(_ message: String) {
        if hasStarted || failure != nil {
            warning = message
        } else {
            failure = message
        }
    }

    // MARK: Track descriptions

    static func trackList(for tracks: [ContainerTrack]) -> MediaTrackList {
        MediaTrackList(
            audio: tracks.filter { $0.kind == .audio }.map { track in
                TrackOption(id: String(track.id), kind: .audio, languageCode: track.language, name: track.name,
                            format: TrackFormatDescription.audio(codec: track.codec.displayName, channels: track.channels),
                            isDefault: track.isDefault, isSupported: track.codec.isSupported)
            },
            subtitles: tracks.filter { $0.kind == .subtitle }.map { track in
                let name = track.name ?? ""
                return TrackOption(id: String(track.id), kind: .subtitle, languageCode: track.language, name: track.name,
                                   format: track.codec.isSupported ? nil : track.codec.displayName,
                                   isForced: track.isForced, isSDH: name.localizedCaseInsensitiveContains("SDH"),
                                   isDefault: track.isDefault, isSupported: track.codec.isSupported)
            }
        )
    }
}

nonisolated enum TrackFormatDescription {
    /// "Dolby Digital 5.1", "AAC Stereo".
    static func audio(codec: String, channels: Int?) -> String {
        guard let channels else { return codec }
        let layout = switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels)ch"
        }
        return "\(codec) \(layout)"
    }
}

/// Reads a file's audio and subtitle tracks without starting playback.
enum MediaInspector {
    static func trackList(for url: URL) async -> MediaTrackList {
        let tracks = await Task.detached { (try? Demuxers.open(url))?.tracks ?? [] }.value
        return TheaterEngine.trackList(for: tracks)
    }
}
