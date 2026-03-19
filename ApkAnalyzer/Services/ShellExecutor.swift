import Foundation

// MARK: - Result Types

/// Encapsulates the result of a shell command execution.
public struct ShellResult {
    /// Standard output from the process.
    public let output: String
    /// Standard error from the process.
    public let errorOutput: String
    /// The process exit code (0 typically means success).
    public let exitCode: Int32
    /// Whether the command exited successfully (exit code == 0).
    public var isSuccess: Bool { exitCode == 0 }
}

/// Errors thrown by ShellExecutor.
public enum ShellError: LocalizedError {
    case notSupportedOnPlatform
    case executionFailed(reason: String)
    case timeout
    case invalidExecutable(path: String)

    public var errorDescription: String? {
        switch self {
        case .notSupportedOnPlatform:
            return "Shell execution is not supported or not permitted on this platform/sandbox configuration."
        case .executionFailed(let reason):
            return "Execution failed: \(reason)"
        case .timeout:
            return "The shell command timed out."
        case .invalidExecutable(let path):
            return "Executable not found or not executable at path: \(path)"
        }
    }
}

// MARK: - ShellExecutor

/// A utility class for executing shell commands on Mac Catalyst.
///
/// Internally loads a macOS `ShellHelper.bundle` at runtime which uses
/// `Foundation.Process` — an API unavailable in the Mac Catalyst compilation
/// target. This keeps macOS-only code cleanly separated in its own bundle.
///
/// Usage:
/// ```swift
/// // Synchronous
/// let result = try ShellExecutor.shared.run("ls -la /tmp")
///
/// // Async/Await
/// let result = try await ShellExecutor.shared.runAsync("echo Hello")
///
/// // With environment & working directory
/// let result = try ShellExecutor.shared.run(
///     "/usr/bin/swift", arguments: ["--version"],
///     environment: ["PATH": "/usr/bin:/bin"],
///     workingDirectory: "/tmp",
///     timeout: 10
/// )
/// ```
public final class ShellExecutor: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = ShellExecutor()

    // MARK: - Configuration

    /// Default shell used when running commands as strings (e.g., `run("ls -la")`).
    public var defaultShell: String = "/bin/zsh"

    /// Default timeout in seconds. `nil` means no timeout.
    public var defaultTimeout: TimeInterval? = 30

    // MARK: - Bundle Helper

    private var _helper: ShellHelperProtocol?

    /// Loads the ShellHelper.bundle from PlugIns and returns the helper instance.
    private func helper() throws -> ShellHelperProtocol {
        if let h = _helper { return h }

        let bundleFileName = "ShellHelper.bundle"
        guard let bundleURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent(bundleFileName),
              let helperBundle = Bundle(url: bundleURL) else {
            throw ShellError.executionFailed(reason: "ShellHelper.bundle not found in PlugIns")
        }

        if !helperBundle.isLoaded {
            try helperBundle.loadAndReturnError()
        }

        guard let pluginClass = helperBundle.classNamed("ShellHelper.ShellHelper") as? ShellHelperProtocol.Type else {
            throw ShellError.executionFailed(reason: "Failed to load ShellHelper principle class")
        }
        
//        let cls: NSObject.Type
//        if let pc = helperBundle.principalClass as? NSObject.Type {
//            cls = pc
//        } else if let fallback = NSClassFromString("ShellHelperImpl") as? NSObject.Type {
//            cls = fallback
//        } else {
//            throw ShellError.executionFailed(reason: "Failed to load ShellHelper principal class")
//        }

//        guard let instance = cls.init() as? ShellHelperProtocol else {
//            throw ShellError.executionFailed(reason: "ShellHelper does not conform to ShellHelperProtocol")
//        }

        let instance = pluginClass.init()
        _helper = instance
        return instance
    }

    // MARK: - Init

    private init() {}

    // MARK: - Platform Guard

    /// Returns `true` if `Process` execution is available (macOS / Mac Catalyst on macOS).
    public var isShellExecutionAvailable: Bool {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Public API: String Command

    /// Runs a shell command string via the default shell (`/bin/zsh -c <command>`).
    @discardableResult
    public func run(
        _ command: String,
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        timeout: TimeInterval? = nil
    ) throws -> ShellResult {
        return try run(
            defaultShell,
            arguments: ["-c", command],
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
    }

    // MARK: - Public API: Executable + Arguments

    /// Runs an executable directly with arguments (no shell interpolation).
    @discardableResult
    public func run(
        _ executablePath: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        timeout: TimeInterval? = nil
    ) throws -> ShellResult {
        guard isShellExecutionAvailable else {
            throw ShellError.notSupportedOnPlatform
        }

        // Validate executable
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw ShellError.invalidExecutable(path: executablePath)
        }

        let h = try helper()
        let effectiveTimeout = timeout ?? defaultTimeout ?? 0

        let dict = h.run(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: effectiveTimeout
        )

        let didTimeout = dict["didTimeout"] as? Bool ?? false
        if didTimeout {
            throw ShellError.timeout
        }

        let output = dict["stdout"] as? String ?? ""
        let errorOutput = dict["stderr"] as? String ?? ""

        return ShellResult(
            output: output.trimmingCharacters(in: .newlines),
            errorOutput: errorOutput.trimmingCharacters(in: .newlines),
            exitCode: dict["exitCode"] as? Int32 ?? -1
        )
    }

    // MARK: - Public API: Async/Await

    /// Async version of `run(_:environment:workingDirectory:timeout:)`.
    public func runAsync(
        _ command: String,
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.run(
                        command,
                        environment: environment,
                        workingDirectory: workingDirectory,
                        timeout: timeout
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Async version of `run(_:arguments:environment:workingDirectory:timeout:)`.
    public func runAsync(
        _ executablePath: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.run(
                        executablePath,
                        arguments: arguments,
                        environment: environment,
                        workingDirectory: workingDirectory,
                        timeout: timeout
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Streaming Output (Callback-based)

    /// Runs a command and streams stdout line-by-line via a callback.
    ///
    /// Note: Streaming is implemented by running the command and delivering
    /// the full output on completion (the bundle bridge doesn't support
    /// incremental pipe reads). For true incremental streaming, use an
    /// XPC helper service.
    public func runStreaming(
        _ command: String,
        onOutput: @escaping (String) -> Void,
        onComplete: @escaping (Result<ShellResult, ShellError>) -> Void
    ) {
        guard isShellExecutionAvailable else {
            onComplete(.failure(.notSupportedOnPlatform))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try self.run(command)
                // Deliver output line-by-line
                let lines = result.output.components(separatedBy: "\n")
                for line in lines {
                    DispatchQueue.main.async { onOutput(line) }
                }
                DispatchQueue.main.async { onComplete(.success(result)) }
            } catch let error as ShellError {
                DispatchQueue.main.async { onComplete(.failure(error)) }
            } catch {
                DispatchQueue.main.async {
                    onComplete(.failure(.executionFailed(reason: error.localizedDescription)))
                }
            }
        }
    }
}

// MARK: - Convenience Extensions

public extension ShellExecutor {

    /// Returns the output string of a command, or `nil` on failure.
    func output(of command: String) -> String? {
        return try? run(command).output
    }

    /// Returns `true` if the command exits with code 0.
    func succeeds(_ command: String) -> Bool {
        return (try? run(command).isSuccess) ?? false
    }

    /// Returns the path of an executable using `which`.
    func which(_ tool: String) -> String? {
        let result = output(of: "which \(tool)")
        return result?.isEmpty == false ? result : nil
    }
}
