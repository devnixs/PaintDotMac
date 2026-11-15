import Foundation

/// The hex box's grammar and display form (C-2). CSS byte order `RRGGBB` / `RRGGBBAA` — Paint.NET's
/// palette *files* use `AARRGGBB`, which 0054 handles on its own.
enum ColorHex {
    /// The Colors panel's hex box (spec 0007).
    static let fieldIdentifier = "colors.hex"

    /// The digits a valid string spells. `alpha == nil` for 6-digit input, which means "keep
    /// the slot's current alpha".
    struct Parsed: Equatable {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8?

        /// The color the digits spell, filling in `alpha` when no `AA` pair was typed.
        func color(alpha: UInt8) -> ColorRGBA8 {
            ColorRGBA8(red: red, green: green, blue: blue, alpha: self.alpha ?? alpha)
        }
    }

    private static let sixDigitCount = 6
    private static let eightDigitCount = 8
    private static let radix = 16
    private static let hexDigits = Array("0123456789ABCDEF")
    private static let asciiZero: UInt32 = 0x30   // "0"
    private static let asciiUpperA: UInt32 = 0x41 // "A"
    private static let asciiLowerA: UInt32 = 0x61 // "a"

    /// Trimmed, one optional leading `#`, then exactly 6 or 8 ASCII hex digits, case-insensitive.
    /// Nothing else parses: no `0x`, no inner spaces, no 3- or 4-digit CSS shorthand, no
    /// full-width digits, no second `#`.
    static func parse(_ input: String) -> Parsed? {
        var body = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("#") { body.removeFirst() }
        let scalars = Array(body.unicodeScalars)
        guard scalars.count == sixDigitCount || scalars.count == eightDigitCount else { return nil }
        var values: [UInt8] = []
        values.reserveCapacity(scalars.count)
        for scalar in scalars {
            guard let nibble = nibble(scalar) else { return nil }
            values.append(nibble)
        }
        return Parsed(red: byte(values[0], values[1]),
                      green: byte(values[2], values[3]),
                      blue: byte(values[4], values[5]),
                      alpha: scalars.count == eightDigitCount
                          ? byte(values[6], values[7]) : nil)
    }

    /// `#RRGGBB` or `#RRGGBBAA`, uppercase, zero-padded.
    static func format(_ color: ColorRGBA8, includeAlpha: Bool) -> String {
        var result = "#" + pair(color.red) + pair(color.green) + pair(color.blue)
        if includeAlpha { result += pair(color.alpha) }
        return result
    }

    /// What the hex field shows: 6 digits while opaque, 8 as soon as alpha matters.
    static func displayString(_ color: ColorRGBA8) -> String {
        format(color, includeAlpha: color.alpha != 255)
    }

    /// The nibble an ASCII hex digit spells; nil for anything else (full-width digits included).
    private static func nibble(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar.value {
        case asciiZero...asciiZero + 9: return UInt8(scalar.value - asciiZero)
        case asciiUpperA...asciiUpperA + 5: return UInt8(scalar.value - asciiUpperA + 10)
        case asciiLowerA...asciiLowerA + 5: return UInt8(scalar.value - asciiLowerA + 10)
        default: return nil
        }
    }

    private static func byte(_ high: UInt8, _ low: UInt8) -> UInt8 {
        high * UInt8(radix) + low
    }

    private static func pair(_ value: UInt8) -> String {
        "\(hexDigits[Int(value) / radix])\(hexDigits[Int(value) % radix])"
    }
}
