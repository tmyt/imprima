import XCTest
@testable import RasaPrinterCore

final class SmokeTests: XCTestCase {
    func testDataInputStream() throws {
        let s = DataInputStream(Data([1, 2, 3]))
        XCTAssertEqual(try s.readExactly(2), [1, 2])
        XCTAssertEqual(try s.readByte(), 3)
        XCTAssertNil(try s.readByte())
    }
}
