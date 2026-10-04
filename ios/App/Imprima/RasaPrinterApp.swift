import SwiftUI

@main
struct ImprimaApp: App {
    @StateObject private var service = PrinterService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(service)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { service.refreshAddresses() }
                }
                .onAppear {
                    // Test hook: `xcrun simctl launch <udid> dev.utatane.imprima --autostart`
                    if ProcessInfo.processInfo.arguments.contains("--autostart") { service.start() }
                }
        }
    }
}
