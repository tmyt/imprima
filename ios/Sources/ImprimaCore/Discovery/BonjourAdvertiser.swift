import Foundation
import dnssd
import os

/// DNS-SD registration of `_ipp._tcp` (with subtypes) via dnssd's DNSServiceRegister. FROZEN INTERFACE.
public final class BonjourAdvertiser {
    private static let log = Logger(subsystem: "dev.utatane.imprima", category: "bonjour")

    private let name: String
    private let port: UInt16
    private let txt: [String: String]
    private let subtypes: [String]
    /// All DNSService calls (register, callbacks, deallocate) happen on this queue.
    private let queue = DispatchQueue(label: "dev.utatane.imprima.bonjour")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var ref: DNSServiceRef?
    private var name_: String?

    /// - Parameters:
    ///   - subtypes: e.g. ["universal", "print"] (no leading underscore; registered as "_ipp._tcp,_universal,_print")
    public init(name: String, port: UInt16, txt: [String: String], subtypes: [String] = ["universal", "print"]) {
        self.name = name
        self.port = port
        self.txt = txt
        self.subtypes = subtypes
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { unregister() }

    /// "_ipp._tcp,_universal,_print"
    var registrationType: String {
        (["_ipp._tcp"] + subtypes.map { $0.hasPrefix("_") ? $0 : "_" + $0 }).joined(separator: ",")
    }

    /// TXT keys in a stable order: txtvers first (per DNS-SD convention), then alphabetical.
    var orderedTxtKeys: [String] {
        txt.keys.sorted { a, b in
            if a == "txtvers" { return b != "txtvers" }
            if b == "txtvers" { return false }
            return a < b
        }
    }

    /// Registers and processes results on a background thread. Throws on immediate failure.
    public func register() throws {
        try onQueue { try registerLocked() }
    }

    private func registerLocked() throws {
        if ref != nil { return }
        var record = TXTRecordRef()
        TXTRecordCreate(&record, 0, nil)
        defer { TXTRecordDeallocate(&record) }
        for key in orderedTxtKeys {
            let value = Array(txt[key]!.utf8)
            guard value.count <= 255 else { throw StreamError.io("TXT value too long for key \(key)") }
            let err = value.withUnsafeBytes {
                TXTRecordSetValue(&record, key, UInt8(value.count), $0.baseAddress)
            }
            guard err == kDNSServiceErr_NoError else { throw StreamError.io("TXTRecordSetValue(\(key)) failed: \(err)") }
        }

        var newRef: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let err = DNSServiceRegister(
            &newRef, 0, 0, name, registrationType, nil, nil,
            port.bigEndian,
            TXTRecordGetLength(&record), TXTRecordGetBytesPtr(&record),
            { _, _, errorCode, name, _, _, context in
                guard let context = context else { return }
                let me = Unmanaged<BonjourAdvertiser>.fromOpaque(context).takeUnretainedValue()
                me.didRegister(errorCode: errorCode, name: name.map { String(cString: $0) })
            },
            context)
        guard err == kDNSServiceErr_NoError, let r = newRef else {
            throw StreamError.io("DNSServiceRegister failed: \(err)")
        }
        let qerr = DNSServiceSetDispatchQueue(r, queue)
        guard qerr == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(r)
            throw StreamError.io("DNSServiceSetDispatchQueue failed: \(qerr)")
        }
        ref = r
    }

    private func didRegister(errorCode: DNSServiceErrorType, name: String?) {
        if errorCode == kDNSServiceErr_NoError {
            lock.lock(); name_ = name; lock.unlock()
            Self.log.info("registered \(name ?? "?", privacy: .public) \(self.registrationType, privacy: .public) port \(self.port)")
        } else {
            Self.log.error("registration failed: \(errorCode)")
        }
    }

    /// Deregisters. Idempotent.
    public func unregister() {
        onQueue {
            if let r = ref {
                DNSServiceRefDeallocate(r)
                ref = nil
            }
        }
        lock.lock(); name_ = nil; lock.unlock()
    }

    /// Name actually registered (after conflict renaming), once known.
    public var registeredName: String? {
        lock.lock(); defer { lock.unlock() }
        return name_
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }
}
