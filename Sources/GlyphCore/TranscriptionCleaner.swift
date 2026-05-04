import Foundation

public enum TranscriptionCleaner {
    public static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{feff}", with: "")
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .replacingOccurrences(
                        of: #"^\s*\[[^\]]+\]\s*"#,
                        with: "",
                        options: .regularExpression
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
