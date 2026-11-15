import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PaintDotMac

/// Pins the container walks in `ContainerCompleteness` with hand-built byte streams.
/// Expected values come from the container formats themselves — PNG chunk framing
/// (4-byte big-endian length, 4-byte type, data, 4-byte CRC; the stream ends with IEND)
/// and JPEG marker segments (every length-bearing segment counts its own 2 length bytes;
/// the scan ends at EOI; 0xFF is stuffed as 0xFF 0x00) — not from the implementation.
struct ContainerCompletenessTests {
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// One PNG chunk: length, type, data, and four placeholder CRC bytes (the walk checks
    /// framing, never CRCs — that is the decoder's job).
    private func chunk(_ type: String, _ data: [UInt8] = []) -> [UInt8] {
        var bytes = [UInt8]()
        let length = UInt32(data.count)
        bytes += [UInt8(length >> 24), UInt8(length >> 16), UInt8(length >> 8), UInt8(length)]
        bytes += Array(type.utf8)
        bytes += data
        bytes += [0, 0, 0, 0] // CRC placeholder
        return bytes
    }

    private var minimalPNG: [UInt8] {
        Self.pngSignature
            + chunk("IHDR", [UInt8](repeating: 0, count: 13))
            + chunk("IDAT", [1, 2, 3, 4])
            + chunk("IEND")
    }

    private func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

    /// SOI, one length-bearing DQT segment (3 payload bytes), SOS with a 2-byte payload, a
    /// scan containing a stuffed `FF 00` pair and a restart marker, and EOI.
    private var minimalJPEG: [UInt8] {
        [0xFF, 0xD8]
            + [0xFF, 0xDB] + be16(5) + [0xAA, 0xBB, 0xCC] // DQT: 2 self + 3 payload
            + [0xFF, 0xDA] + be16(4) + [0x01, 0x11] // SOS header
            + [0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56] // entropy-coded scan
            + [0xFF, 0xD9] // EOI
    }

    // MARK: - PNG

    @Test func completeHandBuiltPNG() {
        #expect(ContainerCompleteness.isComplete(Data(minimalPNG)))
    }

    @Test func pngWithTrailingGarbageAfterIEND() {
        #expect(ContainerCompleteness.isComplete(Data(minimalPNG + [9, 9, 9])))
    }

    @Test func pngWithOnlyItsSignature() {
        #expect(!ContainerCompleteness.isComplete(Data(Self.pngSignature)))
    }

    @Test func pngWithLastCRCBytesMissing() {
        // Dropping the final byte cuts IEND's CRC short: the declared framing runs past EOF.
        #expect(!ContainerCompleteness.isComplete(Data(minimalPNG.dropLast(1))))
    }

    @Test func pngCutMidIDAT() {
        // Keep the IDAT header plus half of its four data bytes.
        let idatHeaderEnd = Self.pngSignature.count
            + chunk("IHDR", [UInt8](repeating: 0, count: 13)).count + 8
        #expect(!ContainerCompleteness.isComplete(Data(minimalPNG.prefix(idatHeaderEnd + 2))))
    }

    @Test func pngChunkLengthAtUInt32MaxDoesNotOverflow() {
        // A 0xFFFFFFFF chunk length must fail the bounds check, not wrap around.
        var bytes = Self.pngSignature + chunk("IHDR", [UInt8](repeating: 0, count: 13))
        bytes += [0xFF, 0xFF, 0xFF, 0xFF] + Array("IDAT".utf8) + [1, 2]
        #expect(!ContainerCompleteness.isComplete(Data(bytes)))
    }

    // MARK: - JPEG

    @Test func completeHandBuiltJPEG() {
        #expect(ContainerCompleteness.isComplete(Data(minimalJPEG)))
    }

    @Test func jpegWithOnlySOIAndEOI() {
        #expect(ContainerCompleteness.isComplete(Data([0xFF, 0xD8, 0xFF, 0xD9])))
    }

    @Test func jpegCutMidScan() {
        #expect(!ContainerCompleteness.isComplete(Data(minimalJPEG.dropLast(2)))) // without EOI
    }

    @Test func jpegCutRightAfterAFillByte() {
        // A stream ending between the two bytes of the EOI marker is cut off.
        #expect(!ContainerCompleteness.isComplete(Data(minimalJPEG.dropLast(1))))
    }

    @Test func jpegSegmentLengthBeyondEOF() {
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDB] + be16(64) + [0x01, 0x02, 0xFF, 0xD9]
        #expect(!ContainerCompleteness.isComplete(Data(bytes)))
    }

    @Test func jpegWithDanglingMarkerHeader() {
        // A marker whose length field is cut off mid-word.
        #expect(!ContainerCompleteness.isComplete(Data([0xFF, 0xD8, 0xFF, 0xDB, 0x00])))
    }

    // MARK: - Non-container input and real encoders

    @Test func nonPNGOrJPEGReportsTrueForImageIOToDecide() {
        // The function answers only "is this PNG/JPEG stream cut off?"; other bytes are left
        // to ImageIO's own guards (spec 0001 *Scope*: `PaintDocument.read` still rejects them).
        #expect(ContainerCompleteness.isComplete(Data("GIF89a....".utf8)))
        #expect(ContainerCompleteness.isComplete(Data(repeating: 0x42, count: 512)))
    }

    /// Real ImageIO output must never be refused: the walks have to tolerate every chunk and
    /// marker ImageIO emits (profiles, tables, multiple IDATs, progressive scans).
    @Test func imageIOEncodedFilesAreComplete() throws {
        let image = try FixtureFiles.solidImage(width: 32, height: 32, rgba: (10, 200, 30, 255))
        #expect(ContainerCompleteness.isComplete(try Self.encoded(image, type: "public.png")))
        #expect(ContainerCompleteness.isComplete(try Self.encoded(image, type: "public.jpeg")))
    }

    private static func encoded(_ image: CGImage, type: String) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }
}
