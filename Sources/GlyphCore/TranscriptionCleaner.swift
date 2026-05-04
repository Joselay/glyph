import Foundation

public enum TranscriptionCleaner {
    public static func clean(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var needsSpace = false

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = stripWhisperTimestampPrefix(from: rawLine)
            var wroteLineContent = false

            for character in line {
                if character == "\u{feff}" {
                    continue
                }

                if character.isWhitespace {
                    needsSpace = !output.isEmpty
                    continue
                }

                if needsSpace, !output.isEmpty {
                    output.append(" ")
                }
                output.append(character)
                needsSpace = false
                wroteLineContent = true
            }

            if wroteLineContent {
                needsSpace = !output.isEmpty
            }
        }

        return output
    }

    private static func stripWhisperTimestampPrefix(from line: Substring) -> Substring {
        var trimmed = line.drop { character in
            character.isWhitespace || character == "\u{feff}"
        }

        if trimmed.first == "[", let closingBracket = trimmed.firstIndex(of: "]") {
            trimmed = trimmed[trimmed.index(after: closingBracket)...]
                .drop(while: \.isWhitespace)
        }

        return trimmed
    }
}
