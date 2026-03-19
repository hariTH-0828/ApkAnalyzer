import Foundation

enum APKError: LocalizedError {
    case toolNotFound
    case executionFailed(String)
    case invalidAPK
    case unsupportedFormat
    case iconExtractionFailed
    case fileAccessDenied

    var errorDescription: String? {
        switch self {
        case .toolNotFound:
            return "aapt2 tool not found in app bundle."
        case .executionFailed(let message):
            return "Execution failed: \(message)"
        case .invalidAPK:
            return "The selected file is not a valid APK."
        case .unsupportedFormat:
            return "Unsupported APK format."
        case .iconExtractionFailed:
            return "Failed to extract app icon."
        case .fileAccessDenied:
            return "Cannot access the selected file."
        }
    }
}
