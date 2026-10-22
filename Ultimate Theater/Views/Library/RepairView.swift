//
//  RepairView.swift
//  Ultimate Theater
//
//  Checks a movie file for damage and saves a repaired copy. A missing MP4 index is
//  rebuilt with help from a healthy movie made with the same encoder settings; other
//  damage (cut-off files, broken indexes, corrupt packets) is fixed directly.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Runs a repair in stages and publishes progress for the sheet.
@Observable
final class RepairSession {
    enum Phase {
        case checking
        case healthy
        case finding(String)
        case analyzing(Double)
        case review
        case writing(Double)
        case finished(MovieRepairReport, URL)
        case failed(String)
    }

    let title: Title
    let playbackID: String
    private(set) var phase: Phase = .checking
    /// Damage found by the diagnosis (for everything except a missing MP4 index).
    private(set) var plan: RepairPlan?
    private(set) var notes: [String] = []
    private(set) var report: MovieRepairReport?
    private var repairer: MovieRepairer?
    private var reference: RepairReference?
    private var analysis: MovieRepairer.Analysis?

    init(title: Title, playbackID: String) {
        self.title = title
        self.playbackID = playbackID
    }

    /// Diagnoses the file, then prepares the right repair.
    func start(library: MediaLibrary) async {
        let diagnosis: Result<RepairPlan?, Error>? = await library.withFileAccess(playbackID) { url in
            await Task.detached { Result { try MediaRepair.diagnose(url) } }.value
        }
        switch diagnosis {
        case .success(let plan?):
            if case .mp4MissingIndex = plan.kind {
                phase = .finding("Looking for a movie made with the same settings…")
                await rebuildIndex(library: library)
            } else {
                self.plan = plan
                phase = .review
            }
        case .success(nil): phase = .healthy
        case .failure(let error): phase = .failed(error.localizedDescription)
        case nil: phase = .failed("The file couldn't be opened. Its drive may be disconnected.")
        }
    }

    /// Finds a reference and analyzes a file whose MP4 index is missing.
    private func rebuildIndex(library: MediaLibrary) async {
        let candidates = library.repairCandidates(excluding: playbackID)
        let outcome: Result<Void, Error>? = await library.withFileAccess(playbackID) { damagedURL in
            do {
                let repairer = try await Task.detached { try MovieRepairer(damaged: damagedURL) }.value
                var found: RepairReference?
                for id in candidates where found == nil {
                    found = await library.withFileAccess(id) { url in
                        await MainActor.run { self.phase = .finding("Checking \(url.deletingPathExtension().lastPathComponent)…") }
                        return await Task.detached { repairer.matchingReference(from: [url]) }.value
                    } ?? nil
                }
                guard let reference = found else { throw MovieRepairError.noMatchingReference }
                phase = .analyzing(0)
                let analysis = try await Task.detached {
                    try repairer.analyze(with: reference) { fraction in
                        Task { @MainActor in if case .analyzing = self.phase { self.phase = .analyzing(fraction) } }
                    }
                }.value
                self.repairer = repairer
                self.reference = reference
                self.analysis = analysis
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success: phase = .review
        case .failure(let error): phase = .failed(error.localizedDescription)
        case nil: phase = .failed("The file couldn't be opened. Its drive may be disconnected.")
        }
    }

    var fileExtension: String { plan?.fileExtension ?? "mp4" }

    /// What the analysis found, for the review step.
    var summary: (frames: Int, duration: Double, audioTracks: Int, reference: String, size: String)? {
        guard let analysis, let reference else { return nil }
        let plan = TimingPlan(analysis: analysis, reference: reference)
        return (analysis.videoSamples.count, plan.duration, plan.audioTracks.count,
                reference.url.deletingPathExtension().lastPathComponent, "\(reference.width)×\(reference.height)")
    }

    func save(to output: URL, library: MediaLibrary) async {
        if let plan {
            phase = .writing(0)
            let result: Result<[String], Error>? = await library.withFileAccess(playbackID) { source in
                await Task.detached {
                    Result {
                        try MediaRepair.repair(plan, source: source, to: output) { fraction in
                            Task { @MainActor in if case .writing = self.phase { self.phase = .writing(fraction) } }
                        }
                    }
                }.value
            }
            switch result {
            case .success(let notes):
                self.notes = notes
                let duration = (try? Demuxers.open(output).duration) ?? nil
                phase = .finished(MovieRepairReport(referenceName: "", videoFrames: 0, keyframes: 0, audioFrames: [],
                                                    duration: duration ?? 0, frameRate: 0, unrecoveredBytes: 0), output)
            case .failure(let error): phase = .failed(error.localizedDescription)
            case nil: phase = .failed("The original file couldn't be read while saving.")
            }
            return
        }
        guard let repairer, let reference, let analysis else { return }
        phase = .writing(0)
        let result: Result<MovieRepairReport, Error>? = await library.withFileAccess(playbackID) { _ in
            await Task.detached {
                Result {
                    try repairer.write(analysis, reference: reference, to: output) { fraction in
                        Task { @MainActor in if case .writing = self.phase { self.phase = .writing(fraction) } }
                    }
                }
            }.value
        }
        switch result {
        case .success(let report):
            self.report = report
            phase = .finished(report, output)
        case .failure(let error): phase = .failed(error.localizedDescription)
        case nil: phase = .failed("The original file couldn't be read while saving.")
        }
    }
}

struct RepairView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var session: RepairSession
    @State private var didReplace = false

    init(title: Title, playbackID: String) {
        _session = State(initialValue: RepairSession(title: title, playbackID: playbackID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "bandage.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 52, height: 52)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repair \(session.title.name)")
                        .font(.title2.bold())
                    Text("Finds damage in the file and saves a repaired copy.")
                        .foregroundStyle(.secondary)
                }
            }
            content
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            actions
        }
        .padding(28)
        .frame(width: 560)
        .task { await session.start(library: model.library) }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .checking:
            step("Checking the file…", detail: "Looking for missing indexes, cut-off endings, and damaged data.") {
                ProgressView().controlSize(.small)
            }
        case .healthy:
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No damage found").font(.headline)
                    Text("The file's structure is intact. If it still won't play, its video or audio format may not be supported.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
        case .finding(let message):
            step(message, detail: "The damaged file is missing the information that describes its video and audio. A healthy movie made the same way can supply it.") {
                ProgressView().controlSize(.small)
            }
        case .analyzing(let fraction):
            step("Reading the damaged file…", detail: "Finding every video frame and audio packet.") {
                ProgressView(value: fraction).frame(width: 260)
            }
        case .review:
            if let plan = session.plan {
                VStack(alignment: .leading, spacing: 12) {
                    Label("\(plan.format) file with damage", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    ForEach(plan.findings, id: \.self) { finding in
                        Label(finding, systemImage: "circle.fill")
                            .labelStyle(BulletLabelStyle())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("The original file isn't changed. A repaired copy is saved where you choose.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let summary = session.summary {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Ready to repair", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        row("Recoverable", Self.format(summary.duration))
                        row("Video", "\(summary.frames.formatted()) frames, \(summary.size)")
                        row("Audio tracks", "\(summary.audioTracks)")
                        row("Setup from", summary.reference)
                    }
                    if let note = truncationNote(summary.duration) {
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("The original file isn't changed. A repaired copy is saved where you choose.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .writing(let fraction):
            step("Saving the repaired copy…", detail: "Copying the movie and writing a new index.") {
                ProgressView(value: fraction).frame(width: 260)
            }
        case .finished(let report, let url):
            VStack(alignment: .leading, spacing: 10) {
                Label(didReplace ? "Your library now uses the repaired copy." : "Repaired copy saved.", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                if session.notes.isEmpty {
                    Text("\(Self.format(report.duration)) of video with \(report.audioFrames.count) audio track\(report.audioFrames.count == 1 ? "" : "s").")
                } else {
                    ForEach(session.notes, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                }
                Text(url.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        case .failed(let message):
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            Spacer()
            switch session.phase {
            case .review:
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
                Button("Save Repaired Copy…", action: chooseDestination)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            case .finished(_, let url):
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.glass)
                if !didReplace {
                    Button("Use in Library") {
                        Task {
                            await model.library.replaceFile(session.playbackID, with: url)
                            didReplace = true
                        }
                    }
                    .buttonStyle(.glass)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            case .failed, .healthy:
                Button("Close") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            default:
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
            }
        }
        .controlSize(.large)
    }

    private func step<Accessory: View>(_ title: String, detail: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                accessory()
                Text(title).font(.headline)
            }
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    /// When the file holds clearly less than the movie's runtime, the copy was cut short.
    private func truncationNote(_ recovered: Double) -> String? {
        let runtime = Double(session.title.runtimeMinutes) * 60
        guard runtime > 0, recovered < runtime * 0.9 else { return nil }
        return "This file only contains the first \(Self.format(recovered)) of the movie's \(Self.format(runtime)). The rest was never copied into it, so the repaired copy ends there too. Copying the movie again from its source will restore the full length."
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Save Repaired Copy"
        panel.nameFieldStringValue = "\(session.title.name) (Repaired).\(session.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: session.fileExtension) ?? .movie]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await session.save(to: url, library: model.library) }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours) hr \(minutes) min" : "\(minutes) min \(total % 60) sec"
    }
}

/// A small bullet before each finding.
private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.secondary)
            configuration.title
        }
    }
}
