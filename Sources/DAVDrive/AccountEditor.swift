import DAVCore
import SwiftUI
import UniformTypeIdentifiers

struct AccountEditor: View {
    let original: Account?

    @Environment(AccountsModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var lanURLString: String
    @State private var wanURLString: String
    @State private var username: String
    @State private var password: String
    /// Cloudflare Access service token for the public endpoint (ID in plain
    /// text, secret in the durable password store).
    @State private var wanClientID: String
    @State private var wanClientSecret: String
    /// Fixed for the life of the editor: the account id keys the password and
    /// token stores, so it must not change between the test and the save.
    @State private var draftID: String
    @State private var pinnedCertificate: Data?
    @State private var importingCertificate = false

    @State private var test: TestState = .idle
    @State private var confirmSaveAnyway = false

    enum TestState: Equatable {
        case idle, running, ok(String), failed(String)
    }

    init(account: Account?) {
        original = account
        _name = State(initialValue: account?.name ?? "")
        _lanURLString = State(initialValue: account?.lanURLString ?? "")
        _wanURLString = State(initialValue: account?.wanURLString ?? "")
        _username = State(initialValue: account?.username ?? "")
        _password = State(initialValue: account.flatMap { Passwords.password(for: $0.id) } ?? "")
        _wanClientID = State(initialValue: account?.wanClientID ?? "")
        _wanClientSecret = State(initialValue: account.map { AccountStore.cfSecret(for: $0.id) } ?? "")
        _draftID = State(initialValue: account?.id ?? UUID().uuidString)
        _pinnedCertificate = State(initialValue: account?.pinnedCertificate)
    }

    private var draft: Account {
        Account(
            id: draftID,
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? (nameHostHint ?? "WebDAV") : name.trimmingCharacters(in: .whitespaces),
            lanURLString: lanURLString.trimmingCharacters(in: .whitespacesAndNewlines),
            wanURLString: wanURLString.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username,
            wanClientID: wanClientID,
            pinnedCertificate: pinnedCertificate
        )
    }

    /// The host of the first filled-in address, for the name placeholder.
    /// Deliberately computed from the raw URL strings: `draft` needs this
    /// value while it is being built, so it must never read back through
    /// `draft` (that cycle recurses forever and overflows the stack).
    private var nameHostHint: String? {
        var hint: String? = nil
        if let url = URL(string: wanURLString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            hint = url.host()
        }
        if hint == nil, let url = URL(string: lanURLString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            hint = url.host()
        }
        return hint
    }

    private var draftHost: String? {
        (draft.wanURL ?? draft.lanURL)?.host()
    }

    private var draftUsable: Bool { draft.lanURL != nil || draft.wanURL != nil }

    /// Says where the password comes from (or why it can't be kept), so an
    /// empty password field is never a mystery. Short codes:
    /// G-01 shared storage unavailable · P-01 no stored copy · P-OK stored.
    private var signInFooter: String {
        guard let id = original?.id else {
            return "首次保存：密码只需输入这一次，以后重装都在。"
        }
        let d = Passwords.diagnostic(for: id)
        var lines: [String] = []
        if !d.groupAvailable {
            lines.append("G-01 共享存储不可用（签名配置没有授权 App Group）：文件 App 扩展暂时用不了，密码改存本机钥匙串。")
        }
        if d.inFile {
            lines.append("P-OK 密码副本：共享存储")
        } else if d.inKeychain {
            lines.append("P-OK 密码副本：钥匙串")
        } else if d.inLocalKeychain {
            lines.append("P-OK 密码副本：本机钥匙串（重装后保留）")
        } else {
            lines.append("P-01 还没有密码副本：输入一次并保存")
        }
        let availability = d.groupAvailable ? "" : "（不可用）"
        lines.append("共享组：\(d.groupID)\(availability)")
        return lines.joined(separator: "\n")
    }

    /// The endpoints a connection test tries, LAN first.
    private var draftEndpoints: [Endpoint] {
        var endpoints: [Endpoint] = []
        if let url = draft.lanURL {
            endpoints.append(Endpoint(url: url, username: username, password: password,
                                      isWan: false, pinnedCertificate: pinnedCertificate))
        }
        if let url = draft.wanURL {
            let headers = AccountStore.cfAccessHeaders(clientID: wanClientID, secret: wanClientSecret)
            endpoints.append(Endpoint(url: url, username: username, password: password,
                                      isWan: true, cfAccessHeaders: headers))
        }
        return endpoints
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("局域网地址", text: $lanURLString, prompt: Text("http://192.168.1.10:8080/dav/"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("公网地址", text: $wanURLString, prompt: Text("https://dav.example.com/"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("地址")
                } footer: {
                    Text("填一个或两个都填。局域网地址（http 或 https）只要能连上就优先用它，在家时不走外网。公网地址必须是 https，用蜂窝网络或局域网连不上时才会用它。")
                }

                Section {
                    TextField("名称", text: $name, prompt: Text(draftHost ?? "显示在文件 App 里的名字"))
                } header: {
                    Text("名称")
                }

                Section {
                    TextField("用户名", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("账号密码")
                } footer: {
                    Text(signInFooter)
                }

                if !wanURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        TextField("访问密钥 ID", text: $wanClientID)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("访问密钥 Secret", text: $wanClientSecret)
                    } header: {
                        Text("公网登录（Cloudflare Access）")
                    } footer: {
                        Text("公网地址开了 Cloudflare Access 才需要填：在 Cloudflare 零信任里建一个 Service Token，把 ID 和 Secret 填这里。只对公网地址生效，局域网地址不带这两个头。")
                    }
                }

                Section {
                    Button {
                        importingCertificate = true
                    } label: {
                        HStack {
                            Text("固定证书")
                            Spacer()
                            Text(pinnedCertificate == nil ? "未设置" : "已设置")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if pinnedCertificate != nil {
                        Button("移除证书", role: .destructive) { pinnedCertificate = nil }
                    }
                } footer: {
                    Text("只用于自签名的局域网地址：服务器必须出示的正是这张证书（.cer/.pem）。其他情况走系统正常校验，别的证书一律不信任。")
                }

                Section {
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack {
                            Text("测试连接")
                            Spacer()
                            testStatus
                        }
                    }
                    .disabled(!draftUsable || test == .running)
                    if case .failed(let message) = test {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(original == nil ? "添加接入点" : "编辑接入点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await saveTapped() } }
                        .disabled(!draftUsable || test == .running)
                }
            }
            .confirmationDialog("连接测试没通过。", isPresented: $confirmSaveAnyway, titleVisibility: .visible) {
                Button("仍然保存") { Task { await save() } }
                Button("继续编辑", role: .cancel) {}
            }
            .fileImporter(isPresented: $importingCertificate, allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                pinnedCertificate = try? Data(contentsOf: url)
            }
        }
        .interactiveDismissDisabled(test == .running)
    }

    @ViewBuilder private var testStatus: some View {
        switch test {
        case .idle: EmptyView()
        case .running: ProgressView()
        case .ok(let summary):
            Label(summary, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.footnote)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    @discardableResult
    private func runTest() async -> Bool {
        test = .running
        do {
            let (mode, items) = try await WebDAVClient.testConnection(endpoints: draftEndpoints)
            let label = mode == .lan ? "局域网" : "公网"
            test = .ok("\(label) · \(items) 项")
            return true
        } catch {
            test = .failed("T-01 \(error.localizedDescription)")
            return false
        }
    }

    private func saveTapped() async {
        // Remember the password as soon as it is entered: a strong password is
        // painful to type again, and the connection test below may fail for a
        // reason that has nothing to do with it.
        if let id = original?.id, !password.isEmpty {
            Passwords.write(password, for: id)
        }
        if case .ok = test {
            await save()
        } else if await runTest() {
            await save()
        } else {
            confirmSaveAnyway = true
        }
    }

    private func save() async {
        // Store the Cloudflare token secret with the same durability as the
        // password (app-group file first), so Files can log in after a reinstall.
        if !AccountStore.setCFSecret(wanClientSecret, for: draftID) {
            model.lastError = "P-02 密码没能保存，重装后要重新输入。"
        }
        await model.save(draft, password: password)
        dismiss()
    }
}
