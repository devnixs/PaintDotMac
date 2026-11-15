import Foundation

/// PNG and JPEG container-completeness checks.
///
/// On macOS 27, ImageIO reports `statusComplete` and hands back a decodable image even for a
/// PNG or JPEG truncated mid-scan (verified against data-, URL-, and incremental-backed
/// `CGImageSource`s), so the `CGImageSource` guards in `PaintDocument.read` cannot reject
/// truncated files. 0001 must never accept one silently (spec *Edge cases*: a truncated file is
/// refused with the standard error), so the container structure — the chunk list for PNG, the
/// marker walk for JPEG — is validated by hand here. 0002 owns the full codec pipeline and may
/// replace this.
///
/// Both checks answer one question only: is the byte stream cut off? They do not validate CRCs
/// or table contents; that is the decoder's job. A stream that is not PNG or JPEG reports
/// `true` and is left to ImageIO's own guards. A wrong "complete" for a hostile file can at
/// most make the app show a partially decoded image — never a crash.
enum ContainerCompleteness {
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let pngIEND: [UInt8] = [0x49, 0x45, 0x4E, 0x44] // "IEND"

    /// True when `data` is a complete PNG/JPEG container, or is not PNG/JPEG at all.
    static func isComplete(_ data: Data) -> Bool {
        guard data.count >= pngSignature.count else { return false }
        let bytes = [UInt8](data)
        if bytes.starts(with: pngSignature) { return isCompletePNG(bytes) }
        if bytes.starts(with: [0xFF, 0xD8]) { return isCompleteJPEG(bytes) }
        return true
    }

    /// PNG: every chunk's declared length must fit in the data, and the chunk list must end
    /// with `IEND`.
    static func isCompletePNG(_ bytes: [UInt8]) -> Bool {
        guard bytes.starts(with: pngSignature) else { return false }
        // Chunk: 4-byte length, 4-byte type, `length` data bytes, 4-byte CRC.
        // `length` is at most `UInt32.max` and `Int` is 64-bit, so `next` cannot overflow.
        var offset = pngSignature.count
        while offset + 8 <= bytes.count {
            let length = (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
            let next = offset + 8 + Int(length) + 4
            guard next <= bytes.count else { return false } // truncated chunk
            if Array(bytes[(offset + 4) ..< (offset + 8)]) == pngIEND { return true }
            offset = next
        }
        return false // ran out of data before IEND
    }

    /// JPEG: every length-bearing marker segment must fit in the data, and the entropy-coded
    /// scan must be terminated by `EOI` (stuffed `FF 00` pairs and restart markers skipped, as
    /// any decoder does).
    static func isCompleteJPEG(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }
        var i = 2 // past SOI
        var inEntropy = false
        while i + 1 < bytes.count {
            guard bytes[i] == 0xFF else {
                if !inEntropy { return false } // garbage outside entropy data
                i += 1
                continue
            }
            let marker = bytes[i + 1]
            if inEntropy {
                switch marker {
                case 0xD9: return true // EOI
                case 0x00, 0x01, 0xD0...0xD7: i += 2 // stuffed 0xFF, TEM, restart markers
                default: inEntropy = false // a new segment starts here; parse it next round
                }
            } else {
                switch marker {
                case 0xD9: return true // EOI with no scan: complete (thumbnail-style stream)
                case 0xFF: i += 1 // fill byte before a marker
                case 0x00, 0x01, 0xD0...0xD8: i += 2 // markers without a length segment
                default: // length-bearing segment; SOS hands over to entropy after its header
                    guard let next = segmentEnd(bytes, markerAt: i) else { return false }
                    i = next
                    if marker == 0xDA { inEntropy = true }
                }
            }
        }
        return false // ran out of data before EOI
    }

    /// End offset of the length-bearing segment whose marker starts at `markerAt`, or nil when
    /// the declared length runs past the data.
    private static func segmentEnd(_ bytes: [UInt8], markerAt: Int) -> Int? {
        guard markerAt + 4 <= bytes.count else { return nil }
        let length = Int(bytes[markerAt + 2]) << 8 | Int(bytes[markerAt + 3])
        guard length >= 2, markerAt + 2 + length <= bytes.count else { return nil }
        return markerAt + 2 + length
    }
}
