import XCTest
import Darwin
@testable import ImprimaCore

final class BonjourAdvertiserTests: XCTestCase {
    private static let dnsSd = "/usr/bin/dns-sd"

    /// Runs dns-sd for `seconds`, then terminates it and returns its stdout.
    private func runDnsSd(_ args: [String], seconds: TimeInterval) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.dnsSd)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        Thread.sleep(forTimeInterval: seconds)
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// A free TCP port (bound then released).
    private func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    private func waitForName(_ adv: BonjourAdvertiser, timeout: TimeInterval = 5) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let n = adv.registeredName { return n }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    func testRegistrationType() {
        let adv = BonjourAdvertiser(name: "x", port: 1, txt: ["rp": "a", "txtvers": "1", "ty": "b"])
        XCTAssertEqual(adv.registrationType, "_ipp._tcp,_universal,_print")
        XCTAssertEqual(adv.orderedTxtKeys, ["txtvers", "rp", "ty"])
        adv.unregister()
        adv.unregister()
    }

    func testRegisterAndResolveTxt() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.dnsSd))
        let name = "Imprima Test \(UInt32.random(in: 0...UInt32.max))"
        let adv = BonjourAdvertiser(name: name, port: try freePort(), txt: ["rp": "ipp/print", "txtvers": "1"])
        try adv.register()
        defer { adv.unregister() }
        let registered = try XCTUnwrap(waitForName(adv), "register callback never fired")
        XCTAssertEqual(registered, name)
        let out = try runDnsSd(["-L", registered, "_ipp._tcp", "local."], seconds: 5)
        XCTAssertTrue(out.contains("rp=ipp/print"), "dns-sd -L output:\n\(out)")
        XCTAssertTrue(out.contains("txtvers=1"), "dns-sd -L output:\n\(out)")
    }

    func testUniversalSubtypeBrowsable() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.dnsSd))
        let name = "Imprima Test \(UInt32.random(in: 0...UInt32.max))"
        let adv = BonjourAdvertiser(name: name, port: try freePort(), txt: ["rp": "ipp/print", "txtvers": "1"])
        try adv.register()
        defer { adv.unregister() }
        let registered = try XCTUnwrap(waitForName(adv), "register callback never fired")
        // Browses the _universal._sub._ipp._tcp subtype; dns-sd rejects the "_sub" spelling
        // (DNSServiceBrowse -65540) and expects "<type>,<subtype>" instead.
        let out = try runDnsSd(["-B", "_ipp._tcp,_universal", "local."], seconds: 4)
        XCTAssertTrue(out.contains(registered), "dns-sd -B output:\n\(out)")
    }
}
