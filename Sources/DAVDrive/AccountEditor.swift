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
        _pinnedCertificate = State(initialValue: account?.pinnedCertificate)
    }

    private var draft: Account {
        Account(
            id: original?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? (nameHostHint ?? "WebDAV") : name.trimmingCharacters(in: .whitespaces),
            lanURLString: lanURLString.trimmingCharacters(in: .whitespacesAndNewlines),
            wanURLString: wanURLString.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username,
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
            return "首次保存：密码只需输入这一次，以后重装都在。 (First save: you only need to enter the password this once; it will persist through reinstalls.)"
        }
        let d = Passwords.diagnostic(for: id)
        var lines: [String] = []
        if !d.groupAvailable {
            lines.append("G-01 共享存储不可用（签名配置未授权 App Group）：文件 App 扩展暂不可用，密码改存本机钥匙串。 (G-01 Shared storage unavailable (signing profile does not authorize the App Group): the Files app extension is not currently usable; the password is stored in the local keychain instead.)")
        }
        if d.inFile {
            lines.append("P-OK 密码副本：共享存储 (P-OK Password copy: shared storage)")
        } else if d.inKeychain {
            lines.append("P-OK 密码副本：钥匙串 (P-OK Password copy: keychain)")
        } else if d.inLocalKeychain {
            lines.append("P-OK 密码副本：本机钥匙串（重装保留） (P-OK Password copy: local keychain (preserved across reinstalls))")
        } else {
            lines.append("P-01 尚无密码副本：输入一次并保存 (P-01 No password copy yet: enter it once and save)")
        }
        lines.append("共享组 (Shared group): \(d.groupID)\(d.groupAvailable ? "" : "（不可用）(unavailable)"))
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
            endpoints.append(Endpoint(url: url, username: username, password: password, isWan: true))
        }
        return endpoints
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("LAN Address", text: $lanURLString, prompt: Text("http://192.168.1.10:8080/dav/"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Public Address", text: $wanURLString, prompt: Text("https://dav.example.com/"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Addresses")
                } footer: {
                    Text("Fill in one or both. The LAN address (http or https) is used while it answers, so the app stays off the internet at home. The public address must be https and is used on cellular or when the LAN address doesn't answer.")
                }

                Section {
                    TextField("Name", text: $name, prompt: Text(draftHost ?? "Shown in Files"))
                } header: {
                    Text("Name")
                }

                Section {
                    TextField("User Name", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Sign In")
                } footer: {
                    Text(signInFooter)
                }

                Section {
                    Button {
                        importingCertificate = true
                    } label: {
                        HStack {
                            Text("Pinned Certificate")
                            Spacer()
                            Text(pinnedCertificate == nil ? "Not Set" : "Set")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if pinnedCertificate != nil {
                        Button("Remove Certificate", role: .destructive) { pinnedCertificate = nil }
                    }
                } footer: {
                    Text("Only for a self-signed LAN address: the host must present exactly this certificate (.cer/.pem). Everything else uses normal system validation; other certificates are not trusted.")
                }

                Section {
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack {
                            Text("Test Connection")
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
            .navigationTitle(original == nil ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await saveTapped() } }
                        .disabled(!draftUsable || test == .running)
                }
            }
            .confirmationDialog("The connection test failed.", isPresented: $confirmSaveAnyway, titleVisibility: .visible) {
                Button("Save Anyway") { Task { await save() } }
                Button("Keep Editing", role: .cancel) {}
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
            let label = mode == .lan ? "LAN" : "Public"
            test = .ok("\(label) · \(items) item\(items == 1 ? "" : "s")")
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
        await model.save(draft, password: password)
        dismiss()
    }
}
