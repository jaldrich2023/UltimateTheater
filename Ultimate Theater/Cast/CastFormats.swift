//
//  CastFormats.swift
//  Ultimate Theater
//
//  Which files each kind of casting device can play. Casting sends the original file (there
//  is no transcoding), so the device's own player must understand the container and the
//  codecs; when it can't, the Cast menu says why instead of failing on the TV.
//

import Foundation

/// The file's container, as casting devices think of it.
nonisolated enum CastContainer: String, Sendable, Equatable {
    case mp4, mov, threeGP, matroska, webm, avi, mpegTS, mpegPS, ogg, flv, dv, other

    init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "mp4", "m4v", "f4v": self = .mp4
        case "mov", "qt": self = .mov
        case "3gp", "3g2": self = .threeGP
        case "mkv", "mk3d": self = .matroska
        case "webm": self = .webm
        case "avi", "divx": self = .avi
        case "ts", "m2ts", "mts", "m2t", "tp", "trp", "tod": self = .mpegTS
        case "mpg", "mpeg", "m1v", "m2v", "m2p", "vob", "mod": self = .mpegPS
        case "ogv", "ogg", "ogm": self = .ogg
        case "flv": self = .flv
        case "dv", "dif": self = .dv
        default: self = .other
        }
    }

    var displayName: String {
        switch self {
        case .mp4: "MP4"
        case .mov: "MOV"
        case .threeGP: "3GP"
        case .matroska: "MKV"
        case .webm: "WebM"
        case .avi: "AVI"
        case .mpegTS: "MPEG-TS"
        case .mpegPS: "MPEG-PS"
        case .ogg: "Ogg"
        case .flv: "FLV"
        case .dv: "DV"
        case .other: "This"
        }
    }

    /// The MIME type the media server sends.
    var mimeType: String {
        switch self {
        case .mp4: "video/mp4"
        case .mov: "video/quicktime"
        case .threeGP: "video/3gpp"
        case .matroska: "video/x-matroska"
        case .webm: "video/webm"
        case .avi: "video/x-msvideo"
        case .mpegTS: "video/mp2t"
        case .mpegPS: "video/mpeg"
        case .ogg: "video/ogg"
        case .flv: "video/x-flv"
        case .dv: "video/x-dv"
        case .other: "application/octet-stream"
        }
    }

    /// Every spelling of this container's MIME type seen in renderers' protocol lists.
    var mimeAliases: Set<String> {
        switch self {
        case .mp4: ["video/mp4", "video/mpeg4", "video/x-mp4", "video/m4v", "video/x-m4v"]
        case .mov: ["video/quicktime", "video/x-quicktime", "video/mov"]
        case .threeGP: ["video/3gpp", "video/3gp"]
        case .matroska: ["video/x-matroska", "video/x-mkv", "video/mkv", "video/matroska"]
        case .webm: ["video/webm"]
        case .avi: ["video/avi", "video/x-msvideo", "video/msvideo", "video/divx", "video/x-divx", "video/x-avi"]
        case .mpegTS: ["video/mp2t", "video/vnd.dlna.mpeg-tts", "video/mpeg2", "video/x-mpeg2", "video/mpeg"]
        case .mpegPS: ["video/mpeg", "video/mpeg2", "video/x-mpeg", "video/x-mpeg2", "video/mp2p"]
        case .ogg: ["video/ogg", "application/ogg", "video/x-ogg"]
        case .flv: ["video/x-flv", "video/flv"]
        case .dv: ["video/x-dv", "video/dv"]
        case .other: []
        }
    }
}

/// What casting needs to know about a file: container and codecs.
nonisolated struct CastMediaProfile: Equatable, Sendable {
    var container: CastContainer
    var video: MediaCodec?
    /// Audio codecs in file order; the first default track is what a device plays.
    var audio: [MediaCodec]
    var defaultAudio: MediaCodec?
    var hdr: HDRFormat?

    init(container: CastContainer, video: MediaCodec?, audio: [MediaCodec], defaultAudio: MediaCodec? = nil, hdr: HDRFormat? = nil) {
        self.container = container
        self.video = video
        self.audio = audio
        self.defaultAudio = defaultAudio ?? audio.first
        self.hdr = hdr
    }

    /// Reads the file's tracks (blocking; call off the main actor).
    static func inspect(_ url: URL) -> CastMediaProfile {
        let container = CastContainer(fileExtension: url.pathExtension)
        let tracks = (try? Demuxers.open(url))?.tracks ?? []
        let video = tracks.first { $0.kind == .video }
        let audio = tracks.filter { $0.kind == .audio }
        let preferred = audio.first(where: \.isDefault) ?? audio.first
        return CastMediaProfile(container: container, video: video?.codec, audio: audio.map(\.codec),
                                defaultAudio: preferred?.codec, hdr: video?.hdr)
    }

    /// "MKV · HEVC · DTS".
    var summary: String {
        [container == .other ? nil : container.displayName, video?.displayName, defaultAudio?.displayName]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Whether a device can play a file.
nonisolated enum CastSupport: Equatable, Sendable {
    case supported
    /// Probably plays, with a caveat shown in the menu.
    case limited(String)
    case unsupported(String)

    var isPlayable: Bool {
        if case .unsupported = self { return false }
        return true
    }

    var note: String? {
        switch self {
        case .supported: nil
        case .limited(let note), .unsupported(let note): note
        }
    }
}

nonisolated enum CastCompatibility {
    static func check(_ profile: CastMediaProfile, for device: CastDevice) -> CastSupport {
        switch device.kind {
        case .googleCast: googleCast(profile, model: device.model)
        case .roku: roku(profile)
        case .dlna: dlna(profile, sink: device.sinkProtocols, deviceName: device.name)
        }
    }

    private static func cannot(_ profile: CastMediaProfile, _ highlight: [String], by device: String, _ reason: String) -> CastSupport {
        let parts = ([profile.container.displayName] + highlight).filter { $0 != "This" }
        let format = parts.isEmpty ? profile.summary : parts.joined(separator: " · ")
        return .unsupported("This file's format (\(format)) can't be played by \(device). \(reason)")
    }

    // MARK: Google Cast

    /// Chromecast Ultra, Chromecast with Google TV, Google TV Streamer, and TVs with Cast
    /// built in decode HEVC and VP9; earlier Chromecasts and Nest displays don't (Nest Hubs do VP9).
    static func googleCastDecodesHEVC(model: String?) -> Bool {
        let model = (model ?? "").lowercased()
        if model.contains("ultra") || model.contains("google tv") || model.contains("streamer") || model.contains("chromecast hd") { return true }
        if model.contains("chromecast") || model.contains("nest") || model.contains("google home") { return false }
        return !model.isEmpty // A TV or projector with Cast built in.
    }

    static func googleCast(_ profile: CastMediaProfile, model: String?) -> CastSupport {
        let family = (model ?? "").localizedCaseInsensitiveContains("chromecast") ? "Chromecast" : "this Google Cast device"
        var caveats: [String] = []
        switch profile.container {
        case .mp4, .mov, .webm: break
        case .matroska: caveats.append("Google Cast doesn't officially support MKV files; many devices play them, some don't.")
        default:
            return cannot(profile, [], by: family, "Google Cast plays MP4, M4V, MOV, and WebM files.")
        }
        let advanced = googleCastDecodesHEVC(model: model)
        let isNestHub = (model ?? "").localizedCaseInsensitiveContains("nest hub")
        if let video = profile.video {
            switch video {
            case .h264, .vp8: break
            case .hevc where advanced: break
            case .vp9 where advanced || isNestHub: break
            case .av1 where (model ?? "").localizedCaseInsensitiveContains("streamer"): break
            case .hevc, .vp9, .av1:
                return cannot(profile, [video.displayName], by: family,
                              "\(video.displayName) video needs a Chromecast Ultra, Chromecast with Google TV, or a TV with Cast built in.")
            default:
                return cannot(profile, [video.displayName], by: family, "Google Cast plays H.264, HEVC, VP8, and VP9 video.")
            }
        }
        if profile.hdr != nil, profile.video == .hevc || profile.video == .vp9 {
            caveats.append("HDR shows only on an HDR-capable TV.")
        }
        if let audio = profile.defaultAudio {
            switch audio {
            case .aac, .mp3, .opus, .vorbis, .flac: break
            case .ac3, .eac3:
                caveats.append("\(audio.displayName) sound plays only when the TV or sound system decodes it.")
            default:
                return cannot(profile, [audio.displayName], by: family, "Google Cast plays AAC, MP3, Opus, Vorbis, and FLAC sound.")
            }
        }
        return caveats.isEmpty ? .supported : .limited(caveats.joined(separator: " "))
    }

    // MARK: Roku

    static func roku(_ profile: CastMediaProfile) -> CastSupport {
        var caveats: [String] = []
        switch profile.container {
        case .mp4, .mov, .matroska: break
        default: return cannot(profile, [], by: "Roku", "Roku's media player plays MP4, MOV, and MKV files.")
        }
        if let video = profile.video {
            switch video {
            case .h264: break
            case .hevc, .vp9, .av1: caveats.append("\(video.displayName) video plays on 4K Roku models only.")
            default: return cannot(profile, [video.displayName], by: "Roku", "Roku plays H.264 and HEVC video.")
            }
        }
        if let audio = profile.defaultAudio {
            switch audio {
            case .aac, .mp3, .ac3, .eac3, .flac: break
            case .dts: caveats.append("DTS sound needs a sound system that decodes it.")
            case .opus, .vorbis, .alac: caveats.append("\(audio.displayName) sound plays on newer Roku models only.")
            default: return cannot(profile, [audio.displayName], by: "Roku", "Roku plays AAC, MP3, Dolby Digital, and FLAC sound.")
            }
        }
        return caveats.isEmpty ? .supported : .limited(caveats.joined(separator: " "))
    }

    // MARK: DLNA

    /// The MIME types a renderer accepts over HTTP, from its ConnectionManager Sink list
    /// ("http-get:*:video/mp4:DLNA.ORG_PN=…,http-get:*:video/x-mkv:*").
    static func httpMIMETypes(sink: [String]) -> [String] {
        sink.compactMap { entry in
            let fields = entry.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[0].trimmingCharacters(in: .whitespaces).lowercased() == "http-get" else { return nil }
            return fields[2].trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    /// The renderer's own spelling of the file's MIME type, if it lists one.
    static func dlnaMIMEType(_ profile: CastMediaProfile, sink: [String]?) -> String? {
        guard let sink else { return nil }
        let accepted = httpMIMETypes(sink: sink)
        return accepted.first { profile.container.mimeAliases.contains($0) }
    }

    static func dlna(_ profile: CastMediaProfile, sink: [String]?, deviceName: String) -> CastSupport {
        guard profile.container != .other else {
            return cannot(profile, [], by: deviceName, "TVs need a standard video file such as MP4 or MKV.")
        }
        var caveats: [String] = []
        let accepted = sink.map(httpMIMETypes) ?? []
        if dlnaMIMEType(profile, sink: sink) == nil {
            if accepted.isEmpty || accepted.contains("*") || accepted.contains("video/*") || accepted.contains("*/*") {
                caveats.append("\(deviceName) didn't say which formats it plays, so it may not play this file.")
            } else {
                let videoTypes = accepted.filter { $0.hasPrefix("video/") }
                let listed = Array(Set(videoTypes)).sorted().prefix(5).joined(separator: ", ")
                return cannot(profile, [], by: deviceName, listed.isEmpty ? "It doesn't accept video files." : "It accepts \(listed).")
            }
        }
        // Protocol lists name containers, not codecs: flag the codecs TVs rarely decode.
        if let video = profile.video {
            switch video {
            case .h264, .hevc, .mpeg2Video, .mpeg4Part2, .mpeg1Video, .vp9, .av1: break
            default: caveats.append("Most TVs can't decode \(video.displayName) video.")
            }
        }
        if let audio = profile.defaultAudio {
            switch audio {
            case .dts, .trueHD: caveats.append("\(audio.displayName) sound may not play unless a sound system decodes it.")
            case .opus, .vorbis, .alac, .flac: caveats.append("Some TVs can't play \(audio.displayName) sound.")
            default: break
            }
        }
        return caveats.isEmpty ? .supported : .limited(caveats.joined(separator: " "))
    }

    /// DLNA's fourth protocolInfo field and contentFeatures header: byte seeking (OP=01),
    /// not converted (CI=0), streaming transfer, DLNA 1.5.
    static let dlnaFeatures = "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
}
