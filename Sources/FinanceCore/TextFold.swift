import Foundation

/// Folds text into a key that is used only for matching, never for display.
///
/// Steps: NFKC (full-width Latin and digits become ASCII, half-width kana become
/// full-width), fold case, drop whitespace, recompose kana with voiced marks, turn
/// every dash, long-vowel mark and wave dash into "-", and make small kana large.
/// So "ﾌｧﾐﾘｰﾏｰﾄ", "フアミリ―マ―ト" and "ファミリーマート" share one key.
public enum TextFold {
    public static func key(_ text: String) -> String {
        let nfkc = text.precomposedStringWithCompatibilityMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        var kept = String.UnicodeScalarView()
        for scalar in nfkc.unicodeScalars where !scalar.properties.isWhitespace {
            kept.append(scalar)
        }
        let composed = String(kept).precomposedStringWithCanonicalMapping
        var out = String.UnicodeScalarView()
        for scalar in composed.unicodeScalars {
            out.append(foldMap[scalar] ?? scalar)
        }
        return String(out)
    }

    private static let foldMap: [Unicode.Scalar: Unicode.Scalar] = {
        var map: [Unicode.Scalar: Unicode.Scalar] = [:]
        let dashes: [UInt32] = [
            0x007E, 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212,
            0x2500, 0x2501, 0x301C, 0x30FC, 0xFF0D, 0xFF5E, 0xFF70,
        ]
        for value in dashes {
            if let scalar = Unicode.Scalar(value) { map[scalar] = "-" }
        }
        let small = Array("ァィゥェォッャュョヮヵヶぁぃぅぇぉっゃゅょゎ".unicodeScalars)
        let large = Array("アイウエオツヤユヨワカケあいうえおつやゆよわ".unicodeScalars)
        for (s, l) in zip(small, large) { map[s] = l }
        return map
    }()
}
