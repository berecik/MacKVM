import SwiftUI

@main
struct MacKVMApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
#if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1920, height: 1080 + 44) // framebuffer + toolbar
#endif
    }
}
