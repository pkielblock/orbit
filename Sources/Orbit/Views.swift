import AppKit
import SwiftUI

/// Loads a bundled logo (svg/pdf/png). Falls back to a letter badge so the app still works without assets.
enum Logos {
    static func image(for provider: Provider, height: CGFloat) -> NSImage {
        for ext in ["svg", "pdf", "png"] {
            if let url = Bundle.main.url(forResource: provider.logoName, withExtension: ext, subdirectory: "logos"),
               let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: height, height: height)
                // Bundled logos are monochrome, so macOS tints them to match the menu bar and label colors.
                image.isTemplate = true
                return image
            }
        }
        return badge(letter: String(provider.name.prefix(1)), height: height)
    }

    private static func badge(letter: String, height: CGFloat) -> NSImage {
        let size = NSSize(width: height, height: height)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: height * 0.25, yRadius: height * 0.25).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: height * 0.6, weight: .bold),
                .foregroundColor: NSColor.windowBackgroundColor
            ]
            let text = NSAttributedString(string: letter, attributes: attrs)
            let textSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            return true
        }
    }
}

enum Format {
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = .app
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = .app
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = .app
        f.dateFormat = format
        return f
    }
    private static let shortDay = formatter("EEE")
    private static let longDay = formatter("EEEE")
    private static let dayOfMonth = formatter("d")

    /// "Fri"; pt-BR's trailing period ("sex.") is dropped.
    static func shortWeekday(_ date: Date) -> String {
        let text = shortDay.string(from: date)
        return text.hasSuffix(".") ? String(text.dropLast()) : text
    }
    static func longWeekday(_ date: Date) -> String { longDay.string(from: date) }
    static func monthDay(_ date: Date) -> String { dayOfMonth.string(from: date) }

    /// At most 5 characters up to 999M: "812", "3.4K", "412K", "3.5M", "12.8M", "412M".
    static func tokens(_ count: Int, locale: Locale = .app) -> String {
        guard count >= 1000 else { return "\(max(count, 0))" }
        func decimal(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1)).locale(locale)) }
        let thousands = Double(count) / 1000
        if thousands < 9.95 { return decimal(thousands) + "K" }
        if thousands < 999.5 { return "\(Int(thousands.rounded()))K" }
        let millions = thousands / 1000
        return millions < 99.95 ? decimal(millions) + "M" : "\(Int(millions.rounded()))M"
    }

    /// The grouped integer for tooltips and VoiceOver ("3.482.110" in pt-BR).
    static func tokensFull(_ count: Int, locale: Locale = .app) -> String {
        count.formatted(.number.locale(locale))
    }

    static func clockTime(_ date: Date) -> String {
        clock.string(from: date)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    /// "in 2h 13m (14:30)" within a day, "Mon 14:30" beyond that.
    static func reset(_ date: Date?) -> String {
        guard let date else { return String(localized: "reset unknown") }
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return String(localized: "resetting now") }
        if seconds < 86_400 {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            let rel = h > 0 ? "\(h)h \(m)m" : "\(m)m"
            return String(localized: "resets in \(rel) (\(clock.string(from: date)))")
        }
        return String(localized: "resets \(weekday.string(from: date))")
    }
}

extension Locale {
    /// The language picked in Settings (System, English, Português (Brasil)); read once, the app restarts on change.
    static let app: Locale = switch UserDefaults.standard.string(forKey: "language") {
    case "pt-BR": Locale(identifier: "pt_BR")
    case "en": Locale(identifier: "en_" + (Locale.current.region?.identifier ?? "US"))
    default: .current
    }
}

/// White orbit drawing from the app icon. macOS adapts the template to the menu bar appearance.
enum StatusIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            OrbitIcon.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}
