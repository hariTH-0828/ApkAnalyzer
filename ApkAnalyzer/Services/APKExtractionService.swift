import Foundation
import UIKit

final class APKExtractionService {

    // MARK: - Private Helpers

    /// Locates the bundled aapt2 binary.
    private func aapt2Path() throws -> String {
        guard let path = Bundle.main.path(forResource: "aapt2", ofType: nil) else {
            throw APKError.toolNotFound
        }
        return path
    }

    /// Locates the bundled apksigner.jar.
    private func apksignerJarPath() throws -> String {
        guard let path = Bundle.main.path(forResource: "apksigner", ofType: "jar") else {
            throw APKError.toolNotFound
        }
        return path
    }

    /// Runs aapt2 with the given arguments and returns stdout.
    private func runAAPT2(arguments: [String]) throws -> String {
        let toolPath = try aapt2Path()
        let result = try ShellExecutor.shared.run(toolPath, arguments: arguments)

        guard result.exitCode == 0 else {
            throw APKError.executionFailed(result.errorOutput.isEmpty ? "aapt2 exited with code \(result.exitCode)" : result.errorOutput)
        }

        return result.output
    }

    /// Runs a generic command and returns stdout.
    private func runCommand(executablePath: String, arguments: [String]) throws -> String {
        let result = try ShellExecutor.shared.run(executablePath, arguments: arguments)
        return result.output
    }

    // MARK: - Public API

    /// Copies the APK into the app's temp directory for safe access, returns the temp path.
    func copyToTempDirectory(apkURL: URL) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApkAnalyzer", isDirectory: true)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let destination = tempDir.appendingPathComponent(apkURL.lastPathComponent)

        // Remove any previous copy
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.copyItem(at: apkURL, to: destination)
        return destination
    }

    #if targetEnvironment(macCatalyst)
    /// Full extraction pipeline: metadata + icon + signature.
    func extractMetadata(from apkPath: URL) throws -> APKMetadata {
        let badging = try runAAPT2(arguments: ["dump", "badging", apkPath.path])
        let permissionsOutput = try runAAPT2(arguments: ["dump", "permissions", apkPath.path])

        // App Information
        let appName = parseAppLabel(from: badging)
        let packageName = parseSingleValue(from: badging, key: "package: name")
        let versionName = parseSingleValue(from: badging, key: "versionName")
        let versionCode = parseSingleValue(from: badging, key: "versionCode")
        let minSDK = parseSingleValue(from: badging, key: "sdkVersion")
        let targetSDK = parseSingleValue(from: badging, key: "targetSdkVersion")
        let deviceCompatibility = parseDeviceCompatibility(from: badging)

        // Features and Permissions
        let permissions = parsePermissions(from: permissionsOutput)
        let (usesFeatures, notRequiredFeatures) = parseFeatures(from: badging)

        // Icon
        let iconExtractor = APKIconExtractor()
        let toolPath = try? aapt2Path()
        let iconResult = iconExtractor.extractIcon(from: apkPath, badgingOutput: badging, aapt2Path: toolPath)
        let iconPath = iconResult?.sourcePath
        let icon = iconResult?.image

        // Signature
        let (signer, v1Verified) = extractSignatureInfo(from: apkPath)

        return APKMetadata(
            appName: appName,
            packageName: packageName,
            versionName: versionName,
            versionCode: versionCode,
            minSDK: minSDK,
            targetSDK: targetSDK,
            deviceCompatibility: deviceCompatibility,
            permissions: permissions,
            usesFeatures: usesFeatures,
            notRequiredFeatures: notRequiredFeatures,
            signer: signer,
            v1SchemeVerified: v1Verified,
            iconPath: iconPath,
            icon: icon
        )
    }
    #else
    func extractMetadata(from apkPath: URL) throws -> APKMetadata {
        throw APKError.executionFailed("APK analysis is only supported on Mac Catalyst.")
    }
    #endif

    // MARK: - Parsing (Plain-text only, no binary parsing)

    /// Extracts the application label (app name) from badging output.
    /// Looks for: application-label:'My App Name'
    private func parseAppLabel(from output: String) -> String {
        let pattern = "application-label:'([^']*)'"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "N/A" }
        let nsOutput = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: nsOutput.length))
        guard let match = matches.first, match.numberOfRanges >= 2 else { return "N/A" }
        return nsOutput.substring(with: match.range(at: 1))
    }

    /// Extracts a quoted value for a given key from badging output.
    private func parseSingleValue(from output: String, key: String) -> String {
        // First try: key='value' pattern
        let pattern1 = "\(NSRegularExpression.escapedPattern(for: key))='([^']*)'"
        if let regex = try? NSRegularExpression(pattern: pattern1),
           let match = regex.firstMatch(in: output, range: NSRange(location: 0, length: (output as NSString).length)),
           match.numberOfRanges >= 2 {
            return (output as NSString).substring(with: match.range(at: 1))
        }

        // Second try: key:'value' pattern (sdkVersion, targetSdkVersion)
        let pattern2 = "\(NSRegularExpression.escapedPattern(for: key)):'([^']*)'"
        if let regex = try? NSRegularExpression(pattern: pattern2),
           let match = regex.firstMatch(in: output, range: NSRange(location: 0, length: (output as NSString).length)),
           match.numberOfRanges >= 2 {
            return (output as NSString).substring(with: match.range(at: 1))
        }

        return "N/A"
    }

    /// Parses device compatibility (native-code, screen sizes) from badging output.
    private func parseDeviceCompatibility(from output: String) -> [String] {
        var devices: [String] = []

        // Parse native-code: 'arm64-v8a' 'x86_64' etc.
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

        // Parse supported screens
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
    private func parseFeatures(from output: String) -> (required: [String], notRequired: [String]) {
        var required: [String] = []
        var notRequired: [String] = []

        let lines = output.components(separatedBy: "\n")
        for line in lines {
            guard line.contains("uses-feature:") || line.contains("uses-implied-feature:") else { continue }

            // Extract feature name
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
    private func parsePermissions(from output: String) -> [String] {
        let pattern = "uses-permission.*name='([^']*)'"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsOutput = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: nsOutput.length))

        return matches.compactMap { match in
            guard match.numberOfRanges >= 2 else { return nil }
            return nsOutput.substring(with: match.range(at: 1))
        }
    }

    // MARK: - Signature Extraction

    #if targetEnvironment(macCatalyst)
    /// Extracts signer info and v1 scheme verification using bundled apksigner.jar.
    private func extractSignatureInfo(from apkPath: URL) -> (signer: String, v1Verified: String) {
        guard let jarPath = try? apksignerJarPath() else {
            return ("N/A", "N/A")
        }

        // Find Java
        let javaPath: String
        if FileManager.default.fileExists(atPath: "/usr/bin/java") {
            javaPath = "/usr/bin/java"
        } else if let whichResult = try? runCommand(executablePath: "/usr/bin/which", arguments: ["java"]),
                  !whichResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            javaPath = whichResult.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return ("N/A (Java not found)", "N/A")
        }

        guard let verifyOutput = try? runCommand(
            executablePath: javaPath,
            arguments: ["-jar", jarPath, "verify", "--verbose", "--print-certs", apkPath.path]
        ) else {
            return ("N/A", "N/A")
        }

        let signer = parseSignerDN(from: verifyOutput)
        let v1Verified = parseV1Scheme(from: verifyOutput)

        return (signer, v1Verified)
    }

    /// Parses signer DN from apksigner verify output.
    /// Looks for: Signer #1 certificate DN: CN=..., OU=..., O=..., L=..., ST=..., C=...
    private func parseSignerDN(from output: String) -> String {
        let pattern = "certificate DN: (.*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "N/A" }
        let nsOutput = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: nsOutput.length))
        guard let match = matches.first, match.numberOfRanges >= 2 else { return "N/A" }
        return nsOutput.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }

    /// Parses v1 scheme (JAR signing) verification status from apksigner output.
    /// Looks for: Verified using v1 scheme (JAR signing): true/false
    private func parseV1Scheme(from output: String) -> String {
        let pattern = "Verified using v1 scheme \\(JAR signing\\): (\\w+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "N/A" }
        let nsOutput = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: nsOutput.length))
        guard let match = matches.first, match.numberOfRanges >= 2 else { return "N/A" }
        return nsOutput.substring(with: match.range(at: 1))
    }


    #endif
}
