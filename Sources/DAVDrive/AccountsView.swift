import DAVCore
import SwiftUI

struct AccountsView: View {
    @Environment(AccountsModel.self) private var model
    @State private var editing: EditTarget?
    @State private var resetting: Account?

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
                        Text("Open the Files app, tap Browse and look under Locations. With one server, Files calls it DAV Drive. If syncing is stuck, swipe right on the server and tap Reset Sync.")
                    }
                    Section {
                        NavigationLink("Ignore Rules") { IgnoreRulesView() }
                    }
                }
            }
            .navigationTitle("DAV Drive")
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
        Button {
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
                }
                Spacer()
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
            Button("Open in Files", systemImage: "folder") { Task { await model.openInFiles(account) } }
            Button("Edit", systemImage: "pencil") { editing = .existing(account) }
            Button("Reset Sync", systemImage: "arrow.clockwise") { resetting = account }
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.delete(account) } }
        }
    }
}
