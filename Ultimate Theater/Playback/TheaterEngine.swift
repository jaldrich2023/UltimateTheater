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
import os

// MARK: - Pipeline

/// Messages from the pipeline to the engine.
nonisolated enum PipelineEvent: Sendable {
    case cue(track: Int, SubtitleCue)
    /// Ends the open image subtitle on a track.
    case endCue(track: Int, at: Double)
    case error(String)
}

/// A first-in, first-out packet queue with constant-time removal from the front and a
/// running byte total, so reading ahead can pause when one stream's backlog grows too large.
/// The backlog is measured in time, so streams with many small packets (TrueHD's 1,200 a
/// second) get as much slack as any other.
nonisolated struct PacketQueue {
    /// This much media time, or this many bytes, whichever comes first…
    static let defaultSpanLimit: Double = 20
    static let defaultByteLimit = 128 << 20
    /// …with a packet count only as a backstop for timestamps that don't advance.
    static let defaultPacketLimit = 200_000

    let packetLimit: Int
    let byteLimit: Int
    let spanLimit: Double
    /// Taken packets are cleared at once so their data is released; the storage is compacted later.
    private var storage: [MediaPacket?] = []
    private var head = 0
    private(set) var byteCount = 0
    /// Latest finite timestamp queued since the queue was last emptied.
    private var newestPTS = -Double.infinity

    init(packetLimit: Int = Self.defaultPacketLimit, byteLimit: Int = Self.defaultByteLimit,
         spanLimit: Double = Self.defaultSpanLimit) {
        self.packetLimit = packetLimit
        self.byteLimit = byteLimit
        self.spanLimit = spanLimit
    }

    var count: Int { storage.count - head }
    var isEmpty: Bool { head == storage.count }
    /// Media time from the first queued packet to the latest (zero without usable timestamps).
    var span: Double {
        guard let first, first.pts.isFinite, newestPTS.isFinite else { return 0 }
        return max(newestPTS - first.pts, 0)
    }
    /// The backlog is at its limit: reading ahead should wait for this stream to catch up.
    var isFull: Bool { count >= packetLimit || byteCount >= byteLimit || span >= spanLimit }
    var first: MediaPacket? { head < storage.count ? storage[head] : nil }

    mutating func append(_ packet: MediaPacket) {
        storage.append(packet)
        byteCount += packet.data.count
        if packet.pts.isFinite { newestPTS = max(newestPTS, packet.pts) }
    }

    mutating func append(contentsOf packets: [MediaPacket]) {
        for packet in packets { append(packet) }
    }

    mutating func popFirst() -> MediaPacket? {
        guard head < storage.count, let packet = storage[head] else { return nil }
        storage[head] = nil
        head += 1
        byteCount -= packet.data.count
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
            newestPTS = -.infinity
        } else if head >= 1024, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return packet
    }

    /// Drops the packets ahead of the first keyframe. Returns how many were dropped.
    @discardableResult
    mutating func dropUntilKeyframe() -> Int {
        var dropped = 0
        while let packet = first, !packet.isKeyframe {
            _ = popFirst()
            dropped += 1
        }
        return dropped
    }

    mutating func removeAll() {
        storage.removeAll()
        head = 0
        byteCount = 0
        newestPTS = -.infinity
    }
}

/// What the engine polls while buffering and playing. Published under a lock so reading it
/// never waits behind the pipeline's demuxing.
nonisolated struct PipelineProgress: Sendable, Equatable {
    /// Latest timestamps handed to each renderer.
    var videoFedThrough = -Double.infinity
    var audioFedThrough = -Double.infinity
    /// Where the media handed to the renderers ends (latest timestamp plus its duration).
    var fedEnd = -Double.infinity
    /// Every packet has been read and handed to its renderer.
    var reachedEnd = false
    /// False for a stream that isn't playing, including one stopped after repeated failures
    /// (it's tried again at the next seek).
    var isVideoActive = false
    var isAudioActive = false
}

/// One track's formatter, used only on its own serial queue, so software decoding of one
/// stream (MPEG-4 Part 2, VP8, Theora, DTS, TrueHD) can't hold up the other stream or the
/// pipeline. Work runs in the order it's submitted.
nonisolated final class FormatterLane: @unchecked Sendable {
    let track: ContainerTrack
    /// The picture comes from the engine's own decoder rather than VideoToolbox.
    let decodesVideoInSoftware: Bool
    private let formatter: TrackFormatter
    private let queue: DispatchQueue

    init(track: ContainerTrack) throws {
        formatter = try TrackFormatter(track: track)
        self.track = track
        decodesVideoInSoftware = track.kind == .video && [.vp8, .theora, .mpeg4Part2].contains(track.codec)
        queue = DispatchQueue(label: "Theater.formatter.\(track.id)", qos: .userInitiated)
    }

    /// Resets per-stream state after any conversion already submitted.
    func reset() {
        queue.async { self.formatter.reset() }
    }

    func sampleBuffers(for packet: MediaPacket) async throws -> [CMSampleBuffer] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.formatter.sampleBuffers(for: packet) })
            }
        }
    }
}

/// Owns the demuxer and feeds the renderers. Runs off the main actor; each renderer
/// has its own feeder so neither can starve the other.
actor TheaterPipeline {
    nonisolated let tracks: [ContainerTrack]
    nonisolated let duration: Double?
    nonisolated let chapters: [ContainerChapter]

    /// Consecutive failures after which a stream stops until the next seek.
    static let failureLimit = 48

    private let demuxer: any MediaDemuxer
    private var videoReceiver: AVSampleBufferVideoRenderer.Receiver?
    private var audioReceiver: AVSampleBufferAudioRenderer.Receiver?
    private var videoLane: FormatterLane?
    private var audioLane: FormatterLane?
    private var subtitleTrackIDs: Set<Int> = []
    private var pgsDecoders: [Int: PGSDecoder] = [:]
    private var vobSubDecoders: [Int: VobSubDecoder] = [:]
    private var dvbDecoders: [Int: DVBSubtitleDecoder] = [:]
    private var teletextDecoders: [Int: TeletextDecoder] = [:]
    private let events: AsyncStream<PipelineEvent>.Continuation

    private var videoQueue = PacketQueue()
    private var audioQueue = PacketQueue()
    private var isAtEnd = false
    private var awaitingKeyframe = true
    private var reconstructor: DisplayOrderReconstructor?
    private var generation = 0
    private var feeders: [Task<Void, Never>] = []
    private var isVideoActive = false
    private var isAudioActive = false
    private var isClosed = false

    /// Latest timestamps handed to each renderer, for buffering decisions.
    private(set) var videoFedThrough = -Double.infinity
    private(set) var audioFedThrough = -Double.infinity
    private var fedEnd = -Double.infinity
    /// A packet taken from each queue is still being converted or enqueued.
    private var isVideoInFlight = false
    private var isAudioInFlight = false
    /// Latest timestamp read from the file, where reading continues if a seek fails.
    private var demuxedThrough = -Double.infinity
    /// Feeders waiting for the other stream's backlog to shrink.
    private var roomWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated private let progressLock = OSAllocatedUnfairLock(initialState: PipelineProgress())
    /// The feeding state, readable from any thread without waiting for the pipeline.
    nonisolated var progress: PipelineProgress { progressLock.withLock { $0 } }

    private enum Next {
        case packet(MediaPacket)
        /// The other stream's backlog is full; try again once it shrinks.
        case wait
        case end
    }

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

    var hasVideo: Bool { videoLane != nil }
    var hasAudio: Bool { audioLane != nil }
    /// Everything was read, and the last packets have reached their renderers (not just left
    /// the queues: conversion takes a moment, and ending then would cut off the last frame).
    var reachedEnd: Bool {
        isAtEnd && videoQueue.isEmpty && audioQueue.isEmpty
            && !(isVideoActive && isVideoInFlight) && !(isAudioActive && isAudioInFlight)
    }

    private func publishProgress() {
        let snapshot = PipelineProgress(videoFedThrough: videoFedThrough, audioFedThrough: audioFedThrough, fedEnd: fedEnd,
                                        reachedEnd: reachedEnd, isVideoActive: isVideoActive, isAudioActive: isAudioActive)
        progressLock.withLock { $0 = snapshot }
    }

    /// Suspends a feeder until the other stream's backlog shrinks (or feeding restarts).
    /// Checking for room and waiting happen in one turn of the actor, so no wake-up is missed.
    private func waitForRoom() async {
        await withCheckedContinuation { continuation in
            roomWaiters.append(continuation)
        }
    }

    private func wakeWaiters() {
        guard !roomWaiters.isEmpty else { return }
        let waiters = roomWaiters
        roomWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Notes media handed to a renderer. Durations from damaged files can't push the end out.
    private func noteFed(_ packet: MediaPacket) {
        guard packet.pts.isFinite else { return }
        let length = packet.duration.flatMap { $0.isFinite && $0 > 0 ? min($0, 10) : nil } ?? 0
        fedEnd = max(fedEnd, packet.pts + length)
    }

    func attach(video: sending AVSampleBufferVideoRenderer.Receiver, audio: sending AVSampleBufferAudioRenderer.Receiver) {
        videoReceiver = video
        audioReceiver = audio
    }

    /// Chooses tracks. Unsupported codecs throw with a readable message.
    func configure(videoTrack: Int?, audioTrack: Int?) throws {
        guard !isClosed else { return }
        // Nothing may feed from the old formatters or queues while they're replaced.
        stopFeeding()
        clearQueues()
        videoLane = try videoTrack.flatMap { id in tracks.first { $0.id == id } }.map(FormatterLane.init)
        do {
            audioLane = try audioTrack.flatMap { id in tracks.first { $0.id == id } }.map(FormatterLane.init)
        } catch {
            audioLane = nil // Play the picture even if this audio format can't be decoded.
            onError("Audio: \(error.localizedDescription)")
        }
        subtitleTrackIDs = Set(tracks.filter { $0.kind == .subtitle && $0.codec.isSupported }.map(\.id))
        demuxer.enabledTrackIDs = Set([videoLane?.track.id, audioLane?.track.id].compactMap { $0 })
            .union(subtitleTrackIDs)
    }

    /// Positions at the keyframe at or before `time`, then starts feeding. Returns the landing time.
    /// If the seek fails, reading carries on from where it was, and the landing says so.
    func start(at time: Double) -> Double {
        stopFeeding()
        guard !isClosed else { return time }
        let landing: Double
        do {
            landing = try demuxer.seek(to: time)
            demuxedThrough = -.infinity
        } catch {
            onError(error.localizedDescription)
            // The demuxer didn't move: reading resumes after the last packet read (the start
            // of the file if nothing was read yet).
            landing = demuxedThrough.isFinite ? demuxedThrough : 0
        }
        clearQueues()
        isAtEnd = false
        awaitingKeyframe = true
        videoFedThrough = -.infinity
        audioFedThrough = -.infinity
        fedEnd = -.infinity
        videoLane?.reset()
        audioLane?.reset()
        // MPEG-4 Part 2 is reordered by its own decoder; AVI H.264 needs display times rebuilt.
        if let track = videoLane?.track, track.isAnnexB, demuxer is AVIDemuxer {
            reconstructor = DisplayOrderReconstructor(frameDuration: track.frameDuration ?? 1.0 / 25, startTime: landing)
        } else {
            reconstructor = nil
        }
        generation += 1
        let current = generation
        isVideoActive = videoReceiver != nil && videoLane != nil
        isAudioActive = audioReceiver != nil && audioLane != nil
        if isVideoActive {
            feeders.append(Task { await self.feedVideo(generation: current) })
        }
        if isAudioActive {
            feeders.append(Task { await self.feedAudio(generation: current) })
        }
        publishProgress()
        return landing
    }

    func stopFeeding() {
        generation += 1
        feeders.forEach { $0.cancel() }
        feeders = []
        isVideoInFlight = false
        isAudioInFlight = false
        wakeWaiters() // Cancelled feeders waiting for room see the new generation and stop.
        videoReceiver?.flush()
        audioReceiver?.flush()
    }

    private func clearQueues() {
        videoQueue.removeAll()
        audioQueue.removeAll()
        wakeWaiters()
    }

    /// Stops feeding, clears the last displayed frame, and takes the renderers out of `synchronizer`.
    func close(removingFrom synchronizer: AVSampleBufferRenderSynchronizer? = nil) async {
        isClosed = true
        stopFeeding()
        clearQueues()
        isVideoActive = false
        isAudioActive = false
        publishProgress()
        await videoReceiver?.flush(removingDisplayedImage: true)
        if let synchronizer {
            let time = synchronizer.currentTime()
            // The receivers are taken out of the pipeline here and used nowhere else.
            if let taken = videoReceiver.take() {
                nonisolated(unsafe) let receiver = taken
                _ = await synchronizer.removeReceiver(receiver, at: time)
            }
            if let taken = audioReceiver.take() {
                nonisolated(unsafe) let receiver = taken
                _ = await synchronizer.removeReceiver(receiver, at: time)
            }
        }
        events.finish()
    }

    // MARK: Feeding

    private func feedVideo(generation current: Int) async {
        var failures = 0
        // After a decoder restart, frames that depend on earlier ones are skipped until a sync frame.
        var needsSync = false
        while current == generation, !Task.isCancelled {
            let packet: MediaPacket
            switch nextPacket(video: true) {
            case .packet(let next): packet = next
            case .wait:
                await waitForRoom()
                continue
            case .end: return
            }
            isVideoInFlight = true
            defer { finishPacket(video: true, generation: current) }
            guard let lane = videoLane, let receiver = videoReceiver else { return }
            let samples: [CMSampleBuffer]
            do {
                samples = try await lane.sampleBuffers(for: packet)
            } catch {
                guard current == generation else { return }
                if countFailure(video: true, error.localizedDescription, reportsFirst: true, failures: &failures) { return }
                if !lane.decodesVideoInSoftware {
                    needsSync = true
                    resyncVideoQueue()
                }
                continue
            }
            feeding: for sample in samples {
                guard current == generation else { return }
                if needsSync {
                    guard Self.isSync(sample) else { continue }
                    needsSync = false
                }
                var failure: String?
                // Each sample buffer goes to the renderer once and isn't touched afterwards.
                nonisolated(unsafe) let handedOff = sample
                let ready = CMReadySampleBuffer(unsafeBuffer: handedOff)
                do {
                    switch try await receiver.enqueue(ready) {
                    case .cancelledDueToFlushRequiredToResume:
                        guard current == generation else { return }
                        receiver.flush()
                        // Decoded pictures stand alone; compressed frames must restart at a keyframe.
                        if !lane.decodesVideoInSoftware {
                            needsSync = true
                            resyncVideoQueue()
                        }
                    case .cancelledDueToError(let error):
                        failure = error.localizedDescription
                    case .cancelledDueToFlush:
                        break
                    default:
                        failures = 0
                    }
                } catch {
                    guard current == generation, !Task.isCancelled else { return }
                    failure = error.localizedDescription
                }
                if let failure {
                    guard current == generation else { return }
                    receiver.flush() // A failed renderer recovers only after a flush.
                    if countFailure(video: true, failure, reportsFirst: true, failures: &failures) { return }
                    if !lane.decodesVideoInSoftware {
                        needsSync = true
                        resyncVideoQueue()
                    }
                    break feeding
                }
            }
            if current == generation {
                videoFedThrough = max(videoFedThrough, packet.pts)
                noteFed(packet)
                publishProgress()
            }
        }
    }

    private func feedAudio(generation current: Int) async {
        var failures = 0
        while current == generation, !Task.isCancelled {
            let packet: MediaPacket
            switch nextPacket(video: false) {
            case .packet(let next): packet = next
            case .wait:
                await waitForRoom()
                continue
            case .end: return
            }
            isAudioInFlight = true
            defer { finishPacket(video: false, generation: current) }
            guard let lane = audioLane, let receiver = audioReceiver else { return }
            let samples: [CMSampleBuffer]
            do {
                samples = try await lane.sampleBuffers(for: packet)
            } catch {
                // A damaged frame is skipped; only a long run of them stops the sound.
                guard current == generation else { return }
                if countFailure(video: false, error.localizedDescription, reportsFirst: false, failures: &failures) { return }
                continue
            }
            feeding: for sample in samples {
                guard current == generation else { return }
                var failure: String?
                // Each sample buffer goes to the renderer once and isn't touched afterwards.
                nonisolated(unsafe) let handedOff = sample
                let ready = CMReadySampleBuffer(unsafeBuffer: handedOff)
                do {
                    switch try await receiver.enqueue(ready) {
                    case .cancelledDueToError(let error):
                        failure = error.localizedDescription
                    case .cancelledDueToFlush:
                        break
                    default:
                        failures = 0
                    }
                } catch {
                    guard current == generation, !Task.isCancelled else { return }
                    failure = error.localizedDescription
                }
                if let failure {
                    guard current == generation else { return }
                    receiver.flush() // A failed renderer recovers only after a flush.
                    if countFailure(video: false, failure, reportsFirst: true, failures: &failures) { return }
                    break feeding
                }
            }
            if current == generation {
                audioFedThrough = max(audioFedThrough, packet.pts)
                noteFed(packet)
                publishProgress()
            }
        }
    }

    /// A packet taken from a queue is done with (fed, skipped, or abandoned).
    private func finishPacket(video: Bool, generation current: Int) {
        guard current == generation else { return } // A restart already reset the state.
        if video { isVideoInFlight = false } else { isAudioInFlight = false }
        if isAtEnd { publishProgress() }
    }

    /// Counts one failure. After `failureLimit` in a row the stream stops until the next seek,
    /// and the other stream plays on to the end. Returns true when the stream stopped.
    private func countFailure(video: Bool, _ message: String, reportsFirst: Bool, failures: inout Int) -> Bool {
        failures += 1
        if failures == 1, reportsFirst { onError(message) }
        guard failures >= Self.failureLimit else { return false }
        if video {
            isVideoActive = false
            videoQueue.removeAll()
            wakeWaiters()
            reconstructor = nil
            onError("The picture stopped after repeated errors: \(message)")
        } else {
            isAudioActive = false
            audioQueue.removeAll()
            wakeWaiters()
            onError("The sound stopped after repeated errors: \(message)")
        }
        // With nothing left reading the file, it has ended as far as playback goes.
        if !isVideoActive, !isAudioActive { isAtEnd = true }
        publishProgress()
        return true
    }

    /// Frames queued after a decoder restart can't be decoded until the next keyframe.
    private func resyncVideoQueue() {
        if videoQueue.dropUntilKeyframe() > 0 { wakeWaiters() }
        if videoQueue.isEmpty { awaitingKeyframe = true }
    }

    private static func isSync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              let first = (attachments as NSArray).firstObject as? NSDictionary else { return true }
        return (first.object(forKey: kCMSampleAttachmentKey_NotSync) as? Bool) != true
    }

    /// Next packet for one renderer, demuxing (and queueing the other's packets) as needed.
    private func nextPacket(video: Bool) -> Next {
        defer { if isAtEnd { publishProgress() } }
        while true {
            // Taking a packet from a full backlog makes room: wake the other feeder, which may be
            // waiting on it.
            let wasFull = video ? videoQueue.isFull : audioQueue.isFull
            if let packet = video ? videoQueue.popFirst() : audioQueue.popFirst() {
                if wasFull { wakeWaiters() }
                return .packet(packet)
            }
            if isAtEnd { return .end }
            // Back-pressure: badly interleaved files would otherwise queue the other stream without limit.
            if video ? audioQueue.isFull : videoQueue.isFull { return .wait }
            do {
                if let packet = try demuxer.nextPacket() {
                    if packet.pts.isFinite { demuxedThrough = max(demuxedThrough, packet.pts) }
                    route(packet)
                } else {
                    isAtEnd = true
                    if var reconstructor {
                        if isVideoActive { videoQueue.append(contentsOf: reconstructor.flush()) }
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
        if packet.trackID == videoLane?.track.id {
            if isVideoActive { routeVideo(packet) }
        } else if packet.trackID == audioLane?.track.id {
            if isAudioActive { audioQueue.append(packet) }
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
        guard var reconstructor else {
            videoQueue.append(packet)
            return
        }
        // AVI stores H.264 frames in decode order with frame-rate timing; rebuild display times.
        videoQueue.append(contentsOf: reconstructor.push(packet, isBFrame: AnnexB.h264IsBSlice(packet.data)))
        self.reconstructor = reconstructor
    }
}

// MARK: - Subtitle cues

/// One embedded subtitle track's cues, sorted by start time so the one showing is found by
/// binary search. A cue with the same start as an earlier one replaces it.
nonisolated struct SubtitleCueStore {
    /// Image cues that ended this long before the playhead are dropped (seeking back decodes
    /// them again)…
    static let imageRetention: Double = 60
    /// …and so are image cues this far ahead, left over from before a seek back.
    static let imageLookahead: Double = 600

    private(set) var cues: [SubtitleCue] = []
    /// The longest finite cue, which bounds how far back a cue can still be showing.
    private var longestSpan: Double = 0
    /// Starts of cues still waiting for their end.
    private var openStarts: [Double] = []

    var count: Int { cues.count }

    /// The first index whose cue starts after `time` (`inclusive`) or at or after it.
    private func boundary(_ time: Double, inclusive: Bool) -> Int {
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if inclusive ? cues[middle].start <= time : cues[middle].start < time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private mutating func note(_ cue: SubtitleCue) {
        if cue.end.isFinite {
            longestSpan = max(longestSpan, cue.end - cue.start)
        } else if cue.end == .infinity {
            openStarts.append(cue.start)
        }
    }

    private mutating func forgetOpen(_ start: Double) {
        if let index = openStarts.firstIndex(of: start) { openStarts.remove(at: index) }
    }

    mutating func insert(_ cue: SubtitleCue) {
        let index = boundary(cue.start, inclusive: false)
        if index < cues.count, cues[index].start == cue.start {
            if cues[index].end == .infinity { forgetOpen(cue.start) }
            cues[index] = cue
        } else {
            cues.insert(cue, at: index)
        }
        note(cue)
    }

    /// The latest-starting cue that began at (`inclusive`) or before `time` and hasn't ended by then.
    private func showingIndex(at time: Double, inclusive: Bool) -> Int? {
        var index = boundary(time, inclusive: inclusive)
        let earliest = min(time - longestSpan, openStarts.min() ?? .infinity)
        while index > 0 {
            index -= 1
            if cues[index].start < earliest { return nil }
            if cues[index].end > time { return index }
        }
        return nil
    }

    /// The cue on screen at `time`; overlapping cues show the latest.
    func cue(at time: Double) -> SubtitleCue? {
        showingIndex(at: time, inclusive: true).map { cues[$0] }
    }

    /// Closes the cue that was showing when a later display set began or cleared.
    mutating func end(at time: Double) {
        guard let index = showingIndex(at: time, inclusive: false) else { return }
        if cues[index].end == .infinity { forgetOpen(cues[index].start) }
        cues[index].end = time
        note(cues[index])
    }

    /// Drops image cues far from the playhead; their bitmaps are large.
    mutating func evictImages(around now: Double) {
        let past = now - Self.imageRetention
        let future = now + Self.imageLookahead
        let before = cues.count
        cues.removeAll { !$0.bitmaps.isEmpty && ($0.end < past || $0.start > future) }
        if cues.count != before {
            openStarts = cues.filter { $0.end == .infinity }.map(\.start)
        }
    }
}

// MARK: - Engine

@Observable
final class TheaterEngine {
    let displayLayer = AVSampleBufferDisplayLayer()

    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    /// `currentTime` rounded down to a quarter second: changes at most four times a second,
    /// for views that don't need every clock tick.
    private(set) var displayTime: Double = 0
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

    /// Core Audio output device UID for the sound (an AirPlay device included); nil follows
    /// the Mac's sound output setting.
    var audioOutputDeviceID: String? {
        didSet {
            if audioOutputDeviceID != oldValue { audioRenderer.audioOutputDeviceUniqueID = audioOutputDeviceID }
        }
    }

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    @ObservationIgnored private var pipeline: TheaterPipeline?
    @ObservationIgnored private var tracks: [ContainerTrack] = []
    @ObservationIgnored private var cues: [Int: SubtitleCueStore] = [:]
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    /// The seek or track change in progress; each new one cancels it and runs after it.
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var wantsPlay = false
    /// The pipeline has its renderers and tracks; until then seeks wait for the first start.
    @ObservationIgnored private var isConfigured = false
    /// A seek made while loading, where playback starts instead.
    @ObservationIgnored private var pendingStart: Double?
    /// Set by `shutdown`: a load still in progress stops at its next step.
    @ObservationIgnored private var isShutDown = false
    /// Cues of sidecar and downloaded subtitles, by track ID ("ext:…"), timed by the player clock.
    @ObservationIgnored private var externalCues: [String: [SubtitleCue]] = [:]
    /// What "Find Subtitles…" searches for while this file plays.
    var subtitleSearchTarget: SubtitleSearchTarget?

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor.black
    }

    /// Opens a file and starts playing from `start`, honoring a saved track selection.
    func load(_ url: URL, start: Double, selection: PlaybackSelection?, externalSubtitles: [ExternalSubtitle] = []) async {
        guard !isShutDown else { return }
        do {
            let (events, continuation) = AsyncStream.makeStream(of: PipelineEvent.self)
            let pipeline = try await TheaterPipeline.open(url, events: continuation)
            guard !isShutDown else {
                await pipeline.close()
                return
            }
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
            // A non-finite or absurd duration (damage) counts as unknown.
            duration = FormatValidation.duration(pipeline.duration) ?? 0
            chapters = pipeline.chapters.map { PlaybackChapter(title: $0.title, start: $0.start, end: $0.end) }
            trackList = Self.trackList(for: tracks)
            for subtitle in externalSubtitles { await loadExternal(subtitle) }
            guard !isShutDown else { return }

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
            guard !isShutDown else { return }
            try await pipeline.configure(videoTrack: video.id, audioTrack: selectedAudioID.flatMap(Int.init))
            guard !isShutDown else { return }
            if resolved.audio == nil, tracks.contains(where: { $0.kind == .audio }) {
                warning = "This file's audio format isn't supported yet, so it will play without sound."
            }

            wantsPlay = true
            isConfigured = true
            let first = pendingStart ?? start
            pendingStart = nil
            await schedule { [weak self] in await self?.begin(at: first) }.value
            guard !isShutDown else { return }
            startClock()
        } catch {
            guard !isShutDown else { return }
            failure = error.localizedDescription
        }
    }

    // MARK: Transport

    func play() {
        wantsPlay = true
        guard hasStarted, !isBuffering, !isShutDown else { return }
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

    /// Where a seek to `seconds` lands: within the file, short of its very end. Files whose
    /// length isn't known (live WebM, broadcast recordings) are only kept from going negative.
    nonisolated static func seekTarget(_ seconds: Double, duration: Double) -> Double {
        guard !seconds.isNaN else { return 0 }
        if duration > 0, duration.isFinite {
            return min(max(seconds, 0), max(duration - 0.5, 0))
        }
        return seconds.isFinite ? min(max(seconds, 0), FormatValidation.maximumDuration) : 0
    }

    /// A time safe to show and to hand Core Media: finite and in range, else zero.
    nonisolated static func sanitizedTime(_ seconds: Double) -> Double {
        FormatValidation.duration(seconds) ?? 0
    }

    func seek(to seconds: Double) {
        let target = Self.seekTarget(seconds, duration: duration)
        setTime(target)
        guard !isShutDown else { return }
        guard isConfigured else {
            // Still loading: playback starts at the latest seek instead.
            pendingStart = target
            return
        }
        schedule { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.begin(at: target)
        }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func selectAudio(_ id: String) {
        guard id != selectedAudioID, !isShutDown else { return }
        guard isConfigured else {
            selectedAudioID = id // Still loading: the first configuration uses it.
            return
        }
        guard let pipeline, let video = tracks.first(where: { $0.kind == .video }) else { return }
        selectedAudioID = id
        let resume = currentTime
        schedule { [weak self] in
            // Always applied, even when a later seek takes over the restart.
            try? await pipeline.configure(videoTrack: video.id, audioTrack: Int(id))
            guard !Task.isCancelled else { return }
            await self?.begin(at: resume)
        }
    }

    func selectSubtitle(_ id: String?) {
        selectedSubtitleID = id
        updateSubtitle()
    }

    /// Adds a subtitle file (e.g. just downloaded) as a track and shows it.
    func addExternalSubtitle(_ subtitle: ExternalSubtitle) async {
        await loadExternal(subtitle)
        if externalCues[subtitle.id] != nil { selectSubtitle(subtitle.id) }
    }

    /// Parses an external subtitle off the main actor and lists it; unreadable files are listed as unsupported.
    private func loadExternal(_ subtitle: ExternalSubtitle) async {
        let url = subtitle.url
        let cues = await Task.detached { try? SubtitleFileParser.parse(contentsOf: url) }.value
        var option = subtitle.trackOption
        if let cues {
            externalCues[subtitle.id] = cues
        } else {
            option.isSupported = false
        }
        trackList.subtitles.removeAll { $0.id == subtitle.id }
        trackList.subtitles.append(option)
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        wantsPlay = false
        clock?.cancel()
        seekTask?.cancel()
        eventTask?.cancel()
        synchronizer.rate = 0
        let pipeline = pipeline
        let synchronizer = synchronizer
        Task { await pipeline?.close(removingFrom: synchronizer) }
    }

    // MARK: Internals

    /// Runs `work` after the seek or track change in progress, which is cancelled first.
    @discardableResult
    private func schedule(_ work: @escaping () async -> Void) -> Task<Void, Never> {
        let previous = seekTask
        previous?.cancel()
        let task = Task {
            await previous?.value
            await work()
        }
        seekTask = task
        return task
    }

    private func setTime(_ time: Double) {
        let seconds = Self.sanitizedTime(time)
        if seconds != currentTime { currentTime = seconds }
        let shown = seconds.isFinite ? (seconds * 4).rounded(.down) / 4 : seconds
        if shown != displayTime { displayTime = shown }
    }

    /// Restarts feeding at `time`, waits for enough buffered media, then resumes.
    private func begin(at time: Double) async {
        guard let pipeline, isConfigured, !isShutDown else { return }
        isBuffering = true
        synchronizer.rate = 0
        // A damaged file can report a landing no clock can represent.
        let landing = Self.sanitizedTime(await pipeline.start(at: time))
        guard !isShutDown, !Task.isCancelled else { return }
        synchronizer.setRate(0, time: CMTime(seconds: landing, preferredTimescale: 90_000))
        setTime(landing)

        // Prime: about half a second of each stream (or end of file).
        for _ in 0..<200 {
            if Task.isCancelled || isShutDown { return }
            let progress = pipeline.progress
            let videoReady = !progress.isVideoActive || progress.videoFedThrough >= landing + 0.4
            let audioReady = !progress.isAudioActive || progress.audioFedThrough >= landing + 0.4
            if progress.reachedEnd || (videoReady && audioReady) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard !isShutDown else { return }
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
                self.tick()
            }
        }
    }

    private func tick() {
        guard !isBuffering, !isShutDown else { return }
        let now = synchronizer.currentTime().seconds
        if FormatValidation.duration(now) != nil { setTime(now) }
        updateSubtitle()

        if isPlaying, let progress = pipeline?.progress, progress.reachedEnd {
            // Ends once the last frame has had its time on screen, not when it starts.
            let fedThrough = max(progress.videoFedThrough, progress.audioFedThrough, progress.fedEnd)
            if currentTime >= fedThrough - 0.05 {
                synchronizer.rate = 0
                isPlaying = false
                setTime(max(currentTime, duration))
            }
        }
    }

    private func addCue(_ cue: SubtitleCue, track: Int) {
        cues[track, default: SubtitleCueStore()].insert(cue)
        if !cue.bitmaps.isEmpty { cues[track]?.evictImages(around: currentTime) }
    }

    /// Closes the image subtitle that was showing when a later display set began or cleared.
    private func endCue(track: Int, at time: Double) {
        cues[track]?.end(at: time)
    }

    private func updateSubtitle() {
        if let id = selectedSubtitleID, let external = externalCues[id] {
            let now = currentTime
            // Overlapping SubRip cues show together.
            let text = external.filter { $0.start <= now && now < $0.end }.map(\.text).joined(separator: "\n")
            let shown = text.isEmpty ? nil : text
            if shown != subtitleText { subtitleText = shown }
            if !subtitleBitmaps.isEmpty { subtitleBitmaps = [] }
            return
        }
        guard let id = selectedSubtitleID.flatMap(Int.init), let trackCues = cues[id] else {
            if subtitleText != nil { subtitleText = nil }
            if !subtitleBitmaps.isEmpty { subtitleBitmaps = [] }
            return
        }
        let cue = trackCues.cue(at: currentTime)
        let text = cue?.text ?? ""
        let shown = text.isEmpty ? nil : text
        if shown != subtitleText { subtitleText = shown }
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
