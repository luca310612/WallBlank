import Cocoa
import MetalKit
import SwiftUI
import WebKit

// MARK: - DisplayWallpaperInstance + Fullscreen
// Why: フルスクリーン検知とアクティブアプリ監視を集約。

extension DisplayWallpaperInstance {

    func setupFullscreenMonitor() {
        // イベント駆動: アプリアクティベーション時に即座にチェック
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // デスクトップクリックでウィンドウが退いたあと、壁紙が奥に回りメニューバーがシステム壁紙を拾うことがある
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier == "com.apple.finder",
               self.settings.desktopItemsClickable == false {
                self.window?.orderFrontRegardless()
            }
            self.checkFullscreenState()
        }

        // フルスクリーン検出にはポーリングが必要（システム通知APIがないため）
        fullscreenCheckTimer = Timer.scheduledTimer(withTimeInterval: AppConstants.TimerIntervals.fullscreenCheck, repeats: true) { [weak self] _ in
            self?.checkFullscreenState()
        }
        debugLog("[Instance:\(displayID)] Fullscreen monitor started (event-driven + 1s polling)")
    }

    func checkFullscreenState() {

        // 設定が無効な場合はチェックしない
        guard settings.pauseWhenFullscreen || settings.pauseWhenOtherAppActive else {
            if isScreenCoveredByFullscreen {
                isScreenCoveredByFullscreen = false
                resumeInternal()
            }
            return
        }

        // この画面のDisplayIDを取得
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return
        }

        let wasFullscreen = isScreenCoveredByFullscreen
        isScreenCoveredByFullscreen = false

        // すべてのウィンドウ情報を取得
        let windowListOptions = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let windowInfoList = CGWindowListCopyWindowInfo(windowListOptions, kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        // この画面のBoundsを取得（CG座標系）
        let screenBounds = CGDisplayBounds(screenNumber)

        // 他のアプリがアクティブかチェック（ディスプレイごとに独立して判定）
        if settings.pauseWhenOtherAppActive {
            let frontApp = NSWorkspace.shared.frontmostApplication
            let frontAppBundleID = frontApp?.bundleIdentifier
            let frontAppPID = frontApp?.processIdentifier

            // Artia自身がフロントの場合は停止しない
            let isArtiaFront = frontAppBundleID == Bundle.main.bundleIdentifier

            // Finderがフロントの場合は停止しない
            let isFinderFront = frontAppBundleID == "com.apple.finder"

            if !isArtiaFront && !isFinderFront {
                // フロントアプリのウィンドウがこのディスプレイ上にあるかチェック
                var frontAppHasWindowOnThisScreen = false

                for windowInfo in windowInfoList {
                    // ウィンドウの所有者PIDを取得
                    guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32 else {
                        continue
                    }

                    // フロントアプリのウィンドウかどうか
                    guard ownerPID == frontAppPID else {
                        continue
                    }

                    // ウィンドウのレイヤーをチェック（通常のウィンドウレベル以上）
                    guard let windowLayer = windowInfo[kCGWindowLayer as String] as? Int32,
                          windowLayer >= 0 else {
                        continue
                    }

                    // ウィンドウの境界を取得
                    guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                          let x = boundsDict["X"],
                          let y = boundsDict["Y"],
                          let width = boundsDict["Width"],
                          let height = boundsDict["Height"] else {
                        continue
                    }

                    let windowBounds = CGRect(x: x, y: y, width: width, height: height)

                    // このディスプレイと重なりがあるかチェック
                    if windowBounds.intersects(screenBounds) {
                        // 十分なサイズのウィンドウがこのディスプレイ上にある
                        let intersection = windowBounds.intersection(screenBounds)
                        let minWindowSize = AppConstants.Performance.minWindowSize
                        if intersection.width >= minWindowSize && intersection.height >= minWindowSize {
                            frontAppHasWindowOnThisScreen = true
                            break
                        }
                    }
                }

                // フロントアプリのウィンドウがこのディスプレイ上にある場合のみ一時停止
                if frontAppHasWindowOnThisScreen {
                    isScreenCoveredByFullscreen = true
                }
            }
        }

        // フルスクリーンチェック（pauseWhenFullscreenが有効で、まだカバーされていない場合のみ）
        if settings.pauseWhenFullscreen && !isScreenCoveredByFullscreen {
            for windowInfo in windowInfoList {
                // ウィンドウの所有者（アプリ名）を取得
                guard let ownerName = windowInfo[kCGWindowOwnerName as String] as? String else {
                    continue
                }

                // システムアプリは無視
                if ownerName == "Artia" || ownerName == "Dock" || ownerName == "Finder" {
                    continue
                }

                // ウィンドウのレイヤーをチェック（デスクトップレベルより上）
                guard let windowLayer = windowInfo[kCGWindowLayer as String] as? Int32,
                      windowLayer >= 0 else {
                    continue
                }

                // ウィンドウの境界を取得
                guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                      let x = boundsDict["X"],
                      let y = boundsDict["Y"],
                      let width = boundsDict["Width"],
                      let height = boundsDict["Height"] else {
                    continue
                }

                let windowBounds = CGRect(x: x, y: y, width: width, height: height)

                // この画面と交差しないウィンドウは無視
                guard windowBounds.intersects(screenBounds) else {
                    continue
                }

                // フルスクリーンチェック（画面をほぼ完全にカバーしているか）
                let coverageThreshold = AppConstants.Performance.fullscreenCoverageThreshold
                let intersection = windowBounds.intersection(screenBounds)
                let coverage = (intersection.width * intersection.height) / (screenBounds.width * screenBounds.height)

                if coverage >= coverageThreshold {
                    isScreenCoveredByFullscreen = true
                    break
                }
            }
        }

        // 状態が変わった場合のみログ出力と状態更新
        if wasFullscreen != isScreenCoveredByFullscreen {
            if isScreenCoveredByFullscreen {
                debugLog("[Instance:\(displayID)] Screen covered or other app active on this display - pausing")
                pauseInternal()
            } else {
                debugLog("[Instance:\(displayID)] Screen not covered - resuming")
                resumeInternal()
            }
        }
    }
}
