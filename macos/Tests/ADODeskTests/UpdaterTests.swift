import XCTest
@testable import ADODesk

/// Check for Updates…: versions, GitHub's release JSON and SHA256SUMS.
final class UpdaterTests: XCTestCase {
    func testNewerVersions() {
        XCTAssertTrue(Updater.isNewer("0.3.3", than: "0.3.2"))
        XCTAssertTrue(Updater.isNewer("0.3.10", than: "0.3.9"))
        XCTAssertTrue(Updater.isNewer("1.0.0", than: "0.9.9"))
        XCTAssertTrue(Updater.isNewer("v0.4", than: "0.3.9"))
        XCTAssertTrue(Updater.isNewer("0.3.2.1", than: "0.3.2"))
    }

    func testSameOrOlderVersions() {
        XCTAssertFalse(Updater.isNewer("0.3.2", than: "0.3.2"))
        XCTAssertFalse(Updater.isNewer("0.3", than: "0.3.0"))
        XCTAssertFalse(Updater.isNewer("0.3.1", than: "0.3.2"))
        XCTAssertFalse(Updater.isNewer("0.2.10", than: "0.3.0"))
    }

    func testDevBuildsNeverUpdate() {
        XCTAssertFalse(Updater.isNewer("0.3.3", than: "dev"))
        XCTAssertFalse(Updater.isNewer("nightly", than: "0.3.2"))
        XCTAssertFalse(Updater.isNewer("0.3.", than: "0.3.2"))
    }

    private func json(tag: String = "v0.3.3", draft: Bool = false, prerelease: Bool = false,
                      assets: [String] = ["ADO-Desk-0.3.3.dmg", "ADO-Desk-0.3.3.zip", "SHA256SUMS"]) -> Data {
        let list = assets.map {
            ["name": $0, "browser_download_url": "https://github.com/jsonify/ado-desk/releases/download/\(tag)/\($0)"]
        }
        let object: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": list,
                                     "html_url": "https://github.com/jsonify/ado-desk/releases/tag/\(tag)"]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testReleaseFromJSON() {
        let base = "https://github.com/jsonify/ado-desk/releases"
        XCTAssertEqual(Updater.release(fromJSON: json()), Release(
            version: "0.3.3", page: URL(string: "\(base)/tag/v0.3.3")!,
            zip: URL(string: "\(base)/download/v0.3.3/ADO-Desk-0.3.3.zip")!,
            checksums: URL(string: "\(base)/download/v0.3.3/SHA256SUMS")!))
    }

    func testReleaseNotReadyOrNotFinal() {
        XCTAssertNil(Updater.release(fromJSON: json(assets: [])), "files not attached yet")
        XCTAssertNil(Updater.release(fromJSON: json(assets: ["ADO-Desk-0.3.3.zip"])), "no checksums")
        XCTAssertNil(Updater.release(fromJSON: json(assets: ["ADO-Desk-0.3.2.zip", "SHA256SUMS"])), "another version's zip")
        XCTAssertNil(Updater.release(fromJSON: json(draft: true)))
        XCTAssertNil(Updater.release(fromJSON: json(prerelease: true)))
        XCTAssertNil(Updater.release(fromJSON: Data("{\"message\": \"Not Found\"}".utf8)))
        XCTAssertNil(Updater.release(fromJSON: Data("not json".utf8)))
    }

    func testChecksumLookup() {
        let sums = """
            1c90a84f1de50fa9372a39e1f5253a7fd3218c9c81acf3971411dd1c65881dc7  ADO-Desk-0.3.3.zip
            7C6F09AA3D77D081B3248279738CC5B40B05726ADC35AE2A871A708B7BFE94A8 *ADO-Desk-0.3.3.dmg

            """
        XCTAssertEqual(Updater.checksum(for: "ADO-Desk-0.3.3.zip", in: sums),
                       "1c90a84f1de50fa9372a39e1f5253a7fd3218c9c81acf3971411dd1c65881dc7")
        XCTAssertEqual(Updater.checksum(for: "ADO-Desk-0.3.3.dmg", in: sums),
                       "7c6f09aa3d77d081b3248279738cc5b40b05726adc35ae2a871a708b7bfe94a8")
        XCTAssertNil(Updater.checksum(for: "ADO-Desk-0.3.2.zip", in: sums))
    }

    func testSHA256() {
        XCTAssertEqual(Updater.sha256(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
