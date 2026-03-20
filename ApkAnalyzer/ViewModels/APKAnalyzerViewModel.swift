import Foundation
import UIKit
import SwiftUI

/// ViewModel for APK analysis, depends on `APKAnalyzing` abstraction (DIP).
@MainActor
final class APKAnalyzerViewModel: ObservableObject {
    @Published var metadata: APKMetadata?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedFileName: String?
    @Published var showDocumentPicker = false

    private let service: APKAnalyzing

    // MARK: - Init (Constructor Injection)

    init(service: APKAnalyzing = APKExtractionService()) {
        self.service = service
    }

    func selectAndAnalyzeAPK() {
        showDocumentPicker = true
    }

    func analyzeAPK(at url: URL) {
        isLoading = true
        errorMessage = nil
        metadata = nil
        selectedFileName = url.lastPathComponent

        let didStartAccessing = url.startAccessingSecurityScopedResource()

        Task {
            do {
                let tempURL = try service.copyToTempDirectory(apkURL: url)

                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }

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
