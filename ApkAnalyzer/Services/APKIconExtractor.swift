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

        guard let zip = APKZipReader(url: apkPath) else { return nil }

        // Strategy 1: Direct extraction using parsed raster icon path
        if let relPath = iconPath, !relPath.hasSuffix(".xml") {
            if let data = zip.extractEntry(path: relPath),
               let image = UIImage(data: data) {
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

            // Strategy 2.5: Directly resolve adaptive icon PNG layers via resource dump.
            // Handles obfuscated APKs where the vector parser's complex resolution chain may fail.
            if let xmlPath = iconPath, xmlPath.hasSuffix(".xml") {
                if let result = extractAdaptiveIconPNGs(from: apkPath, iconXml: xmlPath, aapt2Path: toolPath, zip: zip) {
                    return IconResult(image: result.0, strategy: .densityFallback, sourcePath: result.1)
                }
            }
        }

        // Strategy 3: Scan mipmap/drawable directories for ic_launcher PNGs
        if let result = extractByDensityScan(from: zip) {
            return IconResult(image: result.0, strategy: .densityFallback, sourcePath: result.1)
        }

        // Strategy 4: Best square PNG in resources (handles obfuscated APKs)
        if let result = extractBestSquarePNG(from: zip) {
            return IconResult(image: result.0, strategy: .anyPNG, sourcePath: result.1)
        }

        return nil
    }

    /// Simplified extraction returning just the UIImage (for backward compatibility).
    func extractIconImage(from apkPath: URL, badgingOutput: String, aapt2Path: String? = nil) -> UIImage? {
        return extractIcon(from: apkPath, badgingOutput: badgingOutput, aapt2Path: aapt2Path)?.image
    }

    // MARK: - Extraction Strategies

    /// Strategy 2.5: Directly resolve adaptive icon foreground PNGs via aapt2 resource dump.
    /// Bypasses the vector parser's complex XML → resolveLayer → resolveDrawableReference chain.
    private func extractAdaptiveIconPNGs(from apkPath: URL, iconXml: String, aapt2Path: String, zip: APKZipReader) -> (UIImage, String)? {
        // Step 1: Dump the XML tree to find resource references
        guard let xmlResult = try? ShellExecutor.shared.run(
            aapt2Path, arguments: ["dump", "xmltree", apkPath.path, "--file", iconXml]
        ), !xmlResult.output.isEmpty else { return nil }

        // Look for foreground drawable resource ref: @0x7fXXXXXX
        let refPattern = "foreground[\\s\\S]*?drawable.*?=(@0x[0-9a-fA-F]+)"
        guard let refRegex = try? NSRegularExpression(pattern: refPattern),
              let refMatch = refRegex.firstMatch(in: xmlResult.output, range: NSRange(xmlResult.output.startIndex..., in: xmlResult.output)),
              refMatch.numberOfRanges >= 2 else { return nil }
        let foregroundRef = (xmlResult.output as NSString).substring(with: refMatch.range(at: 1))
        let cleanRef = foregroundRef.replacingOccurrences(of: "@", with: "")

        // Step 2: Dump resources to find PNG file paths for this resource ID
        guard let resResult = try? ShellExecutor.shared.run(
            aapt2Path, arguments: ["dump", "resources", apkPath.path],
            timeout: 10
        ), !resResult.output.isEmpty else { return nil }

        var foundResource = false
        var pngPaths: [String] = []
        for line in resResult.output.components(separatedBy: "\n") {
            if line.contains(cleanRef) {
                foundResource = true
                continue
            }
            if foundResource {
                if line.contains("resource ") { break }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let resRange = trimmed.range(of: "res/") {
                    var path = String(trimmed[resRange.lowerBound...])
                    if let typeRange = path.range(of: " type=") {
                        path = String(path[..<typeRange.lowerBound])
                    }
                    if path.hasSuffix(".png") || path.hasSuffix(".webp") {
                        pngPaths.append(path)
                    }
                }
            }
        }

        // Step 3: Extract highest density PNG (last in the list = highest density)
        for path in pngPaths.reversed() {
            if let data = zip.extractEntry(path: path), let image = UIImage(data: data) {
                return (image, path)
            }
        }

        return nil
    }

    /// Strategy 3: Find ic_launcher PNGs/WebPs in mipmap/drawable directories.
    private func extractByDensityScan(from zip: APKZipReader) -> (UIImage, String)? {
        let candidates = zip.entries.filter { entry in
            let p = entry.path.lowercased()
            return (p.hasPrefix("res/mipmap-") || p.hasPrefix("res/drawable-")) &&
                   (p.hasSuffix(".png") || p.hasSuffix(".webp")) &&
                   p.contains("ic_launcher")
        }.sorted { $0.uncompressedSize > $1.uncompressedSize }

        for entry in candidates {
            if let data = zip.extractEntry(path: entry.path),
               let image = UIImage(data: data) {
                return (image, entry.path)
            }
        }
        return nil
    }

    /// Strategy 4: Find the best square PNG that looks like a launcher icon.
    /// Works for obfuscated APKs where resource names are mangled.
    private func extractBestSquarePNG(from zip: APKZipReader) -> (UIImage, String)? {
        // Filter to PNGs in res/ that are in the icon size range, skip 9-patch
        let candidates = zip.entries.filter { entry in
            let p = entry.path.lowercased()
            return p.hasPrefix("res/") &&
                   (p.hasSuffix(".png") || p.hasSuffix(".webp")) &&
                   !p.contains(".9.") &&
                   entry.uncompressedSize >= 1000 && entry.uncompressedSize <= 30000
        }.sorted { $0.uncompressedSize > $1.uncompressedSize }

        var bestImage: UIImage?
        var bestPixels = 0
        var bestPath: String?

        for entry in candidates.prefix(30) {
            guard let data = zip.extractEntry(path: entry.path),
                  let img = UIImage(data: data) else { continue }

            let w = Int(img.size.width * img.scale)
            let h = Int(img.size.height * img.scale)
            guard w > 0, h > 0 else { continue }

            // Must be square (within 5% tolerance)
            let ratio = CGFloat(max(w, h)) / CGFloat(min(w, h))
            guard ratio <= 1.05 else { continue }

            // Skip images larger than 512px — unlikely to be app icons
            guard max(w, h) <= 512 else { continue }

            let pixels = w * h
            let isStdSize = Self.iconSizes.contains(w) || Self.iconSizes.contains(h)
            let curIsStd = bestImage != nil && (Self.iconSizes.contains(Int(sqrt(Double(bestPixels)))))

            if bestImage == nil ||
               (isStdSize && !curIsStd) ||
               (isStdSize == curIsStd && pixels > bestPixels) {
                bestImage = img
                bestPixels = pixels
                bestPath = entry.path
            }
        }

        if let image = bestImage {
            return (image, bestPath ?? "unknown")
        }
        return nil
    }

    /// Standard Android launcher icon sizes (px), including adaptive icon layer sizes.
    private static let iconSizes: Set<Int> = [48, 72, 96, 108, 128, 144, 162, 192, 216, 256, 324, 432, 512]
}
