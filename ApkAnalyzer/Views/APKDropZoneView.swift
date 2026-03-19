import SwiftUI

struct APKDropZoneView: View {
    @ObservedObject var viewModel: APKAnalyzerViewModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 40))
                .foregroundStyle(isTargeted ? .blue : .secondary)

            if let fileName = viewModel.selectedFileName {
                Text(fileName)
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Text("Drop APK here or click Open")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Color.blue : Color.gray.opacity(0.3))
        )
        .padding()
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url, url.pathExtension.lowercased() == "apk" else { return }
                Task { @MainActor in
                    viewModel.analyzeAPK(at: url)
                }
            }
            return true
        }
    }
}
