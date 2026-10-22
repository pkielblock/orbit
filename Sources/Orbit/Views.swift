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
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    static func clockTime(_ date: Date) -> String {
        clock.string(from: date)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    /// "in 2h 13m (14:30)" within a day, "Mon 14:30" beyond that.
    static func reset(_ date: Date?) -> String {
        guard let date else { return "reset unknown" }
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "resetting now" }
        if seconds < 86_400 {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            let rel = h > 0 ? "\(h)h \(m)m" : "\(m)m"
            return "resets in \(rel) (\(clock.string(from: date)))"
        }
        return "resets \(weekday.string(from: date))"
    }


}

/// White galaxy silhouette. macOS adapts the template to the menu bar appearance.
enum StatusIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            GalaxyIcon.draw(in: rect, colored: false)
            return true
        }
        image.isTemplate = true
        return image
    }
}
