import Foundation
import UIKit
import Security

final class APKExtractionService {

    // MARK: - Private Helpers

    /// Locates the bundled aapt2 binary.
    private func aapt2Path() throws -> String {
        guard let path = Bundle.main.path(forResource: "aapt2", ofType: nil) else {
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
        let minSDK = parseSingleValue(from: badging, key: "minSdkVersion")
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
        let (signer, signingSchemes) = extractSignatureInfo(from: apkPath)

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
            signingSchemes: signingSchemes,
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

    // MARK: - Signature Extraction (Native)

    #if targetEnvironment(macCatalyst)
    /// Extracts signer info by parsing the APK's signing data natively.
    /// Supports v1 (META-INF JAR signing), v2, and v3 APK Signature Schemes.
    private func extractSignatureInfo(from apkPath: URL) -> (signer: String, signingSchemes: String) {
        var schemes: [String] = []
        var signerDN: String = "N/A"

        // --- v1 signing: META-INF/*.RSA/.DSA/.EC ---
        if let zip = APKZipReader(url: apkPath) {
            let metaEntries = zip.entries.map(\.path).filter { $0.hasPrefix("META-INF/") }
            let hasManifest = metaEntries.contains("META-INF/MANIFEST.MF")
            let hasSF = metaEntries.contains { $0.hasSuffix(".SF") }
            let sigBlockExtensions = [".RSA", ".DSA", ".EC"]
            let sigBlockEntry = metaEntries.first { path in
                sigBlockExtensions.contains { path.uppercased().hasSuffix($0) }
            }
            if hasManifest && hasSF && sigBlockEntry != nil {
                schemes.append("v1")
                if signerDN == "N/A",
                   let blockPath = sigBlockEntry,
                   let pkcs7Data = zip.extractEntry(path: blockPath) {
                    signerDN = extractCertificateDN(from: pkcs7Data)
                }
            }
        }

        // --- v2 / v3 signing: APK Signing Block ---
        if let certData = extractCertFromSigningBlock(at: apkPath) {
            if certData.v2 { schemes.append("v2") }
            if certData.v3 { schemes.append("v3") }
            if signerDN == "N/A", let der = certData.certificate {
                if let cert = SecCertificateCreateWithData(nil, der as CFData) {
                    signerDN = formatCertificateDN(cert)
                }
            }
        }

        let schemesStr = schemes.isEmpty ? "None" : schemes.joined(separator: ", ")
        return (signerDN, schemesStr)
    }

    /// Parses the APK Signing Block to detect v2/v3 schemes and extract the first signer certificate.
    /// APK Signing Block layout: ... | pairs | block_size (8) | magic "APK Sig Block 42" (16) | ...
    /// Each pair: size (8 bytes LE) | id (4 bytes LE) | data
    /// v2 scheme ID: 0x7109871a, v3 scheme ID: 0xf05368c0
    private func extractCertFromSigningBlock(at apkPath: URL) -> (v2: Bool, v3: Bool, certificate: Data?)? {
        guard let handle = try? FileHandle(forReadingFrom: apkPath) else { return nil }
        defer { handle.closeFile() }

        // The APK Signing Block sits just before the Central Directory.
        // The Central Directory offset is stored in the End of Central Directory record.
        // EOCD is at most 65535+22 bytes from end of file.
        let fileSize = handle.seekToEndOfFile()
        guard fileSize > 22 else { return nil }

        let searchStart = fileSize > 65557 ? fileSize - 65557 : 0
        handle.seek(toFileOffset: searchStart)
        let tailData = handle.readData(ofLength: Int(fileSize - searchStart))
        let tailBytes = [UInt8](tailData)

        // Find EOCD signature: 0x06054b50
        var eocdOffset: Int?
        for i in stride(from: tailBytes.count - 22, through: 0, by: -1) {
            if tailBytes[i] == 0x50 && tailBytes[i+1] == 0x4b &&
               tailBytes[i+2] == 0x05 && tailBytes[i+3] == 0x06 {
                eocdOffset = i
                break
            }
        }
        guard let eocd = eocdOffset else { return nil }

        // Central Directory offset is at EOCD+16 (4 bytes LE)
        let cdOffset = UInt64(tailBytes[eocd+16]) |
                        (UInt64(tailBytes[eocd+17]) << 8) |
                        (UInt64(tailBytes[eocd+18]) << 16) |
                        (UInt64(tailBytes[eocd+19]) << 24)

        // The APK Signing Block magic "APK Sig Block 42" (16 bytes) ends just before cdOffset.
        // Before the magic are 8 bytes of block size.
        let magic = "APK Sig Block 42".data(using: .ascii)!
        guard cdOffset >= 24 else { return nil } // at minimum magic(16) + size(8)

        handle.seek(toFileOffset: cdOffset - 24)
        let trailer = handle.readData(ofLength: 24)
        guard trailer.count == 24 else { return nil }

        // last 16 bytes should be the magic
        guard trailer.subdata(in: 8..<24) == magic else { return nil }

        // block size (8 bytes LE) - this is the size from block_start+8 to end of magic
        let blockSize = trailer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self) }
        let blockStart = cdOffset - 8 - blockSize  // points to the first 8-byte size field

        // Read the signing block pairs region
        // Structure: [block_size_begin (8)] [pairs...] [block_size_end (8)] [magic (16)]
        guard blockSize > 24, blockStart + 8 < cdOffset - 24 else { return nil }
        let pairsStart = blockStart + 8
        let pairsEnd = cdOffset - 24  // just before block_size_end

        let pairsLen = pairsEnd - pairsStart
        guard pairsLen > 0, pairsLen < 50_000_000 else { return nil } // sanity limit

        handle.seek(toFileOffset: pairsStart)
        let pairsData = handle.readData(ofLength: Int(pairsLen))
        guard pairsData.count == Int(pairsLen) else { return nil }

        let v2ID: UInt32 = 0x7109871a
        let v3ID: UInt32 = 0xf05368c0
        var foundV2 = false
        var foundV3 = false
        var firstCert: Data?

        var offset = 0
        while offset + 12 <= pairsData.count {
            let pairSize: UInt64 = pairsData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
            let pairID: UInt32 = pairsData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self) }
            let dataStart = offset + 12
            let dataLen = Int(pairSize) - 4 // pairSize includes the 4-byte ID

            guard dataLen >= 0, dataStart + dataLen <= pairsData.count else { break }

            if pairID == v2ID {
                foundV2 = true
                if firstCert == nil {
                    firstCert = extractCertFromV2Signer(pairsData.subdata(in: dataStart..<(dataStart + dataLen)))
                }
            } else if pairID == v3ID {
                foundV3 = true
                if firstCert == nil {
                    firstCert = extractCertFromV2Signer(pairsData.subdata(in: dataStart..<(dataStart + dataLen)))
                }
            }

            offset += 8 + Int(pairSize)
        }

        guard foundV2 || foundV3 else { return nil }
        return (foundV2, foundV3, firstCert)
    }

    /// Extracts the first DER X.509 certificate from a v2/v3 signer block.
    /// Structure: signers_seq_len(4) → signer_len(4) → signed_data_len(4) → signed_data
    ///   signed_data: digests_seq_len(4) → digests_data → certs_seq_len(4) → certs_data
    ///   certs_data: cert_len(4) → cert_DER_data
    private func extractCertFromV2Signer(_ data: Data) -> Data? {
        guard data.count > 20 else { return nil }
        let bytes = data.withUnsafeBytes { ptr -> UnsafeRawBufferPointer in ptr }

        func readU32(_ offset: Int) -> Int? {
            guard offset + 4 <= data.count else { return nil }
            return Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }

        // signers_seq_len → first signer_len → signed_data_len → signed_data
        guard let signersSeqLen = readU32(0), signersSeqLen > 0 else { return nil }
        // first signer starts at offset 4
        guard let signerLen = readU32(4), signerLen > 0 else { return nil }
        // signed_data starts at offset 8
        guard let signedDataLen = readU32(8), signedDataLen > 0 else { return nil }
        // signed_data body starts at offset 12
        let signedDataStart = 12

        // First field of signed_data: digests sequence
        guard let digestsSeqLen = readU32(signedDataStart) else { return nil }
        let certsSeqOffset = signedDataStart + 4 + digestsSeqLen

        // certificates sequence
        guard let certsSeqLen = readU32(certsSeqOffset), certsSeqLen > 0 else { return nil }
        let firstCertOffset = certsSeqOffset + 4

        // first certificate: length-prefixed DER data
        guard let certLen = readU32(firstCertOffset), certLen > 0,
              firstCertOffset + 4 + certLen <= data.count else { return nil }

        return data.subdata(in: (firstCertOffset + 4)..<(firstCertOffset + 4 + certLen))
    }

    /// Parses a PKCS#7 / CMS signature block to extract the signer certificate's subject DN.
    /// Uses Apple's Security framework to decode the X.509 certificate.
    private func extractCertificateDN(from pkcs7Data: Data) -> String {
        // Try to create a SecCertificate directly (works for DER-encoded certs)
        if let cert = SecCertificateCreateWithData(nil, pkcs7Data as CFData) {
            return formatCertificateDN(cert)
        }

        // For PKCS#7 containers, extract embedded certificates via SecTrust
        // PKCS#7 SignedData wraps the certificate(s). We need to find the
        // X.509 certificate within the ASN.1 structure.
        if let dn = extractDNFromPKCS7(pkcs7Data) {
            return dn
        }

        return "N/A"
    }

    /// Extracts the subject DN from a PKCS#7 SignedData container by finding
    /// embedded X.509 certificates in the ASN.1 structure.
    private func extractDNFromPKCS7(_ data: Data) -> String? {
        // Scan for X.509 certificate sequences within PKCS#7 data.
        // X.509 certs start with ASN.1 SEQUENCE (0x30) followed by length.
        // The OID for X.509 certificate is 2.5.4.x for DN attributes.
        // We look for the certificate OID pattern and try each candidate.
        let bytes = [UInt8](data)

        for i in 0..<(bytes.count - 4) {
            // Look for SEQUENCE tag with multi-byte length (typical for certs)
            guard bytes[i] == 0x30 else { continue }

            let certData: Data?
            let totalLen: Int

            if bytes[i + 1] == 0x82 && i + 4 < bytes.count {
                // 2-byte length
                let len = (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
                totalLen = 4 + len
                guard i + totalLen <= bytes.count, totalLen > 100 else { continue }
                certData = Data(bytes[i..<(i + totalLen)])
            } else if bytes[i + 1] == 0x83 && i + 5 < bytes.count {
                // 3-byte length
                let len = (Int(bytes[i + 2]) << 16) | (Int(bytes[i + 3]) << 8) | Int(bytes[i + 4])
                totalLen = 5 + len
                guard i + totalLen <= bytes.count, totalLen > 100 else { continue }
                certData = Data(bytes[i..<(i + totalLen)])
            } else {
                continue
            }

            guard let candidateData = certData,
                  let cert = SecCertificateCreateWithData(nil, candidateData as CFData) else {
                continue
            }

            return formatCertificateDN(cert)
        }

        return nil
    }

    /// Formats a SecCertificate's subject into a readable DN string.
    private func formatCertificateDN(_ cert: SecCertificate) -> String {
        // SecCertificateCopySubjectSummary returns the CN or a descriptive summary
        if let summary = SecCertificateCopySubjectSummary(cert) as String?, !summary.isEmpty {
            return summary
        }

        // Fallback: parse the subject DN from the raw DER data
        let derData = SecCertificateCopyData(cert) as Data
        if let dn = parseSubjectDNFromDER(derData) {
            return dn
        }

        return "N/A"
    }

    /// Parses the Subject DN fields from raw DER-encoded X.509 certificate data.
    /// Extracts common RDN attributes (CN, O, OU, L, ST, C) from the ASN.1 structure.
    private func parseSubjectDNFromDER(_ data: Data) -> String? {
        let bytes = [UInt8](data)

        // Known OID to label mapping for common X.500 attributes
        let oidLabels: [[UInt8]: String] = [
            [0x55, 0x04, 0x03]: "CN",   // commonName
            [0x55, 0x04, 0x06]: "C",    // countryName
            [0x55, 0x04, 0x07]: "L",    // locality
            [0x55, 0x04, 0x08]: "ST",   // stateOrProvince
            [0x55, 0x04, 0x0A]: "O",    // organization
            [0x55, 0x04, 0x0B]: "OU",   // organizationalUnit
        ]

        var parts: [String] = []

        // Scan for OID sequences (06 03 55 04 xx) followed by a string value
        for i in 0..<(bytes.count - 7) {
            guard bytes[i] == 0x06, bytes[i + 1] == 0x03, bytes[i + 2] == 0x55, bytes[i + 3] == 0x04 else {
                continue
            }

            let oid = Array(bytes[(i + 2)...(i + 4)])
            guard let label = oidLabels[oid] else { continue }

            // The value follows: string tag (0x0C UTF8, 0x13 PrintableString, 0x16 IA5) + length + value
            let valueStart = i + 5
            guard valueStart + 2 < bytes.count else { continue }
            let tag = bytes[valueStart]
            guard tag == 0x0C || tag == 0x13 || tag == 0x16 || tag == 0x1E else { continue }
            let len = Int(bytes[valueStart + 1])
            guard valueStart + 2 + len <= bytes.count else { continue }

            let valueBytes = Data(bytes[(valueStart + 2)..<(valueStart + 2 + len)])
            if let str = String(data: valueBytes, encoding: .utf8) {
                parts.append("\(label)=\(str)")
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
    #endif
}
