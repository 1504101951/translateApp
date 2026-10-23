import Cocoa
import Carbon
import FlutterMacOS

/// 设置使用独立 Flutter 引擎和普通窗口；浮层保持非激活且不共享视图控制器。
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var engine: FlutterEngine?
    private var window: NSWindow?
    private var channel: FlutterMethodChannel?
    private var recordingMonitor: Any?
    private var recordingResult: FlutterResult?

    /// 无参数；按需创建设置引擎，激活设置窗口，无返回值。
    func show() {
        if let window {
            refresh()
            WindowEngine.present(window)
            return
        }
        // WindowEngine 统一装配附属窗口引擎（#120）。
        guard let started = WindowEngine.start(
            name: AppConstants.settingsEngineName, entrypoint: AppConstants.settingsEntrypoint,
            channel: AppConstants.settingsChannel, handler: { [weak self] call, result in
                let bridge = MacPlatformBridge.Shared.instance!
                switch call.method {
                case AppConstants.recordShortcutMethod:
                    self?.recordShortcut(result: result)
                default:
                    // routeWindowRequest统一区分主引擎业务和系统操作，窗口仅保留快捷键录制。
                    bridge.routeWindowRequest(call, result: result)
                }
            }) else {
            WindowEngine.reportStartFailure("设置窗口")
            return
        }
        engine = started.engine
        channel = started.channel
        // WindowEngine.makeWindow 建出承载原生玻璃内容的普通窗口；设置窗关闭后保留引擎以便快速重开。
        let window = WindowEngine.makeWindow(
            flutter: started.flutter, title: "TranslateApp 设置", size: NSSize(width: 560, height: 720),
            minSize: NSSize(width: 520, height: 500), delegate: self)
        self.window = window
        WindowEngine.present(window)
    }

    /// result 接收 keyCode/modifiers/label，取消为 nil；仅在当前设置窗口录制一次组合。
    private func recordShortcut(result: @escaping FlutterResult) {
        finishRecording(nil)
        recordingResult = result
        MacPlatformBridge.Shared.instance?.shortcutRecorder = { [weak self] keyCode, modifiers in
            let preferences = UserDefaults.standard.dictionary(forKey: AppConstants.preferencesKey) ?? [:]
            // 被系统吞掉的只会是已注册的三种全局快捷键之一，按组合找回已保存的显示名。
            let purpose = GlobalHotKey.allCases.first {
                preferences[$0.keyCodeKey] as? UInt32 == keyCode && preferences[$0.modifiersKey] as? UInt32 == modifiers
            }
            let label = purpose.flatMap { preferences[$0.labelKey] as? String } ?? ""
            self?.finishRecording(["keyCode": keyCode, "modifiers": modifiers, "label": label])
        }
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            if event.keyCode == 53 {
                self.finishRecording(nil)
                return nil
            }
            let flags = event.modifierFlags
            let modifiers: UInt32 = (flags.contains(.command) ? 256 : 0)
                | (flags.contains(.shift) ? 512 : 0)
                | (flags.contains(.option) ? 2048 : 0)
                | (flags.contains(.control) ? 4096 : 0)
            do {
                try SelectionMonitor.validateShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
                let special: [UInt16: String] = [
                    36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 76: "Enter",
                    115: "Home", 116: "Page Up", 117: "⌦", 119: "End", 121: "Page Down",
                    123: "←", 124: "→", 125: "↓", 126: "↑",
                    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                    98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
                    105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
                ]
                let label = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
                self.finishRecording(["keyCode": Int(event.keyCode), "modifiers": modifiers, "label": label])
            } catch {
                self.finishRecording(FlutterError(code: AppConstants.shortcutInvalidError, message: error.localizedDescription, details: nil))
            }
            // 录制时消费组合键，避免 Command-Q/W 等触发设置窗口菜单；其他窗口不受影响。
            return nil
        }
    }

    /// value 为录制结果或 FlutterError/nil；先解除回调再通知 Dart，防止重复完成。
    private func finishRecording(_ value: Any?) {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        MacPlatformBridge.Shared.instance?.shortcutRecorder = nil
        let result = recordingResult
        recordingResult = nil
        result?(value)
    }

    /// notification 为设置窗口失焦通知；中止录制并保留原有组合，无返回值。
    func windowDidResignKey(_ notification: Notification) { finishRecording(nil) }

    /// 无参数；菜单改动或再次打开窗口时刷新主引擎快照，无返回值。
    func refresh() {
        channel?.invokeMethod(AppConstants.refreshSettingsMethod, arguments: nil)
    }

    deinit {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        MacPlatformBridge.Shared.instance?.shortcutRecorder = nil
        channel?.setMethodCallHandler(nil)
        // Flutter 引擎必须显式停止，关闭窗口只隐藏以便快速重新打开。
        engine?.shutDownEngine()
    }
}
