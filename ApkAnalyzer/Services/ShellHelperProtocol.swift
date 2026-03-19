import Foundation

/// @objc protocol bridging the Mac Catalyst app to the macOS ShellHelper bundle.
/// The bundle implements this using Foundation.Process (macOS-only API).
@objc(ShellHelperProtocol)
protocol ShellHelperProtocol: NSObjectProtocol {
    
    init()
    
    /// Runs an executable with arguments and optional configuration.
    ///
    /// - Parameters:
    ///   - executablePath: Absolute path to the executable.
    ///   - arguments: Arguments to pass.
    ///   - environment: Optional additional environment variables.
    ///   - workingDirectory: Optional working directory path.
    ///   - timeout: Timeout in seconds (0 = no timeout).
    /// - Returns: Dictionary with "stdout" (String), "stderr" (String),
    ///            "exitCode" (Int32), "didTimeout" (Bool).
    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: String?,
        timeout: Double
    ) -> [String: Any]
}
