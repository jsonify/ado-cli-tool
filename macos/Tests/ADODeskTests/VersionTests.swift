import XCTest
@testable import ADODesk

/// The version line in Settings → Updates, from the Info.plist build_app.sh writes.
final class VersionTests: XCTestCase {
    func testVersionBuildAndCommit() {
        let info = ["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "412", "ADODeskCommit": "48db438"]
        XCTAssertEqual(Updater.versionLine(info), "0.2.0 (412, 48db438)")
    }

    func testBundleWithoutCommit() {
        XCTAssertEqual(Updater.versionLine(["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "48db438"]),
                       "0.1.0 (48db438)")
    }

    func testNoInfoPlist() {
        XCTAssertEqual(Updater.versionLine(nil), "dev")
    }
}
