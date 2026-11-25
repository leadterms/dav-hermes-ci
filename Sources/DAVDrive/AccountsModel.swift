import DAVCore
import FileProvider
import Network
import SwiftUI

/// The accounts, each registered with the system as a File Provider domain
/// so it shows up under Locations in the Files app.
@MainActor @Observable
final class AccountsModel {
    private(set) var accounts: [Account] = AccountStore.load()
    var lastError: String?

    /// Watches network changes so the preferred endpoint (LAN vs public) is
    /// re-decided and Files re-enumerates after a network swap.
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.github.crazyquark.davdrive.network")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in await self?.networkChanged() }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit { monitor.cancel() }

    func save(_ account: Account, password: String) async {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        AccountStore.save(accounts)
        // Durable app-group copy (survives uninstall) + Keychain (best effort).
        if !Passwords.write(password, for: account.id), !password.isEmpty {
            lastError = "P-02 密码没能保存，重装后要重新输入。"
        }
        await register(account)
        await clearErrors(account)
        ProviderDiagnostics.clear(forAccountID: account.id)
        await refreshPreferredEndpoint(account)
        if let manager = NSFileProviderManager(for: domain(for: account)) {
            try? await manager.reimportItems(below: .rootContainer)
        }
    }

    /// Decides which endpoint the extension should try first: the LAN address
    /// when it answers, the public one otherwise.
    private func refreshPreferredEndpoint(_ account: Account) async {
        guard let endpoints = try? AccountStore.endpoints(forAccountID: account.id) else { return }
        if let lan = endpoints.first(where: { !$0.isWan }), await Endpoint.probe(lan) {
            EndpointStore.remember(.lan, forAccountID: account.id)
        } else {
            EndpointStore.remember(.wan, forAccountID: account.id)
        }
    }

    /// The network changed: re-decide the endpoint and have Files look again.
    private func networkChanged() async {
        for account in accounts {
            await refreshPreferredEndpoint(account)
            await clearErrors(account)
        }
    }

    /// iOS keeps a domain paused after an error like "not authenticated" until
    /// the app says it's resolved; say so, and have Files list everything again.
    private func clearErrors(_ account: Account) async {
        guard let manager = NSFileProviderManager(for: domain(for: account)) else { return }
        for code in [NSFileProviderError.Code.notAuthenticated, .serverUnreachable, .cannotSynchronize] {
            try? await manager.signalErrorResolved(NSFileProviderError(code))
        }
        try? await manager.signalEnumerator(for: .workingSet)
        try? await manager.signalEnumerator(for: .rootContainer)
    }

    /// Removes the account from Files and adds it back, dropping whatever iOS
    /// was stuck on (pending changes, errors, downloaded copies). The files on
    /// the server are untouched.
    func resetSync(_ account: Account) async {
        do {
            try await NSFileProviderManager.remove(domain(for: account))
        } catch {
            lastError = "F-04 重置同步失败"
            return
        }
        await register(account)
    }

    func delete(_ account: Account) async {
        accounts.removeAll { $0.id == account.id }
        AccountStore.save(accounts)
        Passwords.delete(for: account.id)
        Passwords.delete(for: AccountStore.cfSecretKey(account.id))
        EndpointStore.forget(account.id)
        do {
            try await NSFileProviderManager.remove(domain(for: account))
        } catch {
            lastError = "F-03 从文件 App 移除失败"
        }
    }

    /// Makes the registered domains match the accounts.
    func syncDomains() async {
        let registered = (try? await NSFileProviderManager.domains()) ?? []
        let ids = Set(accounts.map(\.id))
        for domain in registered where !ids.contains(domain.identifier.rawValue) {
            try? await NSFileProviderManager.remove(domain)
        }
        for account in accounts where !registered.contains(where: {
            $0.identifier.rawValue == account.id && $0.displayName == account.name
        }) {
            await register(account)
        }
        // Errors from before (e.g. a server that was down) shouldn't keep
        // syncing paused once the app is opened again.
        for account in accounts {
            await clearErrors(account)
        }
    }

    /// Opens the account's folder in the Files app.
    func openInFiles(_ account: Account) async {
        do {
            guard let manager = NSFileProviderManager(for: domain(for: account)) else { return }
            let url = try await manager.getUserVisibleURL(for: .rootContainer)
            var components = URLComponents()
            components.scheme = "shareddocuments"
            components.path = url.path(percentEncoded: false)
            if let filesURL = components.url { await UIApplication.shared.open(filesURL) }
        } catch {
            lastError = "O-01 打不开文件 App"
        }
    }

    private func register(_ account: Account) async {
        // Right after installing a new build the system may not have
        // activated the Files extension yet: add() answers with an
        // NSFileProviderError ("the app is currently unavailable"). That
        // clears on its own, so retry before reporting.
        for delay in [0.0, 2.0, 5.0, 10.0] {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            do {
                // Adding an existing identifier updates its display name.
                try await NSFileProviderManager.add(domain(for: account))
                ProviderDiagnostics.mark("A-OK 已注册 \(account.name)")
                return
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSFileProviderErrorDomain,
                   nsError.code == NSFileProviderError.Code.providerNotFound.rawValue {
                    // Happens when the extension isn't registered with iOS, e.g. when
                    // the app runs inside LiveContainer, which loads no extensions.
                    lastError = "G-02 文件扩展不可用：iOS 找不到 DAV Drive 的文件扩展。请按常规方式安装（SideStore、iLoader 等，不要用 LiveContainer），且签名配置要授予 App Group（见 G-01）。"
                    return
                }
                if nsError.domain != NSFileProviderErrorDomain {
                    lastError = "F-02 无法添加到文件 App"
                    return
                }
                // A FileProvider-domain error: extension not up yet, retry.
            }
        }
        lastError = "G-03 文件扩展还没就绪：等一分钟重开 App，或重启手机后再添加一次。"
    }

    private func domain(for account: Account) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(account.id), displayName: account.name)
    }
}
