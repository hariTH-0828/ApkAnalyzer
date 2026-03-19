import Foundation

/// Executes shell commands using posix_spawn, which is available in Mac Catalyst
/// (unlike Foundation.Process which is marked unavailable).
enum ShellExecutor {

    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Runs an executable at `path` with the given arguments and returns the result.
    static func run(executablePath: String, arguments: [String]) throws -> Result {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        // Build argv: [executable, arg1, arg2, ..., nil]
        let argv: [UnsafeMutablePointer<CChar>?] = ([executablePath] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { $0.map { free($0) } } }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executablePath, &fileActions, nil, argv, environ)
        posix_spawn_file_actions_destroy(&fileActions)

        guard spawnResult == 0 else {
            throw APKError.executionFailed("posix_spawn failed with code \(spawnResult)")
        }

        // Close write ends so reads don't hang
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        // Wait for child
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        // WIFEXITED/WEXITSTATUS are C macros, replicate the bit logic
        let exitCode: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return Result(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: exitCode
        )
    }
}
