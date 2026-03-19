import Foundation
import UIKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class APKAnalyzerViewModel: ObservableObject {
    @Published var metadata: APKMetadata?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedFileName: String?
    @Published var showDocumentPicker = false

    private let service = APKExtractionService()

    func selectAndAnalyzeAPK() {
        showDocumentPicker = true
    }

    func analyzeAPK(at url: URL) {
        isLoading = true
        errorMessage = nil
        metadata = nil
        selectedFileName = url.lastPathComponent

        // Gain access to security-scoped resource
        let didStartAccessing = url.startAccessingSecurityScopedResource()

        Task {
            do {
                // Copy APK to temp directory for sandbox-safe access
                let tempURL = try service.copyToTempDirectory(apkURL: url)

                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }

                // Run extraction on background thread
                let result = try await Task.detached { [service] in
                    try service.extractMetadata(from: tempURL)
                }.value

                self.metadata = result
            } catch let error as APKError {
                self.errorMessage = error.errorDescription
            } catch {
                self.errorMessage = error.localizedDescription
            }

            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
            self.isLoading = false
        }
    }
}

// MARK: - Document Picker

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let apkType = UTType(filenameExtension: "apk") ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [apkType])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
