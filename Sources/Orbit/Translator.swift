import NaturalLanguage
import SwiftUI
import Translation

/// Provider text that still arrives in English while Orbit is in Portuguese (errors from the Claude API or the Codex CLI),
/// translated on device by Apple's Translation framework. Nothing leaves the Mac once the language is downloaded.
@available(macOS 15, *) @Observable @MainActor
final class Translator {
    static let shared = Translator()
    /// Orbit's own strings are already localized; only Portuguese needs the provider text translated.
    static let on = Locale.app.language.languageCode == .portuguese

    private var done: [String: String] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    /// Set or invalidated to wake the panel's `translationTask`.
    var config: TranslationSession.Configuration?

    /// The text in the app's language: translated when it's English and ready, as the provider sent it until then.
    func callAsFunction(_ s: String) -> String {
        guard Self.on, !s.isEmpty else { return s }
        if let t = done[s] { return t }
        // shortcut: a failed batch stays pending until relaunch, so it isn't retried on every redraw.
        if Self.english(s), pending.insert(s).inserted {
            Task { // not during the view update that asked
                if config == nil { config = .init(source: .init(identifier: "en"), target: .init(identifier: "pt-BR")) }
                else { config?.invalidate() }
            }
        }
        return s
    }

    func run(_ session: TranslationSession) async {
        let batch = Array(pending)
        guard !batch.isEmpty else { return }
        let requests = batch.map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
        guard let out = try? await session.translations(from: requests) else { return }
        for r in out { if let k = r.clientIdentifier { done[k] = r.targetText } }
        pending.subtract(batch)
    }

    /// Orbit's localized messages and the providers' English ones share the error line; only the English go to the translator.
    nonisolated static func english(_ s: String) -> Bool {
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.english, .portuguese]
        r.processString(s)
        return r.dominantLanguage == .english
    }
}

/// Provider text in Orbit's language; macOS 13 and 14 have no on-device translation, so it stays as sent.
@MainActor func translated(_ s: String) -> String {
    if #available(macOS 15, *) { return Translator.shared(s) }
    return s
}

extension View {
    /// Translates new English provider lines in one batch whenever they show up (macOS 15+).
    @ViewBuilder func translatesProviderText() -> some View {
        if #available(macOS 15, *) {
            translationTask(Translator.shared.config) { await Translator.shared.run($0) }
        } else {
            self
        }
    }
}
