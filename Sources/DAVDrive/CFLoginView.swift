import SwiftUI
import WebKit

/// Logs into the Cloudflare Access protection of the public address inside
/// the app: the embedded web view runs the e-mail OTP / challenge flow, and
/// when the session exists its cookies are pulled back and stored durably,
/// so every later public request carries them.
struct CFLoginView: View {
    let host: String
    let url: URL
    var onLoggedIn: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cookieCount: Int? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                CFLoginWebView(url: url, host: host, onCookies: { cookies in
                    if !cookies.isEmpty {
                        cookieCount = cookies.count
                        onLoggedIn(cookies)
                    }
                })
                HStack(spacing: 12) {
                    Text(cookieCount.map { "已取回 \($0) 个登录 Cookie，正在用它们访问。" }
                          ?? "完成邮箱验证码后，登录状态会自动取回。")
                        .font(.footnote)
                        .foregroundStyle(cookieCount != nil ? Color.green : Color.secondary)
                        .lineLimit(2)
                    if cookieCount != nil {
                        Button("完成") { dismiss() }
                    }
                    Spacer()
                }
                .padding([.horizontal, .bottom])
            }
            .navigationTitle("公网登录")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }
}

/// The web view itself. After every load it asks the cookie store for the
/// cookies that belong to the public host and hands them up; the login is
/// done once a non-empty set arrives (the Cloudflare session cookie).
struct CFLoginWebView: UIViewRepresentable {
    let url: URL
    let host: String
    var onCookies: ([String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: CFLoginWebView

        init(_ parent: CFLoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pullCookies(from: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            pullCookies(from: webView)
        }

        private func pullCookies(from webView: WKWebView) {
            let host = self.parent.host
            Task { @MainActor in
                let store = webView.configuration.websiteDataStore.httpCookieStore
                let all: [HTTPCookie] = await withCheckedContinuation { continuation in
                    store.getAllCookies { continuation.resume(returning: $0) }
                }
                let normalized = host.lowercased()
                let values = all
                    .filter { cookie in
                        let domain = cookie.domain.lowercased()
                            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        return domain == normalized || normalized.hasSuffix("." + domain)
                    }
                    .map { "\($0.name)=\($0.value)" }
                guard !values.isEmpty else { return }
                self.parent.onCookies(values)
            }
        }
    }
}
