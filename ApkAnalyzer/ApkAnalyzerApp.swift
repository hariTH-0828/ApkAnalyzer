import SwiftUI

@main
struct ApkAnalyzerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                #if targetEnvironment(macCatalyst)
                .frame(minWidth: 600, minHeight: 500)
                #endif
        }
    }
}
