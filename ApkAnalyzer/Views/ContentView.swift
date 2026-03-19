import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = APKAnalyzerViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header / Drop zone
                APKDropZoneView(viewModel: viewModel)

                Divider()

                // Results
                if viewModel.isLoading {
                    Spacer()
                    ProgressView("Analyzing APK...")
                        .padding()
                    Spacer()
                } else if let metadata = viewModel.metadata {
                    APKDetailView(metadata: metadata)
                } else if let error = viewModel.errorMessage {
                    Spacer()
                    ErrorBannerView(message: error)
                    Spacer()
                } else {
                    Spacer()
                    Text("Select an APK file to begin analysis.")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                    Spacer()
                }
            }
            .navigationTitle("APK Analyzer")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.selectAndAnalyzeAPK()
                    } label: {
                        Label("Open APK", systemImage: "doc.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $viewModel.showDocumentPicker) {
                DocumentPicker { url in
                    viewModel.analyzeAPK(at: url)
                }
            }
        }
    }
}
