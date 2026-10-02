import Foundation

/// DNS-SD registration of `_ipp._tcp` (with subtypes) via dnssd's DNSServiceRegister. FROZEN INTERFACE.
public final class BonjourAdvertiser {
    /// - Parameters:
    ///   - subtypes: e.g. ["universal", "print"] (no leading underscore; registered as "_ipp._tcp,_universal,_print")
    public init(name: String, port: UInt16, txt: [String: String], subtypes: [String] = ["universal", "print"]) { fatalError("TODO unit swift-http") }
    /// Registers and processes results on a background thread. Throws on immediate failure.
    public func register() throws { fatalError("TODO unit swift-http") }
    /// Deregisters. Idempotent.
    public func unregister() { fatalError("TODO unit swift-http") }
    /// Name actually registered (after conflict renaming), once known.
    public var registeredName: String? { fatalError("TODO unit swift-http") }
}
