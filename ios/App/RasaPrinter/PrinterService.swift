import Foundation
import SwiftUI
import UIKit
import RasaPrinterCore

@MainActor
final class PrinterService: ObservableObject {
    @Published var config: PrinterConfig
    @Published var isRunning = false
    @Published var status = "Stopped"
    @Published var addresses: [String] = []
    @Published var jobs: [PrintJob] = []
    @Published var errorMessage: String?

    private static let configKey = "printerConfig"
    private var jobStore: FileJobStore?
    private var server: HttpServer?
    private var advertiser: BonjourAdvertiser?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let saved = try? JSONDecoder().decode(PrinterConfig.self, from: data) {
            config = saved
        } else {
            let name = String("Rasa Printer (\(UIDevice.current.name))".prefix(63))
            config = PrinterConfig(name: name, uuid: UUID().uuidString.lowercased())
            Self.persist(config)
        }
        addresses = Self.localIPv4Addresses()
    }

    private static func persist(_ config: PrinterConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    private func store() throws -> FileJobStore {
        if let jobStore { return jobStore }
        let fm = FileManager.default
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let s = FileJobStore(documentsDirectory: docs,
                             metadataURL: support.appendingPathComponent("jobs.json"),
                             converter: RasterDocumentConverter())
        s.onChange = { [weak self] list in
            Task { @MainActor [weak self] in self?.jobs = list }
        }
        jobStore = s
        jobs = s.list()
        return s
    }

    func start() {
        guard !isRunning else { return }
        errorMessage = nil
        do {
            let jobStore = try store()
            let printer = IppPrinterHandler(config: { [weak self] in
                // Config is read from the server threads; use the value captured at start.
                self?.activeConfig ?? PrinterConfig(name: "Rasa Printer", uuid: UUID().uuidString.lowercased())
            }, jobs: jobStore)
            activeConfig = config
            let http = IppHttpHandler(handler: printer, config: { [weak self] in self?.activeConfig ?? PrinterConfig(name: "Rasa Printer", uuid: "") },
                                      jobs: jobStore, iconPng: { Self.iconPng() })
            let server = HttpServer(port: config.port) { http.handle($0) }
            try server.start()
            self.server = server
            let port = server.boundPort
            let adv = BonjourAdvertiser(name: config.name, port: port, txt: PrinterAttributes.bonjourTxt(config: config))
            do {
                try adv.register()
                advertiser = adv
            } catch {
                server.stop()
                self.server = nil
                throw error
            }
            isRunning = true
            status = "Running on port \(port)"
            UIApplication.shared.isIdleTimerDisabled = true
            refreshAddresses()
        } catch {
            errorMessage = "Could not start printer: \(error.localizedDescription)"
            status = "Stopped"
            isRunning = false
        }
    }

    func stop() {
        advertiser?.unregister()
        advertiser = nil
        server?.stop()
        server = nil
        isRunning = false
        status = "Stopped"
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func updateConfig(_ new: PrinterConfig) {
        let wasRunning = isRunning
        if wasRunning { stop() }
        config = new
        Self.persist(new)
        if wasRunning { start() }
    }

    func deleteJob(_ id: Int32) {
        do { try store().delete(id) } catch { errorMessage = error.localizedDescription }
    }

    func refreshAddresses() {
        addresses = Self.localIPv4Addresses()
    }

    // Snapshot of config used by server threads.
    private nonisolated(unsafe) var activeConfigStorage = PrinterConfig(name: "Rasa Printer", uuid: "")
    private let configLock = NSLock()
    private nonisolated var activeConfig: PrinterConfig {
        get { configLock.lock(); defer { configLock.unlock() }; return activeConfigStorage }
        set { configLock.lock(); activeConfigStorage = newValue; configLock.unlock() }
    }

    private nonisolated static func iconPng() -> Data? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last, let image = UIImage(named: name) else { return nil }
        return image.pngData()
    }

    static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: host)
                if !result.contains(s) { result.append(s) }
            }
        }
        return result
    }
}
