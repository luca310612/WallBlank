import Foundation
import AppKit
import Combine
@testable import Artia

/// DisplayManagerProtocol の Mock 実装。
/// Why: WallpaperEngine / DisplayWallpaperInstance に注入し、ディスプレイ問い合わせの spy を取れるようにする。
final class MockDisplayManager: DisplayManagerProtocol {
    @Published var connectedDisplays: [DisplayInfo] = []
    @Published var enabledDisplayIDs: Set<String> = []
    @Published var displayArrangement: [String: DisplayLayoutConfiguration] = [:]
    @Published var spanWallpaperAcrossDisplays: Bool = false

    /// `screen(for:)` の戻り値を差し替えるためのスタブ
    var stubbedScreens: [String: NSScreen] = [:]

    // MARK: - Spy

    private(set) var refreshDisplaysCallCount: Int = 0
    private(set) var setDisplayEnabledCalls: [(id: String, enabled: Bool)] = []
    private(set) var screenLookupKeys: [String] = []
    private(set) var loadEnabledDisplaysCallCount: Int = 0
    private(set) var saveEnabledDisplaysCallCount: Int = 0

    // MARK: - DisplayManagerProtocol

    func refreshDisplays() {
        refreshDisplaysCallCount += 1
    }

    func setDisplayEnabled(_ displayID: String, enabled: Bool) {
        setDisplayEnabledCalls.append((displayID, enabled))
        if enabled {
            enabledDisplayIDs.insert(displayID)
        } else {
            enabledDisplayIDs.remove(displayID)
        }
    }

    func isDisplayEnabled(_ displayID: String) -> Bool {
        enabledDisplayIDs.contains(displayID)
    }

    func setDisplayLayout(_ layout: DisplayLayoutConfiguration) {
        displayArrangement[layout.id] = layout
    }

    func setDisplayArrangement(_ arrangement: [String: DisplayLayoutConfiguration]) {
        displayArrangement = arrangement
    }

    func resetDisplayArrangementToSystem() {
        displayArrangement.removeAll()
    }

    func setSpanWallpaperAcrossDisplays(_ enabled: Bool) {
        spanWallpaperAcrossDisplays = enabled
    }

    func screen(for displayID: String) -> NSScreen? {
        screenLookupKeys.append(displayID)
        return stubbedScreens[displayID]
    }

    func enabledScreens() -> [NSScreen] {
        enabledDisplayIDs.compactMap { stubbedScreens[$0] }
    }

    func loadEnabledDisplays() {
        loadEnabledDisplaysCallCount += 1
    }

    func saveEnabledDisplays() {
        saveEnabledDisplaysCallCount += 1
    }
}
