import Foundation

/// macOS bundle implementation of ShellHelperProtocol.
/// Uses Foundation.Process (available on macOS but not Mac Catalyst).
/// Loaded at runtime by the Catalyst app via Bundle.load() + NSPrincipalClass.
@objc
class ShellHelper: NSObject, ShellHelperProtocol {
    
    required override init() {
        
    }

    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: String?,
        timeout: Double
    ) -> [String: Any] {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        // Merge environment
        if let env = environment {
            var merged = ProcessInfo.processInfo.environment
            merged.merge(env) { _, new in new }
            process.environment = merged
        }

        // Working directory
        if let dir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        // Pipes
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Launch
        do {
            try process.run()
        } catch {
            return [
                "stdout": "",
                "stderr": error.localizedDescription,
                "exitCode": Int32(-1),
                "didTimeout": false
            ]
        }

        // Timeout handling
        var didTimeout = false
        if timeout > 0 {
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning {
                    didTimeout = true
                    process.terminate()
                }
            }
        }

        process.waitUntilExit()

        // Read output
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return [
            "stdout": String(data: outputData, encoding: .utf8) ?? "",
            "stderr": String(data: errorData, encoding: .utf8) ?? "",
            "exitCode": process.terminationStatus,
            "didTimeout": didTimeout
        ]
    }
}
