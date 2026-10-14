import CryptoKit
import Foundation

/// Minimal RFC 6455 framing for the official local control socket. No HTTP/cookies,
/// authentication files, compression or remote networking are used.
public struct LocalWebSocketFrame: Equatable, Sendable {
    public let opcode: UInt8
    public let payload: Data
    public static let maximumBytes = 2_097_152
    public static func client(_ payload: Data, opcode: UInt8 = 1) -> Data {
        var bytes: [UInt8] = [0x80 | opcode]
        if payload.count < 126 { bytes.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65535 {
            bytes += [0xfe, UInt8(payload.count >> 8), UInt8(payload.count & 255)]
        } else {
            bytes.append(0xff)
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((UInt64(payload.count) >> shift) & 255)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        bytes += mask
        bytes += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        return Data(bytes)
    }
    public static func accept(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }
}

public struct LocalWebSocketDecoder: Sendable {
    private var buffer = Data(), fragment = Data()
    private var fragmented = false
    public init() {}
    public enum FrameError: Error { case invalid }
    public mutating func append(_ data: Data) throws -> [LocalWebSocketFrame] {
        guard buffer.count + data.count <= LocalWebSocketFrame.maximumBytes + 14 else { throw FrameError.invalid }
        buffer.append(data)
        var frames: [LocalWebSocketFrame] = []
        while buffer.count >= 2 {
            let bytes = Array(buffer.prefix(10)), fin = bytes[0] & 0x80 != 0, opcode = bytes[0] & 15
            guard bytes[0] & 0x70 == 0, bytes[1] & 0x80 == 0, [0, 1, 8, 9, 10].contains(opcode) else { throw FrameError.invalid }
            var header = 2, length = UInt64(bytes[1] & 127)
            if length == 126 {
                guard bytes.count >= 4 else { break }
                header = 4; length = UInt64(bytes[2]) << 8 | UInt64(bytes[3])
                guard length >= 126 else { throw FrameError.invalid }
            } else if length == 127 {
                guard bytes.count >= 10 else { break }
                header = 10; length = bytes[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard length > 65535 else { throw FrameError.invalid }
            }
            guard length <= LocalWebSocketFrame.maximumBytes, opcode < 8 || (fin && length <= 125) else { throw FrameError.invalid }
            guard buffer.count >= header + Int(length) else { break }
            let payload = Data(buffer.dropFirst(header).prefix(Int(length)))
            buffer.removeFirst(header + Int(length))
            if opcode >= 8 { frames.append(.init(opcode: opcode, payload: payload)); continue }
            if opcode == 1 {
                guard !fragmented else { throw FrameError.invalid }
                if fin { frames.append(.init(opcode: 1, payload: payload)) }
                else { fragment = payload; fragmented = true }
            } else {
                guard fragmented, fragment.count + payload.count <= LocalWebSocketFrame.maximumBytes else { throw FrameError.invalid }
                fragment.append(payload)
                if fin { frames.append(.init(opcode: 1, payload: fragment)); fragment = Data(); fragmented = false }
            }
        }
        return frames
    }
}
