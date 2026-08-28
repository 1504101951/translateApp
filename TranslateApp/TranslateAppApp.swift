import AppKit
import SwiftUI
import TranslateCore

@main
struct TranslateAppApp: App {
    @State private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("选区翻译", systemImage: "globe") {
            if !model.accessibilityTrusted {
                Text("需要辅助功能权限才能读取其他应用中的选中文本。")
                Button("授予辅助功能权限") {
                    model.requestAccessibility()
                }
                Divider()
            }
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
