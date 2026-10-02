import SwiftUI

@main
struct RasaPrinterApp: App {
    @StateObject private var service = PrinterService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(service)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { service.refreshAddresses() }
                }
        }
    }
}
