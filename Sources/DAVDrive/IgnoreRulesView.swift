import DAVCore
import SwiftUI

/// Edits the names that never appear in Files: build trees like node_modules
/// and .git. This is only a display filter — nothing on the server changes and
/// nothing about the server is stored locally.
struct IgnoreRulesView: View {
    @State private var directories: [String] = IgnoreRules.load().directories.sorted()
    @State private var files: [String] = IgnoreRules.load().files.sorted()
    @State private var newDirectory = ""
    @State private var newFile = ""

    var body: some View {
        Form {
            Section {
                ForEach(directories, id: \.self) { name in
                    Text(name)
                }
                .onDelete { directories.remove(atOffsets: $0) }
                HStack {
                    TextField("添加文件夹名", text: $newDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(addDirectory)
                    Button("添加", action: addDirectory)
                        .disabled(newDirectory.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("不显示的文件夹")
            } footer: {
                Text("按名称精确匹配，任意层级都生效。隐藏大的编译目录能让文件 App 更快，也让扩展不超内存。")
            }

            Section {
                ForEach(files, id: \.self) { name in
                    Text(name)
                }
                .onDelete { files.remove(atOffsets: $0) }
                HStack {
                    TextField("添加文件名", text: $newFile)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(addFile)
                    Button("添加", action: addFile)
                        .disabled(newFile.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("不显示的文件")
            }

            Section {
                Button("恢复默认") {
                    directories = IgnoreRules.standard.directories.sorted()
                    files = IgnoreRules.standard.files.sorted()
                    save()
                }
            } footer: {
                Text("删除的或新增的目录（包括回收站目录）不受保护——去掉 .davtrash 后，回收站会出现在正常目录树里。")
            }
        }
        .navigationTitle("忽略规则")
        .onChange(of: directories) { _, _ in save() }
        .onChange(of: files) { _, _ in save() }
    }

    private func addDirectory() {
        let name = newDirectory.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !directories.contains(name) else { return }
        directories.append(name)
        directories.sort()
        newDirectory = ""
        save()
    }

    private func addFile() {
        let name = newFile.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !files.contains(name) else { return }
        files.append(name)
        files.sort()
        newFile = ""
        save()
    }

    private func save() {
        IgnoreRules.saveDirectories(directories)
        IgnoreRules.saveFiles(files)
    }
}
