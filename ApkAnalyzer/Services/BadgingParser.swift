import Foundation

/// Responsible for parsing aapt2 text output into structured data (SRP).
///
/// Pure parsing logic with no side effects — takes strings, returns values.
/// Extracted from APKExtractionService to honor Single Responsibility.
struct BadgingParser {

    /// Extracts the application label from badging output.
    /// Matches: `application-label:'My App Name'`
    func parseAppLabel(from output: String) -> String {
        let pattern = "application-label:'([^']*)'"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "N/A" }
        let nsOutput = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: nsOutput.length))
        guard let match = matches.first, match.numberOfRanges >= 2 else { return "N/A" }
        return nsOutput.substring(with: match.range(at: 1))
    }

    /// Extracts a quoted value for a given key from badging output.
    /// Tries `key='value'` then `key:'value'`.
    func parseSingleValue(from output: String, key: String) -> String {
        let patterns = [
            "\(NSRegularExpression.escapedPattern(for: key))='([^']*)'",
            "\(NSRegularExpression.escapedPattern(for: key)):'([^']*)'"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: output, range: NSRange(location: 0, length: (output as NSString).length)),
               match.numberOfRanges >= 2 {
                return (output as NSString).substring(with: match.range(at: 1))
            }
        }

        return "N/A"
    }

    /// Parses device compatibility (native-code, screen sizes) from badging output.
    func parseDeviceCompatibility(from output: String) -> [String] {
        var devices: [String] = []

        let nativePattern = "native-code: (.*)"
        if let regex = try? NSRegularExpression(pattern: nativePattern),
           let match = regex.firstMatch(in: output, range: NSRange(location: 0, length: (output as NSString).length)) {
            let line = (output as NSString).substring(with: match.range(at: 1))
            let archPattern = "'([^']*)'"
            if let archRegex = try? NSRegularExpression(pattern: archPattern) {
                let archMatches = archRegex.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
                for m in archMatches {
                    devices.append((line as NSString).substring(with: m.range(at: 1)))
                }
            }
        }

        let screenPattern = "supports-screens: (.*)"
        if let regex = try? NSRegularExpression(pattern: screenPattern),
           let match = regex.firstMatch(in: output, range: NSRange(location: 0, length: (output as NSString).length)) {
            let line = (output as NSString).substring(with: match.range(at: 1))
            let screens = line.components(separatedBy: " ")
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "'", with: "") }
                .filter { !$0.isEmpty }
            devices.append(contentsOf: screens)
        }

        return devices
    }

    /// Parses uses-feature entries, separating required from not-required.
    func parseFeatures(from output: String) -> (required: [String], notRequired: [String]) {
        var required: [String] = []
        var notRequired: [String] = []

        let lines = output.components(separatedBy: "\n")
        for line in lines {
            guard line.contains("uses-feature:") || line.contains("uses-implied-feature:") else { continue }

            let namePattern = "name='([^']*)'"
            guard let regex = try? NSRegularExpression(pattern: namePattern),
                  let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
                  match.numberOfRanges >= 2 else { continue }

            let featureName = (line as NSString).substring(with: match.range(at: 1))

            if line.contains("required='false'") {
                notRequired.append(featureName)
            } else {
                required.append(featureName)
            }
        }

        return (required, notRequired)
    }

    /// Parses permissions from `aapt2 dump permissions` output.
    func parsePermissions(from output: String) -> [String] {
        let pattern = "uses-permission.*name='([^']*)'"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsOutput = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: nsOutput.length))

        return matches.compactMap { match in
            guard match.numberOfRanges >= 2 else { return nil }
            return nsOutput.substring(with: match.range(at: 1))
        }
    }
}
