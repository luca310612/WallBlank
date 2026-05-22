import Foundation
import AppKit

/// ディスプレイ管理のプロトコル
protocol DisplayManagerProtocol: ObservableObject {
    var connectedDisplays: [DisplayInfo] { get }
    var enabledDisplayIDs: Set<String> { get }
    var displayArrangement: [String: DisplayLayoutConfiguration] { get }
    var spanWallpaperAcrossDisplays: Bool { get }

    // MARK: - Display Detection
    func refreshDisplays()

    // MARK: - Display Enable/Disable
    func setDisplayEnabled(_ displayID: String, enabled: Bool)
    func isDisplayEnabled(_ displayID: String) -> Bool
    func setDisplayLayout(_ layout: DisplayLayoutConfiguration)
    func setDisplayArrangement(_ arrangement: [String: DisplayLayoutConfiguration])
    func resetDisplayArrangementToSystem()
    func setSpanWallpaperAcrossDisplays(_ enabled: Bool)

    // MARK: - Screen Lookup
    func screen(for displayID: String) -> NSScreen?
    func enabledScreens() -> [NSScreen]

    // MARK: - Persistence
    func loadEnabledDisplays()
    func saveEnabledDisplays()
}
