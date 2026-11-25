import DAVCore
import SwiftUI

struct AccountsView: View {
    @Environment(AccountsModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var editing: EditTarget?
    @State private var resetting: Account?
    @State private var browsing: Account?
    /// Bumped when the app comes back to the foreground: the Files extension
    /// records its errors in shared defaults from another process, so the
    /// rows only see new ones on a redraw.
    @State private var tick = 0

    enum EditTarget: Identifiable {
        case new, existing(Account)
        var id: String {
            switch self {
            case .new: "new"
            case .existing(let account): account.id
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                if model.accounts.isEmpty {
                    ContentUnavailableView {
                        Label("No Servers", systemImage: "externaldrive.badge.wifi")
                    } description: {
                        Text("Add a WebDAV server and it shows up in the Files app under Locations.")
                    } actions: {
                        Button("Add Server") { editing = .new }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Section {
                        ForEach(model.accounts) { account in
                            row(account)
                        }
                    } footer: {
                        Text("Tap the list icon on a server to read its folders right here. To use them in other apps, open the Files app, tap Browse and look under Locations. With one server, Files calls it DAV Drive. If syncing is stuck, swipe right on the server and tap Reset Sync.")
                    }
                    Section {
                        NavigationLink("Ignore Rules") { IgnoreRulesView() }
                    }
                }
            }
            .navigationTitle("DAV Drive")
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { tick &+= 1 }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Server", systemImage: "plus") { editing = .new }
                }
            }
            .sheet(item: $editing) { target in
                switch target {
                case .new: AccountEditor(account: nil)
                case .existing(let account): AccountEditor(account: account)
                }
            }
            .sheet(item: $browsing) { account in
                BrowserView(account: account)
            }
            .confirmationDialog(
                "Reset \(resetting?.name ?? "")?",
                isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Reset Sync", role: .destructive) {
                    if let account = resetting { Task { await model.resetSync(account) } }
                }
            } message: {
                Text("Removes this server from Files and adds it back. Files on the server aren't touched; changes still waiting to upload and downloaded copies on this iPhone are discarded.")
            }
            .alert("Something Went Wrong", isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.lastError ?? "")
            }
        }
    }

    /// One line per configured address, LAN first.
    private func addressLines(_ account: Account) -> [String] {
        var lines: [String] = []
        if account.hasLAN { lines.append("LAN · \(account.lanURLString)") }
        if account.hasWAN { lines.append("Public · \(account.wanURLString)") }
        return lines.isEmpty ? ["No address"] : lines
    }

    private func row(_ account: Account) -> some View {
        let _ = tick
        let lastError = ProviderDiagnostics.lastError(forAccountID: account.id)
        return Button {
            editing = .existing(account)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).foregroundStyle(.primary)
                    ForEach(addressLines(account), id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let lastError {
                        Text("F-01 扩展报错 (Extension error) (\(lastError.when.formatted(date: .omitted, time: .shortened))): \(lastError.message)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    }
                }
                Spacer()
                Button("Browse", systemImage: "list.bullet.rectangle") {
                    browsing = account
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                Button("Open in Files", systemImage: "folder") {
                    Task { await model.openInFiles(account) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await model.delete(account) }
            }
        }
        .swipeActions(edge: .leading) {
            Button("Reset Sync", systemImage: "arrow.clockwise") { resetting = account }
                .tint(.orange)
        }
        .contextMenu {
            Button("Browse", systemImage: "list.bullet.rectangle") { browsing = account }
            Button("Open in Files", systemImage: "folder") { Task { await model.openInFiles(account) } }
            Button("Edit", systemImage: "pencil") { editing = .existing(account) }
            Button("Reset Sync", systemImage: "arrow.clockwise") { resetting = account }
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.delete(account) } }
        }
    }
}
