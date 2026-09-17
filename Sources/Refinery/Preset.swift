import Foundation

/// The built-in polish style presets. Exactly six preset modes exist; the sixth
/// (`customOneOff`) carries a user-typed prompt for this run only.
public enum Preset: String, CaseIterable, Identifiable, Codable, Sendable {
    /// General-purpose polish: fix grammar and clarity, keep meaning and language.
    case polish
    /// Tighten the text: fewer words, same message.
    case concise
    /// Neutral, professional register.
    case formal
    /// Warm, conversational email tone.
    case friendlyEmail
    /// Detect Danish vs English and polish in the detected language.
    case languageAware
    /// A user-typed prompt applied to this run only.
    case customOneOff

    public var id: String { rawValue }

    /// Short label shown in the menu-bar UI and notifications.
    var label: String {
        switch self {
        case .polish: return "Polish"
        case .concise: return "Concise"
        case .formal: return "Formal"
        case .friendlyEmail: return "Friendly Email"
        case .languageAware: return "Language-Aware"
        case .customOneOff: return "Custom…"
        }
    }
}

/// Builds the chat messages sent to the OpenAI-compatible endpoint for a preset.
///
/// `customPrompt` is only meaningful for `.customOneOff`, where it carries the
/// user's typed instruction. For all other presets it is ignored.
enum PresetPromptError: LocalizedError, Equatable {
    case missingCustomPrompt

    var errorDescription: String? {
        "Enter a custom instruction before polishing."
    }
}

enum PresetPromptBuilder {
    /// The system prompt that applies to every non-custom preset.
    private static let baseSystemPrompt = """
    You are a text-polishing assistant. You receive a piece of user-selected text \
    and return ONLY the rewritten text. No preamble, no explanation, no markdown \
    fences, no quotes around the result. Preserve the writer's voice, meaning and \
    formatting (paragraph breaks, lists) unless the preset instructs otherwise.
    """

    /// Builds the system message for a preset.
    /// - Parameters:
    ///   - preset: the chosen preset.
    ///   - customPrompt: the typed instruction, used only by `.customOneOff`.
    /// - Returns: the system prompt string.
    static func systemPrompt(for preset: Preset, customPrompt: String? = nil) throws -> String {
        switch preset {
        case .polish:
            return baseSystemPrompt
                + " Polish the text: fix grammar, spelling, punctuation and awkward"
                + " phrasing while keeping the meaning, tone and language."
        case .concise:
            return baseSystemPrompt
                + " Make the text concise: keep the full meaning but remove filler,"
                + " redundancy and wordiness. Prefer the shortest clear wording."
        case .formal:
            return baseSystemPrompt
                + " Rewrite the text in a formal, professional register: neutral"
                + " vocabulary, complete sentences, no slang or contractions."
                + " Keep the meaning and language."
        case .friendlyEmail:
            return baseSystemPrompt
                + " Rewrite the text as a friendly email: warm, conversational and"
                + " polite, addressed as the writer would address their recipient."
                + " Keep the same language and the core message."
        case .languageAware:
            return baseSystemPrompt
                + " First detect whether the text is Danish or English, then polish"
                + " it IN THAT SAME LANGUAGE: fix grammar, spelling and clarity while"
                + " keeping the meaning and tone. Never translate."
        case .customOneOff:
            let trimmed = (customPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw PresetPromptError.missingCustomPrompt }
            return """
            You are a text-polishing assistant. Follow the user's instruction about \
            how to transform the text. Return ONLY the transformed text. No preamble, \
            no explanation, no markdown fences, no quotes around the result.

            Instruction: \(trimmed)
            """
        }
    }

    /// Builds the full message array for a chat-completions request.
    /// - Parameters:
    ///   - selectedText: the text captured from the user's selection.
    ///   - preset: the chosen preset.
    ///   - customPrompt: the typed instruction, used only by `.customOneOff`.
    /// - Returns: the messages payload for the request body.
    static func messages(
        for selectedText: String,
        preset: Preset,
        customPrompt: String? = nil
    ) throws -> [[String: String]] {
        [
            ["role": "system", "content": try systemPrompt(for: preset, customPrompt: customPrompt)],
            ["role": "user", "content": selectedText],
        ]
    }
}
