import AppKit

@MainActor
enum AppDialogs {
    static func replacementAlert(oldestName: String, preferences: AppPreferences) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = preferences.text("最多收藏 5 个位置")
        alert.informativeText = preferences.format("是否覆盖最老的收藏“%@”？", oldestName)
        // Replace is the default action; Escape still cancels the operation.
        // Destructive tinting in the current SDK produces red text on red fill.
        let cancel = alert.addButton(withTitle: preferences.text("取消"))
        cancel.keyEquivalent = "\u{1b}"
        let replace = alert.addButton(withTitle: preferences.text("覆盖"))
        replace.hasDestructiveAction = false
        replace.keyEquivalent = "\r"
        alert.window.defaultButtonCell = replace.cell as? NSButtonCell
        return alert
    }

    static func confirmReplacement(oldestName: String, preferences: AppPreferences, completion: @escaping (Bool) -> Void) {
        let alert = replacementAlert(oldestName: oldestName, preferences: preferences)
        if let window = NSApp.mainWindow {
            alert.beginSheetModal(for: window) { completion($0 == .alertSecondButtonReturn) }
        } else {
            completion(alert.runModal() == .alertSecondButtonReturn)
        }
    }
}
