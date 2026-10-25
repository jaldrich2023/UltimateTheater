//
//  FolderWatcher.swift
//  Ultimate Theater
//
//  Watches the library's folders with FSEvents and reports changed paths in batches.
//

import Foundation
import CoreServices

nonisolated final class FolderWatcher {
    /// A changed path and whether it was removed.
    struct Change: Sendable {
        let path: String
        let wasRemoved: Bool
    }

    private var stream: FSEventStreamRef?
    /// Called on the main actor: the stream delivers its events on the main queue.
    private let handler: @MainActor ([Change]) -> Void

    /// `latency` batches bursts of changes (a copy in progress fires many events).
    init?(paths: [String], latency: TimeInterval = 3, handler: @escaping @MainActor ([Change]) -> Void) {
        guard !paths.isEmpty else { return nil }
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            // Only used on the main queue (the stream's queue), where the handler runs.
            nonisolated(unsafe) let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let changes = (0..<count).compactMap { index -> Change? in
                guard index < list.count else { return nil }
                let flag = Int(flags[index])
                let removed = flag & kFSEventStreamEventFlagItemRemoved != 0
                    || (flag & kFSEventStreamEventFlagItemRenamed != 0 && !FileManager.default.fileExists(atPath: list[index]))
                return Change(path: list[index], wasRemoved: removed)
            }
            // The stream's dispatch queue is the main queue.
            MainActor.assumeIsolated { watcher.handler(changes) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
