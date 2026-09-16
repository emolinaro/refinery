import Foundation

/// Detects whether text is Danish or English, used by the language-aware preset.
///
/// Heuristic scoring: Danish marker characters (æ ø å), Danish-specific words and
/// Danish suffixes push the score towards Danish; common English function words
/// push it towards English. The classifier is deliberately small and offline -
/// the endpoint does the actual polishing; this only decides which language to
/// request (and feeds the local fallback when no endpoint is configured).
enum LanguageDetector {
    enum Language: String, Equatable {
        case danish
        case english
    }

    /// Characters that are near-certain Danish markers (with TeX workarounds excluded).
    private static let danishCharacters: Set<Character> = ["æ", "ø", "å", "Æ", "Ø", "Å"]

    /// Words that are distinctly Danish.
    private static let danishWords: Set<String> = [
        "og", "er", "det", "den", "til", "med", "for", "ikke", "der", "som",
        "har", "jeg", "vi", "af", "du", "en", "et", "på", "kan", "skal", "var",
        "hvad", "hvis", "men", "så", "sig", "mine", "dine", "dette", "disse",
        "meget", "mere", "være", "blev", "har", "hej", "tak", "med", "igen",
        "mange", "allerede", "selvfølgelig", "nd", "virkelig", "snakke",
        "skrive", "svar", "spørgsmål", "håber", "hører", "fint", "godt",
    ]

    /// Words that are distinctly English.
    private static let englishWords: Set<String> = [
        "the", "and", "is", "are", "was", "were", "that", "this", "these", "those",
        "with", "for", "not", "have", "has", "had", "you", "your", "we", "our",
        "of", "to", "in", "on", "it", "as", "but", "so", "they", "them", "their",
        "can", "will", "would", "should", "what", "when", "where", "which", "who",
        "there", "here", "about", "from", "just", "very", "thanks", "please",
        "hope", "hear", "best", "regards", "dear", "hi", "hello",
    ]

    /// Danish suffixes that rarely occur in English.
    private static let danishSuffixes = ["ende", "else", "erne", "eren", "eres", "erne", "hed", "skab"]

    /// Detects the dominant language of `text`.
    /// - Parameter text: the text to classify. May be any length.
    /// - Returns: `.danish` or `.english`; defaults to `.english` when the signal is weak.
    static func detect(_ text: String) -> Language {
        let danishMarkerCount = text.reduce(into: 0) { count, ch in
            if danishCharacters.contains(ch) { count += 1 }
        }
        if danishMarkerCount >= 2 { return .danish }
        if danishMarkerCount == 1 {
            // One marker character is suggestive but not decisive; fall through to word scoring.
            if wordScore(text).danish > 0 { return .danish }
        }

        let score = wordScore(text)
        if score.danish > score.english { return .danish }
        if score.english > score.danish { return .english }

        // Weak or no signal: single marker already ruled out above; check suffixes as a tiebreak.
        let lower = text.lowercased()
        let suffixHits = danishSuffixes.filter { lower.contains($0) }.count
        if danishMarkerCount == 1 || suffixHits >= 2 { return .danish }
        return .english
    }

    private static func wordScore(_ text: String) -> (danish: Int, english: Int) {
        let words = text
            .lowercased()
            .split { !$0.isLetter }
            .map(String.init)
        var danish = 0
        var english = 0
        for word in words {
            if danishWords.contains(word) { danish += 1 }
            if englishWords.contains(word) { english += 1 }
        }
        return (danish, english)
    }
}
