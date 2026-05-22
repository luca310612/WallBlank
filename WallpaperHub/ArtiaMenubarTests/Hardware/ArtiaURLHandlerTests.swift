import XCTest
import Foundation

@testable import WallBlank

/// Phase 8.5: artia:// URL のパース純粋関数テスト。
final class ArtiaURLHandlerTests: XCTestCase {

    @MainActor
    func test_parse_wallpaperSetSimpleId() {
        let url = URL(string: "artia://wallpaper/set/wp123")!
        XCTAssertEqual(ArtiaURLHandler.parse(url), .wallpaperSet(target: "wp123"))
    }

    @MainActor
    func test_parse_wallpaperSetEncodedPath() {
        // /tmp/wall paper.png を URL エンコードしたもの
        let url = URL(string: "artia://wallpaper/set/%2Ftmp%2Fwall%20paper.png")!
        XCTAssertEqual(ArtiaURLHandler.parse(url), .wallpaperSet(target: "/tmp/wall paper.png"))
    }

    @MainActor
    func test_parse_navigation() {
        XCTAssertEqual(ArtiaURLHandler.parse(URL(string: "artia://wallpaper/next")!), .wallpaperNext)
        XCTAssertEqual(ArtiaURLHandler.parse(URL(string: "artia://wallpaper/prev")!), .wallpaperPrev)
        XCTAssertEqual(ArtiaURLHandler.parse(URL(string: "artia://wallpaper/random")!), .wallpaperRandom)
    }

    @MainActor
    func test_parse_playlistSwitch() {
        let url = URL(string: "artia://playlist/switch/morning")!
        XCTAssertEqual(ArtiaURLHandler.parse(url), .playlistSwitch(id: "morning"))
    }

    @MainActor
    func test_parse_profileSwitch() {
        let url = URL(string: "artia://profile/switch/balanced")!
        XCTAssertEqual(ArtiaURLHandler.parse(url), .profileSwitch(id: "balanced"))
    }

    @MainActor
    func test_parse_propertySet() {
        let url = URL(string: "artia://property/set/fps/30")!
        XCTAssertEqual(ArtiaURLHandler.parse(url), .propertySet(key: "fps", value: "30"))
    }

    @MainActor
    func test_parse_unknownScheme_returnsUnknown() {
        let url = URL(string: "https://example.com/wallpaper/set/x")!
        if case .unknown = ArtiaURLHandler.parse(url) {
            // OK
        } else {
            XCTFail("scheme 違いは .unknown を返すべき")
        }
    }

    @MainActor
    func test_parse_emptyTarget_returnsUnknown() {
        let url = URL(string: "artia://wallpaper/set/")!
        if case .unknown = ArtiaURLHandler.parse(url) {
            // OK
        } else {
            XCTFail("set の target が空なら .unknown")
        }
    }

    @MainActor
    func test_resolveProfile_acceptsNamesAndDigits() {
        XCTAssertEqual(ArtiaURLHandler.resolveProfile(id: "low"), .low)
        XCTAssertEqual(ArtiaURLHandler.resolveProfile(id: "Balanced"), .balanced)
        XCTAssertEqual(ArtiaURLHandler.resolveProfile(id: "ultra"), .ultra)
        XCTAssertEqual(ArtiaURLHandler.resolveProfile(id: "0"), .low)
        XCTAssertEqual(ArtiaURLHandler.resolveProfile(id: "3"), .ultra)
        XCTAssertNil(ArtiaURLHandler.resolveProfile(id: "extreme"))
    }
}
