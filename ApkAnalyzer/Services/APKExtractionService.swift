import Foundation
import UIKit

/// Coordinates APK analysis by delegating to focused sub-services (SRP + DIP).
///
/// Each responsibility is handled by a dedicated component:
/// - `BadgingParser`          — parses aapt2 text output
/// - `APKSignatureExtractor`  — extracts signing info natively
/// - `APKIconExtractor`       — extracts/renders app icons
///
/// Conforms to `APKAnalyzing` so the ViewModel depends on an abstraction.
final class APKExtractionService: APKAnalyzing {

    // MARK: - Dependencies

    private let parser: BadgingParser
    private let signatureExtractor: APKSignatureExtractor
    private let iconExtractor: APKIconExtractor

    // MARK: - Init (Constructor Injection)

    init(
        parser: BadgingParser = BadgingParser(),
        signatureExtractor: APKSignatureExtractor = APKSignatureExtractor(),
        iconExtractor: APKIconExtractor = APKIconExtractor()
    ) {
        self.parser = parser
        self.signatureExtractor = signatureExtractor
        self.iconExtractor = iconExtractor
    }

    // MARK: - APKAnalyzing

    func copyToTempDirectory(apkURL: URL) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApkAnalyzer", isDirectory: true)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let destination = tempDir.appendingPathComponent(apkURL.lastPathComponent)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.copyItem(at: apkURL, to: destination)
        return destination
    }

    #if targetEnvironment(macCatalyst)
    func extractMetadata(from apkPath: URL) throws -> APKMetadata {
        // 1. Run aapt2 commands
        let badging = try runAAPT2(arguments: ["dump", "badging", apkPath.path])
        let permissionsOutput = try runAAPT2(arguments: ["dump", "permissions", apkPath.path])

        // 2. Parse text output (delegated to BadgingParser)
        let appName = parser.parseAppLabel(from: badging)
        let packageName = parser.parseSingleValue(from: badging, key: "package: name")
        let versionName = parser.parseSingleValue(from: badging, key: "versionName")
        let versionCode = parser.parseSingleValue(from: badging, key: "versionCode")
        let minSDK = parser.parseSingleValue(from: badging, key: "minSdkVersion")
        let targetSDK = parser.parseSingleValue(from: badging, key: "targetSdkVersion")
        let deviceCompatibility = parser.parseDeviceCompatibility(from: badging)
        let permissions = parser.parsePermissions(from: permissionsOutput)
        let (usesFeatures, notRequiredFeatures) = parser.parseFeatures(from: badging)

        // 3. Extract icon (delegated to APKIconExtractor)
        let toolPath = try? aapt2Path()
        let iconResult = iconExtractor.extractIcon(from: apkPath, badgingOutput: badging, aapt2Path: toolPath)

        // 4. Extract signature (delegated to APKSignatureExtractor)
        let signatureInfo = signatureExtractor.extract(from: apkPath)

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
            signer: signatureInfo.signer,
            signingSchemes: signatureInfo.signingSchemes,
            iconPath: iconResult?.sourcePath,
            icon: iconResult?.image
        )
    }
    #else
    func extractMetadata(from apkPath: URL) throws -> APKMetadata {
        throw APKError.executionFailed("APK analysis is only supported on Mac Catalyst.")
    }
    #endif

    // MARK: - aapt2 Execution (Private)

    private func aapt2Path() throws -> String {
        guard let path = Bundle.main.path(forResource: "aapt2", ofType: nil) else {
            throw APKError.toolNotFound
        }
        return path
    }

    private func runAAPT2(arguments: [String]) throws -> String {
        let toolPath = try aapt2Path()
        let result = try ShellExecutor.shared.run(toolPath, arguments: arguments)

        guard result.exitCode == 0 else {
            throw APKError.executionFailed(
                result.errorOutput.isEmpty
                    ? "aapt2 exited with code \(result.exitCode)"
                    : result.errorOutput
            )
        }

        return result.output
    }
}
