import SwiftUI

@main
struct DAVDriveApp: App {
    @State private var model = AccountsModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AccountsView()
                .environment(model)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { Task { await model.syncDomains() } }
                }
        }
    }
}
