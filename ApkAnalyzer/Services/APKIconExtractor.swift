import Foundation
import UIKit

/// Dedicated parser for extracting app logos (icons) from APK files.
///
/// Handles multiple extraction strategies:
/// 1. Direct extraction using the icon path from aapt2 badging output
/// 2. Fallback to scanning mipmap/drawable directories for `ic_launcher` PNGs
/// 3. Last-resort scan for any PNG asset in resource directories
///
/// Supports density-based selection, preferring PNG over adaptive icon XML.
final class APKIconExtractor {

    // MARK: - Types

    /// Represents a parsed icon entry from aapt2 badging output.
    struct IconEntry {
        let density: Int
        let path: String
        var isPNG: Bool { path.hasSuffix(".png") }
        var isWebP: Bool { path.hasSuffix(".webp") }
        var isXML: Bool { path.hasSuffix(".xml") }
        var isRasterImage: Bool { isPNG || isWebP }
    }

    /// Strategy result indicating how the icon was resolved.
    enum ExtractionStrategy: String {
        case directPath      // Extracted using the exact icon path from badging
        case vectorRendered  // Rendered from Android vector/adaptive icon XML
        case densityFallback // Extracted by scanning mipmap/drawable directories
        case anyPNG          // Last resort: largest PNG found in resources
    }

    /// Result of an icon extraction attempt.
    struct IconResult {
        let image: UIImage
        let strategy: ExtractionStrategy
        let sourcePath: String?
    }

    // MARK: - Icon Path Parsing

    /// Parses all icon entries from aapt2 `dump badging` output.
    ///
    /// Matches lines like:
    /// ```
    /// application-icon-160:'res/mipmap-mdpi-v4/ic_launcher.png'
    /// application-icon-480:'res/mipmap-xxhdpi-v4/ic_launcher_round.png'
    /// application-icon-65534:'res/mipmap-anydpi-v26/ic_launcher.xml'
    /// ```
    func parseAllIconEntries(from badgingOutput: String) -> [IconEntry] {
        let pattern = "application-icon-(\\d+):'([^']*)'"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsOutput = badgingOutput as NSString
        let matches = regex.matches(in: badgingOutput, range: NSRange(location: 0, length: nsOutput.length))

        return matches.compactMap { match -> IconEntry? in
            guard match.numberOfRanges >= 3 else { return nil }
            let densityStr = nsOutput.substring(with: match.range(at: 1))
            let path = nsOutput.substring(with: match.range(at: 2))
            guard let density = Int(densityStr), !path.isEmpty else { return nil }
            return IconEntry(density: density, path: path)
        }
    }

    /// Selects the best icon path from badging output, preferring high-density raster images.
    ///
    /// Selection priority:
    /// 1. Highest-density PNG
    /// 2. Highest-density WebP
    /// 3. Highest-density entry of any type (including XML adaptive icons)
    func bestIconPath(from badgingOutput: String) -> String? {
        let entries = parseAllIconEntries(from: badgingOutput)
        guard !entries.isEmpty else { return nil }

        // Best PNG by density
        let bestPNG = entries.filter(\.isPNG).max(by: { $0.density < $1.density })
        if let png = bestPNG { return png.path }

        // Best WebP by density
        let bestWebP = entries.filter(\.isWebP).max(by: { $0.density < $1.density })
        if let webp = bestWebP { return webp.path }

        // Any highest density (could be XML)
        return entries.max(by: { $0.density < $1.density })?.path
    }

    // MARK: - Icon Extraction

    /// Extracts the icon image from the APK using the best available strategy.
    ///
    /// - Parameters:
    ///   - apkPath: Path to the APK file.
    ///   - badgingOutput: Raw output from `aapt2 dump badging`.
    ///   - aapt2Path: Path to the aapt2 binary (needed for XML icon parsing).
    /// - Returns: An `IconResult` if extraction succeeds, `nil` otherwise.
    func extractIcon(from apkPath: URL, badgingOutput: String, aapt2Path: String? = nil) -> IconResult? {
        let entries = parseAllIconEntries(from: badgingOutput)
        let iconPath = bestIconPath(from: badgingOutput)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApkAnalyzer_icon_\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Strategy 1: Direct extraction using parsed raster icon path
        if let relPath = iconPath, !relPath.hasSuffix(".xml") {
            if let image = extractDirect(from: apkPath, iconRelativePath: relPath, tempDir: tempDir) {
                return IconResult(image: image, strategy: .directPath, sourcePath: relPath)
            }
        }

        // Strategy 2: Render vector/adaptive icon XML via APKVectorIconParser
        if let toolPath = aapt2Path {
            let vectorParser = APKVectorIconParser(aapt2Path: toolPath)

            // Try the best XML icon path first
            if let xmlPath = iconPath, xmlPath.hasSuffix(".xml") {
                if let image = vectorParser.renderIcon(from: apkPath, iconXmlPath: xmlPath) {
                    return IconResult(image: image, strategy: .vectorRendered, sourcePath: xmlPath)
                }
            }

            // Try all XML entries sorted by density (highest first)
            let xmlEntries = entries.filter(\.isXML).sorted(by: { $0.density > $1.density })
            for entry in xmlEntries {
                if let image = vectorParser.renderIcon(from: apkPath, iconXmlPath: entry.path) {
                    return IconResult(image: image, strategy: .vectorRendered, sourcePath: entry.path)
                }
            }
        }

        // Strategy 3: Scan mipmap/drawable directories for ic_launcher PNGs
        if let (image, path) = extractByDensityScan(from: apkPath, tempDir: tempDir) {
            return IconResult(image: image, strategy: .densityFallback, sourcePath: path)
        }

        // Strategy 4: Any PNG in resource directories
        if let (image, path) = extractAnyPNG(from: apkPath, tempDir: tempDir) {
            return IconResult(image: image, strategy: .anyPNG, sourcePath: path)
        }

        return nil
    }

    /// Simplified extraction returning just the UIImage (for backward compatibility).
    func extractIconImage(from apkPath: URL, badgingOutput: String, aapt2Path: String? = nil) -> UIImage? {
        return extractIcon(from: apkPath, badgingOutput: badgingOutput, aapt2Path: aapt2Path)?.image
    }

    // MARK: - Extraction Strategies

    /// Strategy 1: Extract the icon at the exact relative path inside the APK.
    private func extractDirect(from apkPath: URL, iconRelativePath: String, tempDir: URL) -> UIImage? {
        _ = try? ShellExecutor.shared.run(
            "/usr/bin/unzip",
            arguments: ["-o", apkPath.path, iconRelativePath, "-d", tempDir.path]
        )

        let iconFile = tempDir.appendingPathComponent(iconRelativePath)

        guard FileManager.default.fileExists(atPath: iconFile.path),
              let data = try? Data(contentsOf: iconFile),
              let image = UIImage(data: data) else {
            return nil
        }

        return image
    }

    /// Strategy 2: Unzip all mipmap/drawable PNGs and WebPs, pick the largest ic_launcher.
    private func extractByDensityScan(from apkPath: URL, tempDir: URL) -> (UIImage, String)? {
        // Extract from standard directories
        _ = try? ShellExecutor.shared.run(
            "/usr/bin/unzip",
            arguments: [
                "-o", apkPath.path,
                "res/mipmap-*/*.png", "res/mipmap-*/*.webp",
                "res/drawable-*/*.png", "res/drawable-*/*.webp",
                "-d", tempDir.path
            ]
        )

        if let result = findBestIcon(in: tempDir, nameFilter: "ic_launcher") {
            return result
        }

        // For obfuscated APKs: also extract flat res/*.png files
        _ = try? ShellExecutor.shared.run(
            "/usr/bin/unzip",
            arguments: ["-o", apkPath.path, "res/*.png", "res/*.webp", "-d", tempDir.path]
        )

        return findBestIcon(in: tempDir, nameFilter: "ic_launcher")
    }

    /// Strategy 3: Last resort — find the best square PNG that looks like a launcher icon.
    /// Uses `unzip -l` to list all PNGs, extracts candidates, and selects by dimensions.
    private func extractAnyPNG(from apkPath: URL, tempDir: URL) -> (UIImage, String)? {
        // First try what's already extracted
        if let result = findBestSquareIcon(in: tempDir) {
            return result
        }

        // List all PNG/WebP entries in the APK
        guard let listResult = try? ShellExecutor.shared.run(
            "/usr/bin/unzip", arguments: ["-l", apkPath.path]
        ) else {
            return nil
        }
        let listOutput = listResult.output
        guard !listOutput.isEmpty else { return nil }

        // Parse entries: pick res/*.png files in the icon file-size range (1KB–25KB)
        let candidates = listOutput.components(separatedBy: "\n").compactMap { line -> (String, Int)? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Format: "  12345  2024-01-01 12:00  res/XX.png"
            let parts = trimmed.split(separator: " ", maxSplits: 3)
            guard parts.count >= 4 else { return nil }
            let path = String(parts[3])
            guard path.hasPrefix("res/"),
                  path.hasSuffix(".png") || path.hasSuffix(".webp"),
                  !path.contains(".9.") else { return nil } // Skip 9-patch
            guard let size = Int(parts[0]), size >= 1000, size <= 30000 else { return nil }
            return (path, size)
        }.sorted { $0.1 > $1.1 } // Largest first

        // Extract top candidates (limit to avoid excessive I/O)
        let topPaths = candidates.prefix(15).map(\.0)
        guard !topPaths.isEmpty else { return nil }

        var args = ["-o", apkPath.path]
        args.append(contentsOf: topPaths)
        args.append(contentsOf: ["-d", tempDir.path])
        _ = try? ShellExecutor.shared.run("/usr/bin/unzip", arguments: args)

        return findBestSquareIcon(in: tempDir)
    }

    // MARK: - File Scanning

    /// Standard Android launcher icon sizes (px).
    private static let iconSizes: Set<Int> = [48, 72, 96, 128, 144, 192, 256, 512]

    /// Finds the best square image that matches standard launcher icon dimensions.
    private func findBestSquareIcon(in directory: URL) -> (UIImage, String)? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return nil }

        let supportedExtensions: Set<String> = ["png", "webp", "jpg", "jpeg"]
        var bestImage: UIImage?
        var bestPixels: Int = 0
        var bestPath: String?

        while let fileURL = enumerator.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext),
                  !fileURL.lastPathComponent.contains(".9.") else { continue }

            guard let data = try? Data(contentsOf: fileURL),
                  let img = UIImage(data: data) else { continue }

            let w = Int(img.size.width * img.scale)
            let h = Int(img.size.height * img.scale)

            // Must be square (or nearly square, within 5%)
            guard w > 0, h > 0 else { continue }
            let ratio = CGFloat(max(w, h)) / CGFloat(min(w, h))
            guard ratio <= 1.05 else { continue }

            let pixels = w * h

            // Prefer standard icon sizes, then largest
            let isStandardSize = Self.iconSizes.contains(w) || Self.iconSizes.contains(h)
            let currentIsStandard = bestImage != nil && Self.iconSizes.contains(Int(sqrt(Double(bestPixels))))

            if bestImage == nil ||
               (isStandardSize && !currentIsStandard) ||
               (isStandardSize == currentIsStandard && pixels > bestPixels) {
                bestImage = img
                bestPixels = pixels
                bestPath = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
            }
        }

        if let image = bestImage {
            return (image, bestPath ?? "unknown")
        }
        return nil
    }

    /// Scans a directory for image files, optionally filtering by name, and returns the largest one.
    private func findBestIcon(in directory: URL, nameFilter: String?) -> (UIImage, String)? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return nil }

        var bestImage: UIImage?
        var bestSize: Int = 0
        var bestPath: String?
        let supportedExtensions: Set<String> = ["png", "webp", "jpg", "jpeg"]

        while let fileURL = enumerator.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }

            if let filter = nameFilter,
               !fileURL.lastPathComponent.lowercased().contains(filter.lowercased()) {
                continue
            }

            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attrs?[.size] as? Int) ?? 0

            if size > bestSize,
               let data = try? Data(contentsOf: fileURL),
               let img = UIImage(data: data) {
                bestImage = img
                bestSize = size
                bestPath = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
            }
        }

        if let image = bestImage {
            return (image, bestPath ?? "unknown")
        }
        return nil
    }
}
