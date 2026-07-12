import Foundation

/// User-typed server addresses: "localhost:11434" parses in Swift with
/// scheme "localhost" and no host, which then never resolves. Normalize
/// before building URLs anywhere.
public enum ServerURL {
    public static func normalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: withScheme), url.host() != nil else { return nil }
        return url
    }
}
