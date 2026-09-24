//
//  PacePalestinianArabicG2P.swift
//  leanring-buddy
//
//  Deterministic, Offline, Pure Swift Palestinian Arabic Grapheme-to-Phoneme (G2P) Engine.
//  First-party implementation.
//  Zero external dependencies, zero dynamic libraries, zero process execution.
//

import Foundation

public struct PacePalestinianArabicG2P: Sendable {
    public static let shared = PacePalestinianArabicG2P()

    // Base Arabic Consonants mapped to Kokoro/Sofelia target phonemes
    // Note: Sofelia maps ħ -> ʰ, ʕ -> ʁ, sˤ -> s, dˤ -> dᵊ, tˤ -> t, dʒ -> ʤ
    public static let baseConsonants: [Character: String] = [
        "ء": "ʔ", "أ": "ʔ", "إ": "ʔ", "ؤ": "ʔ", "ئ": "ʔ", "آ": "ʔaː",
        "ب": "b",
        "ت": "t",
        "ث": "θ",
        "ج": "ʤ",
        "ح": "ʰ",
        "خ": "χ",
        "د": "d",
        "ذ": "ð",
        "ر": "r",
        "ز": "z",
        "س": "s",
        "ش": "ʃ",
        "ص": "s",
        "ض": "dᵊ",
        "ط": "t",
        "ظ": "ðˤ",
        "ع": "ʁ",
        "غ": "ɣ",
        "ف": "f",
        "ق": "q",
        "ك": "k",
        "ل": "l",
        "م": "m",
        "ن": "n",
        "ه": "h",
        "ة": "a",
        "ى": "aː"
    ]

    // Solar letters that trigger assimilation of the definite article Al-
    public static let sunLetters: Set<Character> = [
        "ت", "ث", "د", "ذ", "ر", "ز", "س", "ش", "ص", "ض", "ط", "ظ", "ل", "ن"
    ]

    // High-frequency Palestinian and Arabic function words / irregular pronunciations
    public static let builtInOverrides: [String: String] = [
        "مرحبا": "mrʰbˈaː",
        "هاني": "hˈaːniː",
        "كيفك": "kˈajfakˌa",
        "خلصت": "χlst",
        "المهمة": "ʔalmˈuhimmˌa",
        "كل": "kˈull",
        "شي": "ʃˈajj",
        "صار": "sˈaːr",
        "تمام": "tˈamaːm",
        "ولا": "wlaː",
        "يهمك": "jhˈumka",
        "خليني": "χlˈiːniː",
        "أتأكد": "ʔtʔkd",
        "من": "mˈin",
        "الموضوع": "ʔalmawdᵊˈuːʁ",
        "وبعدين": "wbʁdˈiːna",
        "بعدين": "bʁdˈiːna",
        "بحكيلك": "bʰkiːlkˌa",
        "شو": "ʃˈuː",
        "استنى": "ˈastnaː",
        "شوي": "ʃˈawiːj",
        "أنا": "ˈana",
        "هسا": "hsˈaː",
        "بفتح": "bftʰ",
        "التطبيق": "ʔattˈatbiːq",
        "وبشوف": "wbʃuːf",
        "بشوف": "bʃuːf",
        "إذا": "ʔˈiðaː",
        "شغال": "ʃˈaɣɣaːl",
        "بدك": "bidkˌa",
        "بقدر": "bqdr",
        "أكمل": "ʔˈakmal",
        "هون": "hˈuːn",
        "ما": "mˈaː",
        "في": "fˈiː",
        "مشكلة": "mˈuʃkilˌa",
        "رح": "rʰ",
        "أراجع": "ʔrˈaːʤʁ",
        "وبخبرك": "wbχbrka",
        "بخبرك": "bχbrka",
        "أول": "ʔˈawwal",
        "أخلص": "ʔˈaχlas",
        "وين": "waˈiːna",
        "أفتحلك": "ʔftʰlkˈa",
        "رأيك": "rˈaʔjka",
        "نجرّبها": "nʤrrbhˈaː",
        "بهالطريقة": "bhaːltrˌiːqt",
        "فتحت": "ftʰt",
        "وكل": "wˈakal",
        "وإذا": "wʔðaː"
    ]

    public init() {}

    public static func stripDiacritics(_ text: String) -> String {
        let diacritics: Set<UnicodeScalar> = [
            "\u{064B}", "\u{064C}", "\u{064D}", "\u{064E}",
            "\u{064F}", "\u{0650}", "\u{0651}", "\u{0652}",
            "\u{0670}", "\u{0640}"
        ]
        return String(text.unicodeScalars.filter { !diacritics.contains($0) })
    }

    /// Phonemizes an isolated word using lexicon overrides, solar/lunar article assimilation, and phonetic rules.
    public func phonemizeWord(_ word: String, customLexicon: [String: String]? = nil) -> String {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return "" }

        // 1. Custom external lexicon lookup
        if let custom = customLexicon {
            if let match = custom[clean] {
                return match
            }
            let stripped = Self.stripDiacritics(clean)
            if let match = custom[stripped] {
                return match
            }
        }

        // 2. Built-in high-frequency Palestinian overrides
        if let direct = Self.builtInOverrides[clean] {
            return direct
        }
        let stripped = Self.stripDiacritics(clean)
        if let directStripped = Self.builtInOverrides[stripped] {
            return directStripped
        }

        // 3. Rule-based phonetic expansion
        var remainder = clean
        var prefixPh = ""

        // Handle Al- (Definite article) and clitics (وال, فال, بال)
        let strippedRemainder = Self.stripDiacritics(remainder)
        if strippedRemainder.hasPrefix("ال") && strippedRemainder.count > 2 {
            let thirdChar = strippedRemainder[strippedRemainder.index(strippedRemainder.startIndex, offsetBy: 2)]
            if Self.sunLetters.contains(thirdChar) {
                let sunCons = Self.baseConsonants[thirdChar] ?? String(thirdChar)
                prefixPh = "ʔa\(sunCons)\(sunCons)"
                let chars = Array(remainder)
                var count = 0
                var dropped = 0
                while count < chars.count && dropped < 3 {
                    let base = chars[count].unicodeScalars.first!
                    if base == "\u{0627}" || base == "\u{0644}" || Character(base) == thirdChar {
                        dropped += 1
                    }
                    count += 1
                }
                remainder = String(chars.dropFirst(count))
            } else {
                prefixPh = "ʔal"
                let chars = Array(remainder)
                var count = 0
                var dropped = 0
                while count < chars.count && dropped < 2 {
                    let base = chars[count].unicodeScalars.first!
                    if base == "\u{0627}" || base == "\u{0644}" {
                        dropped += 1
                    }
                    count += 1
                }
                remainder = String(chars.dropFirst(count))
            }
        } else if (strippedRemainder.hasPrefix("وال") || strippedRemainder.hasPrefix("فال") || strippedRemainder.hasPrefix("بال")) && strippedRemainder.count > 3 {
            let firstChar = strippedRemainder.first!
            let fourthChar = strippedRemainder[strippedRemainder.index(strippedRemainder.startIndex, offsetBy: 3)]
            let lead = firstChar == "و" ? "w" : (firstChar == "ف" ? "f" : "b")
            if Self.sunLetters.contains(fourthChar) {
                let sunCons = Self.baseConsonants[fourthChar] ?? String(fourthChar)
                prefixPh = "\(lead)a\(sunCons)\(sunCons)"
                let chars = Array(remainder)
                var count = 0
                var dropped = 0
                while count < chars.count && dropped < 4 {
                    let base = chars[count].unicodeScalars.first!
                    if Character(base) == firstChar || base == "\u{0627}" || base == "\u{0644}" || Character(base) == fourthChar {
                        dropped += 1
                    }
                    count += 1
                }
                remainder = String(chars.dropFirst(count))
            } else {
                prefixPh = "\(lead)al"
                let chars = Array(remainder)
                var count = 0
                var dropped = 0
                while count < chars.count && dropped < 3 {
                    let base = chars[count].unicodeScalars.first!
                    if Character(base) == firstChar || base == "\u{0627}" || base == "\u{0644}" {
                        dropped += 1
                    }
                    count += 1
                }
                remainder = String(chars.dropFirst(count))
            }
        }

        var ph = prefixPh
        let chars = Array(remainder)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            let scalars = Array(ch.unicodeScalars)
            guard let firstScalar = scalars.first else {
                i += 1
                continue
            }
            let baseChar = Character(firstScalar)

            var hasShaddah = scalars.contains(where: { $0.value == 0x0651 })
            var vowel = ""
            for s in scalars {
                switch s.value {
                case 0x064E: vowel = "a"
                case 0x0650: vowel = "i"
                case 0x064F: vowel = "u"
                case 0x064B: vowel = "an"
                case 0x064C: vowel = "un"
                case 0x064D: vowel = "in"
                case 0x0670: vowel = "aː"
                default: break
                }
            }

            // Check if next char is standalone shaddah or vowel
            if i + 1 < chars.count {
                let nextScalars = Array(chars[i+1].unicodeScalars)
                if nextScalars.count == 1 && nextScalars[0].value == 0x0651 {
                    hasShaddah = true
                    i += 1
                }
            }

            if baseChar == "ا" || baseChar == "ى" {
                if vowel == "an" {
                    ph += "an"
                } else if baseChar == "آ" {
                    ph += "ʔaː"
                } else {
                    ph += "aː"
                }
            } else if baseChar == "و" {
                if i + 1 < chars.count && (chars[i+1].unicodeScalars.first == "\u{0627}") {
                    ph += "uː"
                    i += 1 // consume silent Alif
                } else if !vowel.isEmpty {
                    ph += "w" + vowel
                } else if ph.hasSuffix("a") {
                    ph += "w"
                } else {
                    ph += "uː"
                }
            } else if baseChar == "ي" {
                if !vowel.isEmpty {
                    ph += "j" + vowel
                } else if i == 0 {
                    ph += "j"
                } else {
                    ph += "iː"
                }
            } else if baseChar == "ة" {
                if vowel == "an" { ph += "atan" }
                else if vowel == "un" { ph += "atun" }
                else if vowel == "in" { ph += "atin" }
                else { ph += "a" }
            } else if let cons = Self.baseConsonants[baseChar] {
                if hasShaddah {
                    ph += cons + cons
                } else {
                    ph += cons
                }
                // If next character is Alif (ا), the fatha is subsumed by the long vowel aː
                if !vowel.isEmpty {
                    let nextIsAlif = (i + 1 < chars.count && chars[i+1].unicodeScalars.first == "\u{0627}")
                    if !(vowel == "a" && nextIsAlif) {
                        ph += vowel
                    }
                }
            } else if !vowel.isEmpty {
                ph += vowel
            } else if firstScalar.value == 0x0640 || firstScalar.value == 0x0652 {
                // Tatweel or Sukun: ignored
            } else {
                ph.append(baseChar)
            }
            i += 1
        }
        return ph
    }

    /// Full sentence phonemization handling punctuation spacing and word tokenization.
    public func phonemizeSentence(_ text: String, customLexicon: [String: String]? = nil) -> String {
        let punctMap: [Character: Character] = [
            "،": ",",
            "؛": ";",
            "؟": "?"
        ]
        var normalized = ""
        normalized.reserveCapacity(text.count)
        for c in text {
            if let p = punctMap[c] {
                normalized.append(p)
            } else {
                normalized.append(c)
            }
        }

        let punctChars: Set<Character> = [",", ";", "?", ".", "!", ":"]
        var tokens: [(isPunct: Bool, str: String)] = []
        var cur = ""
        for c in normalized {
            if punctChars.contains(c) {
                let trimmed = cur.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { tokens.append((false, trimmed)) }
                cur = ""
                tokens.append((true, String(c)))
            } else {
                cur.append(c)
            }
        }
        let trimmed = cur.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { tokens.append((false, trimmed)) }

        var result = ""
        for (idx, tok) in tokens.enumerated() {
            if tok.isPunct {
                result += tok.str
                if idx + 1 < tokens.count && !tokens[idx+1].isPunct {
                    result += " "
                }
            } else {
                let words = tok.str.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                let wordPhs = words.map { phonemizeWord($0, customLexicon: customLexicon) }
                let joined = wordPhs.joined(separator: " ")
                if !result.isEmpty && !result.hasSuffix(" ") {
                    result += " "
                }
                result += joined
            }
        }
        return result
    }
}
