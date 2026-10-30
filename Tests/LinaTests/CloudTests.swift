import XCTest
@testable import Lina

final class CloudTests: XCTestCase {
    func testReportUsesTheTableColumns() throws {
        let row = Cloud.ProblemReport(installId: UUID(), appVersion: "1.2.0", kind: "It's slow or got stuck",
                                      note: "", report: "# Lina problem report")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["install_id", "app_version", "kind", "note", "report"])
    }

    func testInstallIDStaysTheSame() {
        XCTAssertEqual(Cloud.installID, Cloud.installID)
    }
}
