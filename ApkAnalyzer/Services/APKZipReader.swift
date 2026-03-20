import Foundation
import ZIPFoundation

/// Swift ZIP reader for APK files, backed by ZIPFoundation.
/// Provides a simple API for listing entries and extracting file data.
final class APKZipReader {

    // MARK: - Types

    /// A single file entry in the ZIP archive.
    struct Entry {
        let path: String
        let uncompressedSize: UInt64
    }

    // MARK: - Properties

    private let archive: Archive
    private(set) var entries: [Entry] = []

    // MARK: - Init

    /// Opens a ZIP (APK) file.
    /// Returns `nil` if the file cannot be opened or is not a valid ZIP.
    init?(url: URL) {
        guard let archive = Archive(url: url, accessMode: .read) else { return nil }
        self.archive = archive
        self.entries = archive.compactMap { zipEntry -> Entry? in
            guard zipEntry.type == .file else { return nil }
            return Entry(path: zipEntry.path, uncompressedSize: zipEntry.uncompressedSize)
        }
    }

    // MARK: - Public API

    /// Extract a single entry by its path. Returns the decompressed file data.
    func extractEntry(path: String) -> Data? {
        guard let zipEntry = archive[path] else { return nil }
        var result = Data()
        _ = try? archive.extract(zipEntry) { data in
            result.append(data)
        }
        return result.isEmpty ? nil : result
    }
}
