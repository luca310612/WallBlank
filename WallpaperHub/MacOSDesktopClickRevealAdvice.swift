import AppKit
import CoreFoundation
import Foundation
import UserNotifications

/// macOS の「壁紙をクリックしてデスクトップを表示」が「常に」のとき、ユーザーにシステム設定への誘導を出す（設定値は変更しない）。
enum MacOSDesktopClickRevealAdvice {

    /// システム設定の「デスクトップと Dock」（デスクトップとステージマネージャを含む）を開く。
    static let desktopDockSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!

    private static let notificationIdentifier = "com.artia.desktopClickRevealAdvice"
    private static let nudgeCooldownSeconds: TimeInterval = 7 * 24 * 3600

    /// 設定画面のトグルと共有（通知を止める）。
    static let suppressUserDefaultsKey = "artia_suppressDesktopClickRevealNudge"
    private static let lastNudgeKey = "artia_lastDesktopClickRevealNudgeAt"

    private static let wmDomain = "com.apple.WindowManager" as CFString
    private static let wmKey = "EnableStandardClickToShowDesktop" as CFString

    /// 「常に」相当（クリックでウィンドウが退く）か。取得できない場合は `false`（通知しない）。
    static func isClickWallpaperRevealEffectivelyAlwaysOn() -> Bool {
        guard let raw = CFPreferencesCopyAppValue(wmKey, wmDomain) else { return false }
        if CFGetTypeID(raw) == CFBooleanGetTypeID() {
            return CFEqual(raw, kCFBooleanTrue)
        }
        if let n = raw as? NSNumber { return n.boolValue }
        return false
    }

    static func openDesktopDockSystemSettings() {
        NSWorkspace.shared.open(desktopDockSettingsURL)
    }

    /// 通知の許可を求め、条件を満たせばローカル通知を1件スケジュールする。
    static func scheduleLocalReminderIfAppropriate(appMode: AppMode) {
        switch appMode {
        case .combined, .controller:
            break
        case .engine:
            return
        }

        guard UserDefaults.standard.bool(forKey: suppressUserDefaultsKey) == false else { return }
        guard isClickWallpaperRevealEffectivelyAlwaysOn() else { return }

        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastNudgeKey)
        if last > 0, now - last < nudgeCooldownSeconds {
            return
        }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                debugLog("[ClickRevealAdvice] 通知が許可されていないためスキップします")
                return
            }
            center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])

            let content = UNMutableNotificationContent()
            content.title = "壁紙をクリックするとウィンドウが退きます"
            content.body = "システム設定の「壁紙をクリックしてデスクトップを表示」を「ステージマネージャ使用時のみ」にすると、壁紙の操作がしやすくなります。通知をクリックして設定を開けます。"
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: trigger)
            center.add(request) { error in
                if let error {
                    debugLog("[ClickRevealAdvice] 通知のスケジュールに失敗: \(error)")
                } else {
                    UserDefaults.standard.set(now, forKey: lastNudgeKey)
                }
            }
        }
    }

    static func handleNotificationResponse(_ response: UNNotificationResponse) {
        guard response.notification.request.identifier == notificationIdentifier else { return }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        openDesktopDockSystemSettings()
    }
}
