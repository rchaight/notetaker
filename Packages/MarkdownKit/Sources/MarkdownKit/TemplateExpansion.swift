import Foundation

/// Placeholder expansion for note templates (files in the vault's
/// Templates/ folder). Supported: {{title}}, {{date}}, {{time}},
/// {{datetime}}. Unknown placeholders pass through untouched.
public enum TemplateExpansion {
    public static func expand(_ text: String, title: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: now)
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: now)
        return text
            .replacingOccurrences(of: "{{title}}", with: title)
            .replacingOccurrences(of: "{{date}}", with: date)
            .replacingOccurrences(of: "{{time}}", with: time)
            .replacingOccurrences(of: "{{datetime}}", with: "\(date) \(time)")
    }
}
