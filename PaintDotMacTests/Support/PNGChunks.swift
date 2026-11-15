import Foundation

/// A test-side PNG chunk walker (the PNG specification, §5.3): the 8-byte signature, then
/// records of 4-byte big-endian length, 4 ASCII type bytes, `length` data bytes, and a 4-byte
/// CRC. Used to inspect chunks (`pHYs`, `iCCP`, `sRGB`) without going through ImageIO, so
/// encoder tests never measure the code under test with the code under test. CRCs are not
/// verified here; `ImageDecoder.pngChunksAreComplete` owns completeness checks.
enum PNGChunks {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    struct Chunk: Equatable {
        let type: String
        let data: Data
    }

    /// All chunks in order; `nil` when the signature or a record is malformed or truncated.
    static func read(_ data: Data) -> [Chunk]? {
        let bytes = [UInt8](data)
        guard bytes.count >= signature.count, Array(bytes[..<signature.count]) == signature else {
            return nil
        }
        var chunks: [Chunk] = []
        var offset = signature.count
        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { return nil }
            let length = Int(be32(bytes, offset))
            let dataStart = offset + 8
            guard length >= 0, dataStart + length + 4 <= bytes.count else { return nil }
            let type = String(decoding: bytes[(offset + 4)..<dataStart], as: UTF8.self)
            chunks.append(Chunk(type: type, data: Data(bytes[dataStart..<(dataStart + length)])))
            offset = dataStart + length + 4
        }
        return chunks
    }

    static func chunks(in data: Data, named name: String) -> [Chunk] {
        (read(data) ?? []).filter { $0.type == name }
    }

    private static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }
}
