import Foundation

/// Bounded path projection. Unknown strings and subtrees are validated and skipped without decoding.
public enum JSONMetadataProjection {
    public static func read(_ data: Data, paths: Set<String>, presencePaths: Set<String> = []) throws -> [String: String] {
        guard data.count <= 2_097_152 else { throw ProjectionError.invalid }
        var reader = Reader(bytes: Array(data), paths: paths, presencePaths: presencePaths)
        try reader.object(prefix: "", depth: 0)
        reader.spaces()
        guard reader.offset == reader.bytes.count else { throw ProjectionError.invalid }
        return reader.fields
    }
    private enum ProjectionError: Error { case invalid }
    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var fields: [String: String] = [:]
        let paths: Set<String>
        let presencePaths: Set<String>
        mutating func spaces() { while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
        mutating func take() throws -> UInt8 {
            guard offset < bytes.count else { throw ProjectionError.invalid }
            defer { offset += 1 }; return bytes[offset]
        }
        mutating func expect(_ byte: UInt8) throws { spaces(); guard try take() == byte else { throw ProjectionError.invalid } }
        mutating func string(retain: Bool) throws -> String? {
            let start = offset
            guard try take() == 34 else { throw ProjectionError.invalid }
            while true {
                let byte = try take()
                guard byte >= 32 else { throw ProjectionError.invalid }
                if byte == 34 { break }
                if byte == 92 {
                    let escape = try take()
                    guard [34, 47, 92, 98, 102, 110, 114, 116, 117].contains(escape) else { throw ProjectionError.invalid }
                    if escape == 117 {
                        for _ in 0..<4 {
                            let hex = try take()
                            guard (48...57).contains(hex) || (65...70).contains(hex) || (97...102).contains(hex) else { throw ProjectionError.invalid }
                        }
                    }
                }
                if retain, offset - start > 1024 { throw ProjectionError.invalid }
            }
            return retain ? try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) : nil
        }
        mutating func object(prefix: String, depth: Int) throws {
            guard depth < 64 else { throw ProjectionError.invalid }
            try expect(123); spaces()
            if offset < bytes.count, bytes[offset] == 125 { offset += 1; return }
            var seen: Set<String> = []
            while true {
                spaces(); let key = try string(retain: true)!
                let path = prefix.isEmpty ? key : prefix + "." + key
                try expect(58); spaces()
                if paths.contains(path) || paths.contains(where: { $0.hasPrefix(path + ".") }) {
                    guard seen.insert(key).inserted, offset < bytes.count else { throw ProjectionError.invalid }
                    if presencePaths.contains(path) { fields[path] = "present"; try skip(depth: depth + 1) }
                    else if paths.contains(path) {
                        if bytes[offset] == 34 { fields[path] = try string(retain: true) }
                        else {
                            let start = offset; try skip(depth: depth + 1)
                            // JSON-RPC root IDs must remain present even when malformed composites.
                            if path == "id" { fields[path] = "present" }
                            if bytes[start] != 123 && bytes[start] != 91 { fields[path] = String(decoding: bytes[start..<offset], as: UTF8.self) }
                        }
                    } else if bytes[offset] == 123 { try object(prefix: path, depth: depth + 1) }
                    else { try skip(depth: depth + 1) }
                } else { try skip(depth: depth + 1) }
                spaces(); let delimiter = try take()
                if delimiter == 125 { return }
                guard delimiter == 44 else { throw ProjectionError.invalid }
            }
        }
        mutating func skip(depth: Int) throws {
            guard depth < 64 else { throw ProjectionError.invalid }
            spaces(); guard offset < bytes.count else { throw ProjectionError.invalid }
            switch bytes[offset] {
            case 34: _ = try string(retain: false)
            case 123, 91:
                let object = try take() == 123, end: UInt8 = object ? 125 : 93
                spaces(); if offset < bytes.count, bytes[offset] == end { offset += 1; return }
                while true {
                    if object { spaces(); _ = try string(retain: false); try expect(58) }
                    try skip(depth: depth + 1); spaces(); let delimiter = try take()
                    if delimiter == end { return }
                    guard delimiter == 44 else { throw ProjectionError.invalid }
                }
            default:
                let start = offset
                while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
                guard offset > start, offset - start <= 128 else { throw ProjectionError.invalid }
                let raw = Data(bytes[start..<offset])
                if raw != Data("null".utf8) && raw != Data("true".utf8) && raw != Data("false".utf8) {
                    let number = try JSONDecoder().decode(Double.self, from: raw)
                    guard number.isFinite else { throw ProjectionError.invalid }
                }
            }
        }
    }
}
