//
//  CastTests.swift
//  Ultimate TheaterTests
//
//  Casting: the Cast channel's protobuf framing, SSDP and UPnP parsing, DIDL-Lite/SOAP
//  escaping, the media server's Range handling and token paths, format compatibility, and
//  Roku ECP URLs. None of these touch the network.
//

import Testing
import Foundation
@testable import Ultimate_Theater

// MARK: - Protobuf

struct CastProtobufTests {
    @Test func encodesTheDocumentedFieldLayout() {
        let message = CastMessage(sourceID: "s", destinationID: "d", namespace: "n", payloadUTF8: "p")
        // protocol_version (1, varint) = 0, source_id (2), destination_id (3), namespace (4),
        // payload_type (5, varint) = STRING, payload_utf8 (6).
        let expected: [UInt8] = [0x08, 0x00, 0x12, 0x01, 0x73, 0x1A, 0x01, 0x64, 0x22, 0x01, 0x6E, 0x28, 0x00, 0x32, 0x01, 0x70]
        #expect([UInt8](message.encoded()) == expected)
        #expect([UInt8](message.framed()) == [0x00, 0x00, 0x00, 0x10] + expected)
    }

    @Test func roundTripsARealisticMessage() throws {
        let payload = #"{"type":"LOAD","requestId":42,"media":{"contentId":"http://192.168.1.5:5000/media/x/a.mp4"}}"#
        let message = CastMessage(sourceID: "sender-0", destinationID: "web-5", namespace: GoogleCastNamespace.media, payloadUTF8: payload)
        let decoded = try CastMessage.decode(message.encoded())
        #expect(decoded == message)
        #expect(decoded.payloadUTF8 == payload)
    }

    @Test func multiByteLengthsUseVarints() {
        var data = Data()
        Protobuf.appendVarint(300, to: &data)
        #expect([UInt8](data) == [0xAC, 0x02])
        let long = String(repeating: "x", count: 200)
        let encoded = CastMessage(sourceID: "a", destinationID: "b", namespace: "c", payloadUTF8: long).encoded()
        // Field 6 key, then 200 as a varint (0xC8 0x01).
        let tail = [UInt8](encoded.suffix(203))
        #expect(Array(tail.prefix(3)) == [0x32, 0xC8, 0x01])
    }

    @Test func skipsUnknownFieldsAndRejectsTruncation() throws {
        var data = CastMessage(sourceID: "a", destinationID: "b", namespace: "c", payloadUTF8: "{}").encoded()
        // An unknown varint field 9 and an unknown fixed32 field 10.
        data.append(contentsOf: [0x48, 0x05, 0x55, 1, 2, 3, 4])
        #expect(try CastMessage.decode(data).namespace == "c")

        let truncated = CastMessage(sourceID: "abc", destinationID: "b", namespace: "c", payloadUTF8: "{}").encoded().prefix(4)
        #expect(throws: CastProtobufError.self) { try CastMessage.decode(Data(truncated)) }
    }

    @Test func frameReaderReassemblesSplitFramesAndRejectsHugeOnes() throws {
        let first = CastMessage(sourceID: "a", destinationID: "b", namespace: "n1", payloadUTF8: "{\"type\":\"PING\"}")
        let second = CastMessage(sourceID: "a", destinationID: "b", namespace: "n2", payloadUTF8: "{\"type\":\"PONG\"}")
        let stream = first.framed() + second.framed()
        var reader = CastFrameReader()
        var received: [CastMessage] = []
        for index in stride(from: 0, to: stream.count, by: 5) {
            received += try reader.append(stream.subdata(in: index..<min(index + 5, stream.count)))
        }
        #expect(received == [first, second])

        var hostile = CastFrameReader()
        #expect(throws: CastProtobufError.self) { _ = try hostile.append(Data([0x7F, 0xFF, 0xFF, 0xFF])) }
    }
}

// MARK: - SSDP and UPnP

struct CastDiscoveryParsingTests {
    @Test func parsesSearchResponses() throws {
        let text = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://192.168.1.20:9197/dmr\r\n"
            + "SERVER: Samsung UPnP/1.0\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n"
            + "USN: uuid:ABCD-1234::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
        let response = try #require(SSDPResponse.parse(text, sender: "192.168.1.20"))
        #expect(response.location.absoluteString == "http://192.168.1.20:9197/dmr")
        #expect(response.searchTarget == SSDP.mediaRenderer)
        #expect(response.deviceUUID == "abcd-1234")
    }

    @Test func rejectsResponsesPointingElsewhere() {
        let elsewhere = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.99/desc.xml\r\nST: roku:ecp\r\nUSN: uuid:roku:ecp:X\r\n\r\n"
        #expect(SSDPResponse.parse(elsewhere, sender: "192.168.1.20") == nil)
        let internet = "HTTP/1.1 200 OK\r\nLOCATION: http://8.8.8.8/desc.xml\r\nST: roku:ecp\r\n\r\n"
        #expect(SSDPResponse.parse(internet, sender: "8.8.8.8") == nil)
        let notOK = "NOTIFY * HTTP/1.1\r\nLOCATION: http://192.168.1.20/\r\nST: roku:ecp\r\n\r\n"
        #expect(SSDPResponse.parse(notOK, sender: "192.168.1.20") == nil)
    }

    @Test func searchRequestIsWellFormed() {
        let request = SSDP.searchRequest(target: SSDP.roku)
        #expect(request.hasPrefix("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"))
        #expect(request.contains("MAN: \"ssdp:discover\"\r\n"))
        #expect(request.contains("ST: roku:ecp\r\n"))
        #expect(request.hasSuffix("\r\n\r\n"))
    }

    private static let description = """
    <?xml version="1.0"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <device>
        <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
        <friendlyName>Living Room TV</friendlyName>
        <manufacturer>Samsung Electronics</manufacturer>
        <modelName>QN65 &amp; friends</modelName>
        <UDN>uuid:1234</UDN>
        <serviceList>
          <service>
            <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
            <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
            <controlURL>RenderingControl/ctrl</controlURL>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
            <controlURL>http://192.168.1.99/evil</controlURL>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
            <controlURL>/upnp/control/AVTransport1</controlURL>
          </service>
        </serviceList>
      </device>
    </root>
    """

    @Test func parsesDeviceDescriptionsAndResolvesControlURLs() throws {
        let location = try #require(URL(string: "http://192.168.1.20:9197/dmr/desc.xml"))
        let parsed = try #require(UPnPRendererDescription.parse(Data(Self.description.utf8), location: location))
        #expect(parsed.friendlyName == "Living Room TV")
        #expect(parsed.modelName == "QN65 & friends")
        #expect(parsed.avTransport?.controlURL.absoluteString == "http://192.168.1.20:9197/upnp/control/AVTransport1")
        #expect(parsed.avTransport?.serviceType == "urn:schemas-upnp-org:service:AVTransport:1")
        // Relative without a slash: against the description's directory.
        #expect(parsed.renderingControl?.controlURL.absoluteString == "http://192.168.1.20:9197/dmr/RenderingControl/ctrl")
        // A control URL on another host is ignored.
        #expect(parsed.connectionManager == nil)
    }

    @Test func honoursURLBaseAndNestedDevices() throws {
        let xml = """
        <root><URLBase>http://10.0.0.7:8080/base/</URLBase><device><deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
        <friendlyName>Receiver</friendlyName><deviceList><device>
        <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>Receiver Renderer</friendlyName>
        <serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:2</serviceType>
        <controlURL>avt</controlURL></service></serviceList></device></deviceList></device></root>
        """
        let location = try #require(URL(string: "http://10.0.0.7:8080/desc.xml"))
        let parsed = try #require(UPnPRendererDescription.parse(Data(xml.utf8), location: location))
        #expect(parsed.friendlyName == "Receiver Renderer")
        #expect(parsed.avTransport?.controlURL.absoluteString == "http://10.0.0.7:8080/base/avt")
    }

    @Test func refusesDTDs() throws {
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE root [<!ENTITY a \"aaaa\">]><root><device><friendlyName>&a;</friendlyName></device></root>"
        let location = try #require(URL(string: "http://192.168.1.20/desc.xml"))
        #expect(UPnPRendererDescription.parse(Data(xml.utf8), location: location) == nil)
        #expect(FlatXMLReader.read(Data(xml.utf8)) == nil)
    }

    @Test func readsSOAPReplies() throws {
        let reply = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
        <u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
        <Track>1</Track><TrackDuration>1:02:03</TrackDuration><RelTime>0:10:05.500</RelTime>
        </u:GetPositionInfoResponse></s:Body></s:Envelope>
        """
        let values = try #require(FlatXMLReader.read(Data(reply.utf8))).values
        let status = DLNARendererClient.status(transport: ["CurrentTransportState": "PAUSED_PLAYBACK"], position: values, volume: 0.4)
        #expect(status.state == .paused)
        #expect(status.duration == 3723)
        #expect(status.position == 605.5)
        #expect(status.volume == 0.4)
    }

    @Test func formatsAndParsesUPnPTimes() {
        #expect(UPnPTime.format(0) == "0:00:00")
        #expect(UPnPTime.format(3723.9) == "1:02:03")
        #expect(UPnPTime.format(-5) == "0:00:00")
        #expect(UPnPTime.format(.infinity) == "0:00:00")
        #expect(UPnPTime.parse("01:02:03") == 3723)
        #expect(UPnPTime.parse("12:34") == 754)
        #expect(UPnPTime.parse("NOT_IMPLEMENTED") == nil)
        #expect(UPnPTime.parse("") == nil)
        #expect(UPnPTime.parse("1:x:03") == nil)
    }
}

// MARK: - DIDL-Lite and SOAP

struct CastMetadataTests {
    @Test func escapesDIDLLiteAndItsSOAPEnvelope() throws {
        let media = try #require(URL(string: "http://192.168.1.5:5000/media/abc/Tom_Jerry.mp4"))
        let didl = DIDLLite.metadata(title: "Tom & Jerry <\"Live\">", mediaURL: media, mimeType: "video/mp4",
                                     size: 1234, duration: 3723, artworkURL: nil, isEpisode: false)
        #expect(didl.contains("<dc:title>Tom &amp; Jerry &lt;&quot;Live&quot;&gt;</dc:title>"))
        #expect(didl.contains("protocolInfo=\"http-get:*:video/mp4:DLNA.ORG_OP=01;"))
        #expect(didl.contains("size=\"1234\""))
        #expect(didl.contains("duration=\"1:02:03.000\""))
        #expect(didl.contains(">http://192.168.1.5:5000/media/abc/Tom_Jerry.mp4</res>"))
        // The DIDL document parses as XML.
        #expect(FlatXMLReader.read(Data(didl.utf8))?.values["title"] == "Tom & Jerry <\"Live\">")

        // Inside SetAVTransportURI the whole document is text, so it's escaped again.
        let envelope = UPnPSOAP.envelope(action: "SetAVTransportURI", serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
                                         arguments: [("InstanceID", "0"), ("CurrentURI", media.absoluteString), ("CurrentURIMetaData", didl)])
        #expect(envelope.contains("&lt;DIDL-Lite"))
        #expect(envelope.contains("Tom &amp;amp; Jerry"))
        let parsed = try #require(FlatXMLReader.read(Data(envelope.utf8)))
        #expect(parsed.values["CurrentURIMetaData"] == didl)
        #expect(UPnPSOAP.soapAction(action: "Play", serviceType: "urn:x:AVTransport:1") == "\"urn:x:AVTransport:1#Play\"")
    }

    @Test func dropsControlCharacters() {
        #expect(XMLSafety.escape("a\u{01}b\tc") == "ab\tc")
    }
}

// MARK: - Media server

struct CastMediaServerTests {
    @Test func resolvesRanges() {
        let size: Int64 = 1000
        #expect(HTTPByteRange.resolve(nil, size: size) == .full)
        #expect(HTTPByteRange.resolve("bytes=0-", size: size) == .partial(start: 0, end: 999))
        #expect(HTTPByteRange.resolve("bytes=100-199", size: size) == .partial(start: 100, end: 199))
        #expect(HTTPByteRange.resolve("bytes=900-5000", size: size) == .partial(start: 900, end: 999))
        #expect(HTTPByteRange.resolve("bytes=-500", size: size) == .partial(start: 500, end: 999))
        #expect(HTTPByteRange.resolve("bytes=-5000", size: size) == .partial(start: 0, end: 999))
        #expect(HTTPByteRange.resolve("BYTES=10-20", size: size) == .partial(start: 10, end: 20))
    }

    @Test func ignoresMultipleAndMalformedRanges() {
        let size: Int64 = 1000
        #expect(HTTPByteRange.resolve("bytes=0-1,5-6", size: size) == .full)
        #expect(HTTPByteRange.resolve("bytes=abc", size: size) == .full)
        #expect(HTTPByteRange.resolve("bytes=5-2", size: size) == .full)
        #expect(HTTPByteRange.resolve("bytes=-", size: size) == .full)
        #expect(HTTPByteRange.resolve("bytes=1e3-", size: size) == .full)
        #expect(HTTPByteRange.resolve("items=0-1", size: size) == .full)
        #expect(HTTPByteRange.resolve("bytes=99999999999999999999-", size: size) == .full)
    }

    @Test func refusesUnsatisfiableRanges() {
        #expect(HTTPByteRange.resolve("bytes=1000-", size: 1000) == .unsatisfiable)
        #expect(HTTPByteRange.resolve("bytes=2000-3000", size: 1000) == .unsatisfiable)
        #expect(HTTPByteRange.resolve("bytes=-0", size: 1000) == .unsatisfiable)
    }

    @Test func matchesOnlyTheCurrentTokens() {
        let token = CastToken.make()
        let art = CastToken.make()
        #expect(token.count == 64)
        #expect(token != art)
        #expect(token.allSatisfy { $0.isHexDigit })
        #expect(CastMediaRoute.match(path: "/media/\(token)/Movie.mp4", mediaToken: token, artworkToken: art) == .media)
        #expect(CastMediaRoute.match(path: "/art/\(art).jpg", mediaToken: token, artworkToken: art) == .artwork)
        #expect(CastMediaRoute.match(path: "/media/\(art)/Movie.mp4", mediaToken: token, artworkToken: art) == .notFound)
        #expect(CastMediaRoute.match(path: "/media/\(token)/", mediaToken: token, artworkToken: art) == .notFound)
        #expect(CastMediaRoute.match(path: "/media/\(token)/a/b.mp4", mediaToken: token, artworkToken: art) == .notFound)
        #expect(CastMediaRoute.match(path: "/media/\(token.dropLast())/Movie.mp4", mediaToken: token, artworkToken: art) == .notFound)
        #expect(CastMediaRoute.match(path: "/media/\(token)/Movie.mp4", mediaToken: nil, artworkToken: nil) == .notFound)
        #expect(CastMediaRoute.match(path: "/art/\(token).jpg", mediaToken: token, artworkToken: art) == .notFound)
        #expect(CastMediaRoute.match(path: "/", mediaToken: token, artworkToken: art) == .notFound)
    }

    @Test func parsesRequestsAndRefusesBodies() {
        let request = "GET /media/abc/x.mp4?foo=1 HTTP/1.1\r\nHost: 192.168.1.5\r\nRange: bytes=0-\r\nConnection: close\r\n\r\n"
        guard case .request(let parsed, let consumed) = CastHTTPRequest.parse(Data(request.utf8)) else {
            Issue.record("Request didn't parse")
            return
        }
        #expect(parsed.method == "GET")
        #expect(parsed.path == "/media/abc/x.mp4")
        #expect(parsed.headers["range"] == "bytes=0-")
        #expect(!parsed.keepAlive)
        #expect(consumed == request.utf8.count)

        #expect(CastHTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) == .incomplete)
        #expect(CastHTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello".utf8)) == .invalid)
        #expect(CastHTTPRequest.parse(Data("GARBAGE\r\n\r\n".utf8)) == .invalid)
        #expect(CastHTTPRequest.parse(Data(repeating: 0x41, count: 20_000)) == .invalid)
    }

    @Test func buildsDLNAHeaders() {
        let head = CastMediaServer.head(status: 206, headers: CastMediaServer.mediaHeaders(contentType: "video/mp4", keepAlive: true))
        #expect(head.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        #expect(head.contains("transferMode.dlna.org: Streaming\r\n"))
        #expect(head.contains("contentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0;"))
        #expect(head.contains("Accept-Ranges: bytes\r\n"))
        #expect(head.hasSuffix("\r\n\r\n"))
    }

    @Test func sanitizesFileNames() {
        #expect(CastMediaServer.safeFileName("My Movie (2020).mkv") == "My_Movie__2020_.mkv")
        #expect(CastMediaServer.safeFileName("../../etc/passwd") == "_.._etc_passwd")
        #expect(CastMediaServer.safeFileName("") == "video")
        #expect(CastMediaServer.safeFileName(String(repeating: "a", count: 200) + ".mp4").hasSuffix(".mp4"))
    }

    @Test func classifiesLocalAddresses() {
        #expect(LANAddress.isLocal(literal: "192.168.0.10"))
        #expect(LANAddress.isLocal(literal: "10.1.2.3"))
        #expect(LANAddress.isLocal(literal: "172.20.0.1"))
        #expect(!LANAddress.isLocal(literal: "172.32.0.1"))
        #expect(!LANAddress.isLocal(literal: "8.8.8.8"))
        #expect(!LANAddress.isLocal(literal: "127.0.0.1"))
        #expect(LANAddress.isLocal(literal: "fe80::1%en0"))
        #expect(LANAddress.isLocal(literal: "fd00::1"))
        #expect(!LANAddress.isLocal(literal: "2001:4860::1"))
        #expect(LANAddress.isLocal(literal: "::ffff:192.168.1.1"))
    }

    @Test func parsesDeviceHTTPReplies() {
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
        #expect(LANHTTPResponseParser.parse(chunked, isClosed: false, maxBody: 1024)
                == .complete(status: 200, headers: ["transfer-encoding": "chunked"], body: Data("hello world".utf8)))
        let partial = Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8)
        #expect(LANHTTPResponseParser.parse(partial, isClosed: false, maxBody: 1024) == .incomplete)
        #expect(LANHTTPResponseParser.parse(partial, isClosed: true, maxBody: 1024) == .invalid)
        let tooBig = Data("HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\n".utf8)
        #expect(LANHTTPResponseParser.parse(tooBig, isClosed: false, maxBody: 1024) == .invalid)
        let untilClose = Data("HTTP/1.0 500 Internal Server Error\r\n\r\n<fault/>".utf8)
        #expect(LANHTTPResponseParser.parse(untilClose, isClosed: true, maxBody: 1024)
                == .complete(status: 500, headers: [:], body: Data("<fault/>".utf8)))
    }
}

// MARK: - Compatibility

struct CastCompatibilityTests {
    private func device(_ kind: CastDeviceKind, model: String? = nil, sink: [String]? = nil) -> CastDevice {
        CastDevice(id: "test", kind: kind, name: kind == .dlna ? "Living Room TV" : "Device", model: model, sinkProtocols: sink)
    }

    private let mp4 = CastMediaProfile(container: .mp4, video: .h264, audio: [.aac])
    private let mkvDTS = CastMediaProfile(container: .matroska, video: .h264, audio: [.dts])

    @Test func chromecastPlaysStandardMP4() {
        #expect(CastCompatibility.check(mp4, for: device(.googleCast, model: "Chromecast")) == .supported)
    }

    @Test func chromecastExplainsWhatItCantPlay() {
        let verdict = CastCompatibility.check(mkvDTS, for: device(.googleCast, model: "Chromecast"))
        #expect(!verdict.isPlayable)
        #expect(verdict.note?.contains("This file's format (MKV · DTS) can't be played by Chromecast") == true)

        let avi = CastMediaProfile(container: .avi, video: .mpeg4Part2, audio: [.mp3])
        #expect(!CastCompatibility.check(avi, for: device(.googleCast, model: "Chromecast")).isPlayable)
    }

    @Test func hevcNeedsANewerCastDevice() {
        let hevc = CastMediaProfile(container: .mp4, video: .hevc, audio: [.aac])
        #expect(!CastCompatibility.check(hevc, for: device(.googleCast, model: "Chromecast")).isPlayable)
        #expect(CastCompatibility.check(hevc, for: device(.googleCast, model: "Chromecast Ultra")) == .supported)
        #expect(CastCompatibility.check(hevc, for: device(.googleCast, model: "Chromecast HD")) == .supported)
        #expect(CastCompatibility.check(hevc, for: device(.googleCast, model: "BRAVIA 4K VH2")) == .supported)
        #expect(!CastCompatibility.check(hevc, for: device(.googleCast, model: "Google Nest Hub")).isPlayable)
    }

    @Test func dolbyAndMKVAreLimitedOnCast() {
        let ac3 = CastMediaProfile(container: .mp4, video: .h264, audio: [.ac3])
        guard case .limited = CastCompatibility.check(ac3, for: device(.googleCast, model: "Chromecast")) else {
            Issue.record("Dolby Digital should be limited")
            return
        }
        let mkv = CastMediaProfile(container: .matroska, video: .h264, audio: [.aac])
        #expect(CastCompatibility.check(mkv, for: device(.googleCast, model: "Chromecast")).isPlayable)
    }

    @Test func usesTheDefaultAudioTrack() {
        let profile = CastMediaProfile(container: .mp4, video: .h264, audio: [.dts, .aac], defaultAudio: .aac)
        #expect(CastCompatibility.check(profile, for: device(.googleCast, model: "Chromecast")) == .supported)
    }

    @Test func rokuRules() {
        #expect(CastCompatibility.check(mp4, for: device(.roku)) == .supported)
        let mkvAC3 = CastMediaProfile(container: .matroska, video: .h264, audio: [.ac3])
        #expect(CastCompatibility.check(mkvAC3, for: device(.roku)) == .supported)
        let ts = CastMediaProfile(container: .mpegTS, video: .mpeg2Video, audio: [.mp2])
        #expect(!CastCompatibility.check(ts, for: device(.roku)).isPlayable)
        let truehd = CastMediaProfile(container: .matroska, video: .hevc, audio: [.trueHD])
        #expect(!CastCompatibility.check(truehd, for: device(.roku)).isPlayable)
    }

    @Test func dlnaMatchesTheRenderersProtocols() {
        let sink = ["http-get:*:video/mp4:DLNA.ORG_PN=AVC_MP4_HP_HD_AAC", "http-get:*:video/x-mkv:*", "rtsp-rtp-udp:*:video/x-msvideo:*"]
        let tv = device(.dlna, sink: sink)
        #expect(CastCompatibility.check(mp4, for: tv) == .supported)
        let mkv = CastMediaProfile(container: .matroska, video: .h264, audio: [.aac])
        #expect(CastCompatibility.check(mkv, for: tv) == .supported)
        #expect(CastCompatibility.dlnaMIMEType(mkv, sink: sink) == "video/x-mkv")
        // AVI is listed only over RTSP, which isn't how the Mac serves files.
        let avi = CastMediaProfile(container: .avi, video: .mpeg4Part2, audio: [.mp3])
        let verdict = CastCompatibility.check(avi, for: tv)
        #expect(!verdict.isPlayable)
        #expect(verdict.note?.contains("Living Room TV") == true)
    }

    @Test func dlnaWithoutAProtocolListIsLimited() {
        guard case .limited = CastCompatibility.check(mp4, for: device(.dlna, sink: nil)) else {
            Issue.record("Unknown renderer formats should be limited")
            return
        }
        guard case .limited = CastCompatibility.check(mkvDTS, for: device(.dlna, sink: ["http-get:*:video/x-matroska:*"])) else {
            Issue.record("DTS should be flagged")
            return
        }
    }

    @Test func containersFromExtensions() {
        #expect(CastContainer(fileExtension: "M4V") == .mp4)
        #expect(CastContainer(fileExtension: "mkv") == .matroska)
        #expect(CastContainer(fileExtension: "m2ts") == .mpegTS)
        #expect(CastContainer(fileExtension: "xyz") == .other)
        #expect(CastContainer.matroska.mimeType == "video/x-matroska")
    }
}

// MARK: - Roku

struct RokuECPTests {
    @Test func buildsThePlayOnRokuRequest() throws {
        let media = try #require(URL(string: "http://192.168.1.5:5123/media/abc123/My_Movie.mp4"))
        let art = try #require(URL(string: "http://192.168.1.5:5123/art/def.jpg"))
        let url = try #require(RokuECP.playURL(host: "192.168.1.30", media: media, title: "Tom & Jerry: The Movie",
                                               format: "mp4", artwork: art))
        #expect(url.absoluteString.hasPrefix("http://192.168.1.30:8060/input/15985?t=v&u=http%3A%2F%2F192.168.1.5%3A5123%2Fmedia%2Fabc123%2FMy_Movie.mp4"))
        #expect(url.absoluteString.contains("&videoName=Tom%20%26%20Jerry%3A%20The%20Movie"))
        #expect(url.absoluteString.contains("&videoFormat=mp4"))
        #expect(url.absoluteString.contains("&k=http%3A%2F%2F192.168.1.5%3A5123%2Fart%2Fdef.jpg"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "u" }?.value == media.absoluteString)
        #expect(components.queryItems?.first { $0.name == "videoName" }?.value == "Tom & Jerry: The Movie")
    }

    @Test func keypressURLs() {
        #expect(RokuECP.keypressURL(host: "10.0.0.2", key: "Play")?.absoluteString == "http://10.0.0.2:8060/keypress/Play")
        #expect(RokuECP.keypressURL(host: "10.0.0.2", key: "../launch") == nil)
        #expect(RokuECP.videoFormat(for: .matroska) == "mkv")
        #expect(RokuECP.videoFormat(for: .mp4) == "mp4")
    }

    @Test func parsesMediaPlayerState() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <player error="false" state="play"><plugin bandwidth="10000000 bps" id="15985" name="Media Player"/>
        <format audio="aac" captions="none" container="mp4" drm="none" video="mpeg4_10b"/>
        <position>34541 ms</position><duration>5964000 ms</duration><is_live>false</is_live></player>
        """
        let state = try #require(RokuECP.parsePlayer(Data(xml.utf8)))
        #expect(state.state == "play")
        #expect(state.position == 34.541)
        #expect(state.duration == 5964)
        #expect(RokuECP.state(state) == .playing)
        #expect(RokuECP.state(.init(state: "close", isError: false)) == .stopped)
        #expect(RokuECP.state(.init(state: "play", isError: true)) != .playing)
    }

    @Test func parsesDeviceInfo() {
        let xml = "<device-info><model-name>Roku Ultra</model-name><user-device-name>Bedroom Roku</user-device-name></device-info>"
        #expect(RokuECP.parseDeviceInfo(Data(xml.utf8)) == .init(name: "Bedroom Roku", model: "Roku Ultra"))
    }
}

// MARK: - Google Cast payloads

struct GoogleCastPayloadTests {
    @Test func buildsLoadRequests() throws {
        let media = try #require(URL(string: "http://192.168.1.5:5123/media/abc/E01.mkv"))
        let request = CastLoadRequest(mediaURL: media, contentType: "video/x-matroska",
                                      profile: CastMediaProfile(container: .matroska, video: .h264, audio: [.aac]),
                                      title: "The Show", subtitle: "S1:E1 · Pilot", artworkURL: nil, startTime: 125,
                                      duration: 1800, fileSize: nil, isEpisode: true)
        let payload = GoogleCastClient.loadPayload(request, sessionID: "abc")
        #expect(payload["type"] as? String == "LOAD")
        #expect(payload["currentTime"] as? Double == 125)
        #expect(payload["sessionId"] as? String == "abc")
        let mediaInfo = try #require(payload["media"] as? [String: Any])
        #expect(mediaInfo["contentId"] as? String == media.absoluteString)
        #expect(mediaInfo["streamType"] as? String == "BUFFERED")
        let metadata = try #require(mediaInfo["metadata"] as? [String: Any])
        #expect(metadata["metadataType"] as? Int == 2)
        #expect(metadata["seriesTitle"] as? String == "The Show")
        #expect(JSONSerialization.isValidJSONObject(payload))
    }

    @Test func readsMediaStatus() {
        let entry: [String: Any] = ["mediaSessionId": 3, "playerState": "IDLE", "idleReason": "FINISHED", "currentTime": 1799.5,
                                    "media": ["duration": 1800.0]]
        let status = GoogleCastClient.status(from: entry, previous: CastPlaybackStatus(state: .playing))
        #expect(status.state == .finished)
        #expect(status.position == 1799.5)
        #expect(status.duration == 1800)
        let playing = GoogleCastClient.status(from: ["playerState": "PLAYING", "currentTime": 10], previous: status)
        #expect(playing.state == .playing)
    }
}
