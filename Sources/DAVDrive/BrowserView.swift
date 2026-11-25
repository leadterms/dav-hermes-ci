import DAVCore
import SwiftUI

/// Reads a server's folders inside the app itself, so the address, the
/// account and the password can be checked without the Files extension in
/// the way. It shows exactly what the extension would list.
struct BrowserView: View {
    let account: Account

    @Environment(\.dismiss) private var dismiss

    /// Paths from the account root down to the open folder, "" being the root.
    @State private var stack: [String] = [""]
    @State private var items: [DAVResource] = []
    @State private var error: String?
    @State private var loading = false

    private var current: String { stack.last ?? "" }
    private var title: String { current.split(separator: "/").last.map(String.init) ?? account.name }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("上一级", systemImage: "chevron.up") {
                            if stack.count > 1 { stack.removeLast() }
                            Task { await load() }
                        }
                        .disabled(stack.count <= 1)
                    }
                }
                .task { await load() }
        }
    }

    @ViewBuilder private var content: some View {
        if loading && items.isEmpty {
            ProgressView("Reading…")
        } else if let error, items.isEmpty {
            ContentUnavailableView {
                Label("这个文件夹读不出来", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
        } else if items.isEmpty {
            ContentUnavailableView("Empty Folder", systemImage: "folder")
        } else {
            List {
                if let error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                Section {
                    ForEach(sorted, id: \.path) { item in row(item) }
                } header: {
                    Text(current.isEmpty ? account.name : "/" + current)
                        .textCase(nil)
                }
            }
            .refreshable { await load() }
        }
    }

    private var sorted: [DAVResource] {
        items.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    @ViewBuilder private func row(_ item: DAVResource) -> some View {
        let label = HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder" : "doc")
                .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                if !item.isDirectory {
                    Text(detail(item)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if item.isDirectory {
            Button {
                stack.append(item.path)
                items = []
                Task { await load() }
            } label: {
                label
            }
            .foregroundStyle(.primary)
        } else {
            label
        }
    }

    private func detail(_ item: DAVResource) -> String {
        var parts: [String] = []
        if let size = item.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let modified = item.modified { parts.append(modified.formatted(date: .abbreviated, time: .shortened)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let client = try AccountStore.client(forAccountID: account.id)
            items = try await client.list(current)
            error = nil
        } catch {
            items = []
            self.error = error.localizedDescription
        }
    }
}
