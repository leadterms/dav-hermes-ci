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
                        Label("还没有接入点", systemImage: "externaldrive.badge.wifi")
                    } description: {
                        Text("添加一个 WebDAV 服务器，它就会出现在文件 App 的「位置」里。")
                    } actions: {
                        Button("添加接入点") { editing = .new }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Section {
                        ForEach(model.accounts) { account in
                            row(account)
                        }
                    } footer: {
                        Text("点服务器后面的列表图标，可以直接在这里看它的文件夹。要在别的 App 里用，就打开文件 App，点「浏览」，在「位置」里找它；只配一个服务器时，文件 App 里显示为 DAV Drive。同步卡住了，就向右滑那个服务器，点「重置同步」。")
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
                    Button("添加接入点", systemImage: "plus") { editing = .new }
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
                "重置 \(resetting?.name ?? "")？",
                isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }),
                titleVisibility: .visible
            ) {
                Button("重置同步", role: .destructive) {
                    if let account = resetting { Task { await model.resetSync(account) } }
                }
            } message: {
                Text("把这个服务器从文件 App 里移除再重新添加。服务器上的文件不受影响；还没上传的改动和这台 iPhone 上已下载的副本会丢弃。")
            }
            .alert("出错了", isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(model.lastError ?? "")
            }
        }
    }

    /// One line per configured address, LAN first.
    private func addressLines(_ account: Account) -> [String] {
        var lines: [String] = []
        if account.hasLAN { lines.append("局域网 · \(account.lanURLString)") }
        if account.hasWAN { lines.append("公网 · \(account.wanURLString)") }
        return lines.isEmpty ? ["未配置地址"] : lines
    }

    private func row(_ account: Account) -> some View {
        let _ = tick
        let lastError = ProviderDiagnostics.lastError(forAccountID: account.id)
        let event = ProviderDiagnostics.lastEvent()
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
                        Text("F-01 扩展报错（\(lastError.when.formatted(date: .omitted, time: .shortened))）：\(lastError.message)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    }
                    if let event {
                        let stopped = event.message.contains("E-OFF")
                        Text("\(stopped ? "⚠" : "✓") \(event.message) · \(event.when.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(stopped ? Color.orange : Color.green)
                            .lineLimit(2)
                    } else {
                        Text("F-05 扩展从未启动")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button("浏览", systemImage: "list.bullet.rectangle") {
                    browsing = account
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                Button("在文件 App 中打开", systemImage: "folder") {
                    Task { await model.openInFiles(account) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
        .swipeActions {
            Button("删除", systemImage: "trash", role: .destructive) {
                Task { await model.delete(account) }
            }
        }
        .swipeActions(edge: .leading) {
            Button("重置同步", systemImage: "arrow.clockwise") { resetting = account }
                .tint(.orange)
        }
        .contextMenu {
            Button("浏览", systemImage: "list.bullet.rectangle") { browsing = account }
            Button("在文件 App 中打开", systemImage: "folder") { Task { await model.openInFiles(account) } }
            Button("编辑", systemImage: "pencil") { editing = .existing(account) }
            Button("重置同步", systemImage: "arrow.clockwise") { resetting = account }
            Button("删除", systemImage: "trash", role: .destructive) { Task { await model.delete(account) } }
        }
    }
}
