import Foundation
import Testing
@testable import PulseCore

@Suite("本机 WebSocket 帧") struct LocalWebSocketTests {
    @Test func maskedClientFramesAndUpgradeAccept() {
        #expect(LocalWebSocketFrame.accept(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        for count in [0, 5, 200, 65536] {
            let body = Data(repeating: 97, count: count), frame = Array(LocalWebSocketFrame.client(body))
            #expect(frame[0] == 0x81 && frame[1] & 128 != 0)
            let offset = count < 126 ? 2 : count <= 65535 ? 4 : 10
            let mask = Array(frame[offset..<offset + 4])
            let decoded = Data(frame.dropFirst(offset + 4).enumerated().map { $0.element ^ mask[$0.offset % 4] })
            #expect(decoded == body)
        }
    }
    @Test func partialFragmentedFramesAndInterleavedPing() throws {
        var decoder = LocalWebSocketDecoder()
        #expect(try decoder.append(Data([0x01, 3, 97])).isEmpty)
        #expect(try decoder.append(Data([98, 99])).isEmpty)
        let frames = try decoder.append(Data([0x89, 1, 120, 0x80, 2, 100, 101]))
        #expect(frames.map(\.opcode) == [9, 1])
        #expect(frames.last?.payload == Data("abcde".utf8))
    }
    @Test func invalidMaskedServerFramesControlFragmentsAndOversizedLengthsFail() {
        for bytes: [UInt8] in [[0x81, 0x80], [0x09, 0], [0x82, 0], [0x80, 0], [0x81, 127, 0, 0, 0, 0, 0, 0x30, 0, 0]] {
            var decoder = LocalWebSocketDecoder()
            #expect(throws: (any Error).self) { try decoder.append(Data(bytes)) }
        }
    }
}
