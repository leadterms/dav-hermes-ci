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
                    TextField("Add folder name", text: $newDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(addDirectory)
                    Button("Add", action: addDirectory)
                        .disabled(newDirectory.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Folders Never Shown")
            } footer: {
                Text("Matched by exact name at any depth. Hiding large build trees keeps Files fast and the extension within its memory limit.")
            }

            Section {
                ForEach(files, id: \.self) { name in
                    Text(name)
                }
                .onDelete { files.remove(atOffsets: $0) }
                HStack {
                    TextField("Add file name", text: $newFile)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(addFile)
                    Button("Add", action: addFile)
                        .disabled(newFile.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Files Never Shown")
            }

            Section {
                Button("Restore Defaults") {
                    directories = IgnoreRules.standard.directories.sorted()
                    files = IgnoreRules.standard.files.sorted()
                    save()
                }
            } footer: {
                Text("Deleted or newly added pieces (including the trash folder) are not protected — removing .davtrash makes the trash visible in the normal tree.")
            }
        }
        .navigationTitle("Ignore Rules")
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
