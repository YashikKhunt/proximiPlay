//
//  NicknameSanitizerTests.swift
//  proximiPlayTests
//
//  A nickname is the app's one piece of peer-supplied text: it arrives in a
//  joiner's invitation context, is stored in the host-authoritative roster,
//  broadcast to every device, rendered in lobby rows, game screens and
//  results, and rasterized into a share card that leaves the device.
//  Trimming and truncating is not enough for that path.
//

import Testing
import Foundation
@testable import proximiPlay

@Suite("Nickname sanitizing")
struct NicknameSanitizerTests {

    // MARK: - Invisible names

    /// Zero-width characters are category Cf, not whitespace, so a trim
    /// never removes them: a name made only of them survives the
    /// non-empty check and then renders as nothing. The player becomes an
    /// unlabelled row in everyone's lobby and a blank name on the share card.
    @Test func zeroWidthOnlyNameDoesNotSurviveAsBlank() {
        let zeroWidth = String(repeating: "\u{200B}", count: 12)
        let result = PlayerNickname.sanitize(zeroWidth, fallback: "Fallback")
        #expect(result == "Fallback", "A name with no visible glyphs must not be accepted")
    }

    @Test func joinerOnlyNameDoesNotSurviveAsBlank() {
        let joiners = String(repeating: "\u{200D}", count: 8)
        let result = PlayerNickname.sanitize(joiners, fallback: "Fallback")
        #expect(result == "Fallback")
    }

    // MARK: - Bidirectional control

    /// A right-to-left override reorders how following text renders, which
    /// lets a name visually masquerade as different text in a lobby row.
    @Test func bidiOverrideIsStripped() {
        let spoof = "Ari\u{202E}drah"
        let result = PlayerNickname.sanitize(spoof)
        #expect(!result.unicodeScalars.contains { $0.value == 0x202E })
        #expect(result.contains("Ari"))
    }

    @Test func bidiIsolatesAreStripped() {
        for scalar in [0x2066, 0x2067, 0x2068, 0x2069, 0x202A, 0x202B, 0x202C, 0x202D] {
            let raw = "Bo\(String(UnicodeScalar(scalar)!))x"
            let result = PlayerNickname.sanitize(raw)
            #expect(
                !result.unicodeScalars.contains { $0.value == UInt32(scalar) },
                "U+\(String(scalar, radix: 16, uppercase: true)) should not reach the roster"
            )
        }
    }

    // MARK: - Layout blowout

    /// `prefix(maxLength)` counts *graphemes*, so one base character with a
    /// hundred combining marks is a single "character" that passes the cap
    /// while rendering as a tall smear over neighbouring rows.
    @Test func stackedCombiningMarksCannotBlowOutLayout() {
        let zalgo = "A" + String(repeating: "\u{0301}", count: 200)
        let result = PlayerNickname.sanitize(zalgo)
        #expect(result.unicodeScalars.count <= PlayerNickname.maxScalars,
                "Scalar count must be bounded, not just grapheme count")
    }

    @Test func newlinesInsideTheNameAreRemoved() {
        let result = PlayerNickname.sanitize("Ari\nBo")
        #expect(!result.contains("\n"), "An embedded newline would break single-line row layout")
    }

    @Test func controlCharactersAreRemoved() {
        let result = PlayerNickname.sanitize("A\u{0007}ri\u{0000}")
        #expect(result == "Ari")
    }

    // MARK: - Legitimate names must still work

    @Test func ordinaryNamesAreUntouched() {
        #expect(PlayerNickname.sanitize("Ari") == "Ari")
        #expect(PlayerNickname.sanitize("  Bo  ") == "Bo")
        #expect(PlayerNickname.sanitize("Priyanka") == "Priyanka")
    }

    @Test func accentedAndNonLatinNamesSurvive() {
        #expect(PlayerNickname.sanitize("José") == "José")
        #expect(PlayerNickname.sanitize("你好") == "你好")
        #expect(PlayerNickname.sanitize("Zoë") == "Zoë")
    }

    /// Family/profession emoji are built from ZWJ sequences, so the filter
    /// cannot simply drop every format character.
    @Test func emojiIncludingZWJSequencesSurvive() {
        #expect(PlayerNickname.sanitize("Ari 🎉") == "Ari 🎉")
        let family = "👨‍👩‍👧"
        #expect(PlayerNickname.sanitize(family) == family)
    }

    @Test func lengthCapStillApplies() {
        let long = String(repeating: "a", count: 100)
        #expect(PlayerNickname.sanitize(long).count == PlayerNickname.maxLength)
    }

    @Test func emptyFallsBackAndNeverYieldsEmpty() {
        #expect(PlayerNickname.sanitize("", fallback: "Device") == "Device")
        #expect(PlayerNickname.sanitize("   ", fallback: "Device") == "Device")
        // A hostile peer could send an unusable name AND an unusable fallback.
        #expect(!PlayerNickname.sanitize("\u{200B}", fallback: "\u{200B}").isEmpty)
    }
}
