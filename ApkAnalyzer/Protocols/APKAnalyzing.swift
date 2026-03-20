import Foundation

/// Abstraction for APK metadata extraction (Dependency Inversion Principle).
///
/// The ViewModel depends on this protocol rather than a concrete service,
/// enabling testability and allowing alternative implementations.
protocol APKAnalyzing {
    /// Copies the APK to a sandbox-safe temporary location.
    func copyToTempDirectory(apkURL: URL) throws -> URL
    /// Extracts all metadata from an APK at the given path.
    func extractMetadata(from apkPath: URL) throws -> APKMetadata
}
