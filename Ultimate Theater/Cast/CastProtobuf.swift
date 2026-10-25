//
//  CastProtobuf.swift
//  Ultimate Theater
//
//  The Google Cast channel's wire format, written from the public description of the
//  CASTV2 protocol: every message is a 4-byte big-endian length followed by a protocol
//  buffer `CastMessage`:
//
//      message CastMessage {
//        required ProtocolVersion protocol_version = 1;   // CASTV2_1_0 = 0
//        required string source_id = 2;
//        required string destination_id = 3;
//        required string namespace = 4;
//        required PayloadType payload_type = 5;           // STRING = 0, BINARY = 1
//        optional string payload_utf8 = 6;
//        optional bytes payload_binary = 7;
//      }
//
//  Only what that message needs is implemented: varints (wire type 0) and length-delimited
//  fields (wire type 2), plus skipping of the other wire types so unknown fields are tolerated.
//

import Foundation

nonisolated enum CastProtobufError: Error, Equatable {
    case truncated
    case malformedVarint
    case unsupportedWireType(Int)
    case invalidUTF8
    case missingField(String)
    case frameTooLarge(Int)
}

/// The few protocol buffer primitives `CastMessage` needs.
nonisolated enum Protobuf {
    static let varint = 0
    static let fixed64 = 1
    static let lengthDelimited = 2
    static let fixed32 = 5

    static func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
    }

    static func appendKey(field: Int, wireType: Int, to data: inout Data) {
        appendVarint(UInt64(field << 3 | wireType), to: &data)
    }

    static func appendString(_ string: String, field: Int, to data: inout Data) {
        appendBytes(Data(string.utf8), field: field, to: &data)
    }

    static func appendBytes(_ bytes: Data, field: Int, to data: inout Data) {
        appendKey(field: field, wireType: lengthDelimited, to: &data)
        appendVarint(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    static func appendVarintField(_ value: UInt64, field: Int, to data: inout Data) {
        appendKey(field: field, wireType: varint, to: &data)
        appendVarint(value, to: &data)
    }

    /// Reads fields from a buffer without copying it.
    struct Reader {
        private let bytes: [UInt8]
        private(set) var offset = 0

        init(_ data: Data) { bytes = [UInt8](data) }

        var isAtEnd: Bool { offset >= bytes.count }

        mutating func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard offset < bytes.count else { throw CastProtobufError.truncated }
                let byte = bytes[offset]
                offset += 1
                // A 64-bit varint has at most ten bytes; the tenth may only carry one bit.
                guard shift < 64, !(shift == 63 && byte > 1) else { throw CastProtobufError.malformedVarint }
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }

        mutating func readKey() throws -> (field: Int, wireType: Int) {
            let key = try readVarint()
            guard key <= UInt64(Int32.max) else { throw CastProtobufError.malformedVarint }
            return (Int(key >> 3), Int(key & 7))
        }

        mutating func readLengthDelimited() throws -> Data {
            let length = try readVarint()
            guard length <= UInt64(bytes.count - offset) else { throw CastProtobufError.truncated }
            let end = offset + Int(length)
            defer { offset = end }
            return Data(bytes[offset..<end])
        }

        mutating func skip(wireType: Int) throws {
            switch wireType {
            case Protobuf.varint: _ = try readVarint()
            case Protobuf.fixed64: try advance(8)
            case Protobuf.lengthDelimited: _ = try readLengthDelimited()
            case Protobuf.fixed32: try advance(4)
            default: throw CastProtobufError.unsupportedWireType(wireType)
            }
        }

        private mutating func advance(_ count: Int) throws {
            guard bytes.count - offset >= count else { throw CastProtobufError.truncated }
            offset += count
        }
    }
}

/// One message on a Cast channel.
nonisolated struct CastMessage: Equatable, Sendable {
    enum PayloadType: UInt64, Sendable {
        case string = 0
        case binary = 1
    }

    /// CASTV2_1_0.
    var protocolVersion: UInt64 = 0
    var sourceID: String
    var destinationID: String
    var namespace: String
    var payloadType: PayloadType = .string
    var payloadUTF8: String?
    var payloadBinary: Data?

    init(sourceID: String, destinationID: String, namespace: String, payloadUTF8: String) {
        self.sourceID = sourceID
        self.destinationID = destinationID
        self.namespace = namespace
        self.payloadUTF8 = payloadUTF8
    }

    /// The protocol buffer encoding (without the length prefix).
    func encoded() -> Data {
        var data = Data()
        Protobuf.appendVarintField(protocolVersion, field: 1, to: &data)
        Protobuf.appendString(sourceID, field: 2, to: &data)
        Protobuf.appendString(destinationID, field: 3, to: &data)
        Protobuf.appendString(namespace, field: 4, to: &data)
        Protobuf.appendVarintField(payloadType.rawValue, field: 5, to: &data)
        if let payloadUTF8 { Protobuf.appendString(payloadUTF8, field: 6, to: &data) }
        if let payloadBinary { Protobuf.appendBytes(payloadBinary, field: 7, to: &data) }
        return data
    }

    /// The length-prefixed frame sent on the TLS connection.
    func framed() -> Data {
        let body = encoded()
        var frame = Data(capacity: body.count + 4)
        let length = UInt32(body.count)
        frame.append(contentsOf: [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        frame.append(body)
        return frame
    }

    static func decode(_ data: Data) throws -> CastMessage {
        var reader = Protobuf.Reader(data)
        var version: UInt64?
        var source: String?
        var destination: String?
        var namespace: String?
        var type: UInt64?
        var utf8: String?
        var binary: Data?
        while !reader.isAtEnd {
            let (field, wireType) = try reader.readKey()
            switch (field, wireType) {
            case (1, Protobuf.varint): version = try reader.readVarint()
            case (2, Protobuf.lengthDelimited): source = try string(reader.readLengthDelimited())
            case (3, Protobuf.lengthDelimited): destination = try string(reader.readLengthDelimited())
            case (4, Protobuf.lengthDelimited): namespace = try string(reader.readLengthDelimited())
            case (5, Protobuf.varint): type = try reader.readVarint()
            case (6, Protobuf.lengthDelimited): utf8 = try string(reader.readLengthDelimited())
            case (7, Protobuf.lengthDelimited): binary = try reader.readLengthDelimited()
            default: try reader.skip(wireType: wireType)
            }
        }
        guard let source else { throw CastProtobufError.missingField("source_id") }
        guard let destination else { throw CastProtobufError.missingField("destination_id") }
        guard let namespace else { throw CastProtobufError.missingField("namespace") }
        var message = CastMessage(sourceID: source, destinationID: destination, namespace: namespace, payloadUTF8: "")
        message.payloadUTF8 = utf8
        message.payloadBinary = binary
        message.protocolVersion = version ?? 0
        message.payloadType = PayloadType(rawValue: type ?? 0) ?? .string
        return message
    }

    private static func string(_ data: Data) throws -> String {
        guard let string = String(data: data, encoding: .utf8) else { throw CastProtobufError.invalidUTF8 }
        return string
    }
}

/// Splits the incoming byte stream into messages.
nonisolated struct CastFrameReader {
    /// Cast messages are limited to 64 KiB; anything larger is a broken or hostile peer.
    static let maximumFrameSize = 64 * 1024

    private var buffer = Data()

    /// Adds received bytes and returns every complete message. Throws on an oversized frame
    /// or a message that doesn't decode; the connection should then be closed.
    mutating func append(_ data: Data) throws -> [CastMessage] {
        buffer.append(data)
        var messages: [CastMessage] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            guard length <= Self.maximumFrameSize else { throw CastProtobufError.frameTooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: (start + 4)..<(start + 4 + length))
            buffer = Data(buffer.dropFirst(4 + length))
            messages.append(try CastMessage.decode(body))
        }
        return messages
    }
}
