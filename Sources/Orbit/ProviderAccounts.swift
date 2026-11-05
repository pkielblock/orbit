import AppKit
import SwiftUI

/// Add, rename or remove one provider's accounts. Provider tools own sign-in and credential storage;
/// Orbit never asks users to paste tokens, and removing an account never touches its folder or sign-in.
struct ProviderAccounts: View {
    private enum FolderChoice: Hashable { case new, existing }
    private static let addFormID = "addForm"

    @ObservedObject var model: GalaxyModel
    let provider: Provider
    let refresh: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied: UUID?
    @State private var newName = ""
    @State private var choice = FolderChoice.new
    @State private var chosenFolder: String?
    @State private var addError: String?
    @State private var newID = UUID()
    @State private var pickerRevision = 0

    private var accounts: [Account] { model.accounts(for: provider) }
    private var folder: String? { choice == .new ? AccountStore.newFolder(provider, id: newID) : chosenFolder }

    var body: some View {
        ScrollViewReader { scroller in
            VStack(spacing: 0) {
                // One instance, hugging its content up to the height limit. A ViewThatFits would hold two copies and rebuild
                // every row when a result or the form crosses the limit, losing typing and focus.
                ScrollView { content }
                // Outside the scroll view: Done stays reachable, and scrollers are hidden until scrolling.
                footer
            }
            .frame(maxHeight: 560)
            .onAppear {
                if let id = model.configuringAccount { scroller.scrollTo(id, anchor: .center) }
            }
            // Scrollers are hidden until scrolling, so a form opening below the fold would look like nothing happened.
            .task(id: model.addingAccount) {
                guard model.addingAccount else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scroller.scrollTo(Self.addFormID, anchor: .bottom) }
            }
        }
        .frame(width: 392)
        .background(Color(white: 0.04)) // T3 Black surface #0a0a0a
        .foregroundStyle(.white).buttonStyle(.plain).preferredColorScheme(.dark)
        .background {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(provider.name) accounts").font(.system(size: 18, weight: .medium))
                Text("Orbit reads quotas from accounts signed in through \(provider.toolName). Sign-in happens in Terminal; Orbit never sees passwords or tokens.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                ForEach(accounts) { account in
                    AccountRow(model: model, account: account, copied: $copied).id(account.id)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Button("Add account") { model.addingAccount.toggle() }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Galaxy.accentText)
                if model.addingAccount { addForm.id(Self.addFormID) }
            }
            Link("Installation and sign-in help", destination: provider.helpURL)
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding([.top, .horizontal], 24).padding(.bottom, 16)
    }

    private var footer: some View {
        HStack {
            Button(model.refreshing ? String(localized: "Checking…") : String(localized: "Check connections"), action: refresh)
                .disabled(model.refreshing).foregroundStyle(.secondary)
            Spacer()
            Button { dismiss() } label: {
                Text("Done").fontWeight(.medium).padding(.horizontal, 16).frame(height: 28)
                    .background(Galaxy.accent, in: Capsule())
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding([.bottom, .horizontal], 24)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Name").font(.system(size: 13))
                TextField("Name", text: $newName, prompt: Text(verbatim: ""))
                    .labelsHidden().textFieldStyle(.roundedBorder).font(.system(size: 13))
            }
            Picker(selection: Binding(get: { choice }, set: { $0 == .existing ? chooseExisting() : selectNewFolder() })) {
                Text("New folder").tag(FolderChoice.new)
                Text("Choose existing…").tag(FolderChoice.existing)
            } label: {
                Text("Folder").font(.system(size: 13))
            }
            .pickerStyle(.radioGroup).horizontalRadioGroupLayout().font(.system(size: 13))
            .id(pickerRevision)
            if let folder {
                Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(folder)
            }
            if let addError {
                Text(addError).font(.system(size: 11)).foregroundStyle(Galaxy.errorText)
            }
            HStack(spacing: 16) {
                Spacer()
                Button("Cancel") { resetForm() }.font(.system(size: 12)).foregroundStyle(.secondary)
                Button(action: add) {
                    Text("Add").font(.system(size: 13, weight: .medium)).padding(.horizontal, 16).frame(height: 28)
                        .background(Galaxy.accent, in: Capsule())
                }
                .disabled(AccountStore.trimmed(newName).isEmpty || folder == nil)
                .opacity(AccountStore.trimmed(newName).isEmpty || folder == nil ? 0.4 : 1)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Galaxy.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func selectNewFolder() {
        choice = .new
        chosenFolder = nil
        addError = nil
    }

    // Its own dialog, not a sheet: a sheet hangs off this narrow window, and beside the menu bar icon it runs off the screen.
    private func chooseExisting() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true // config folders such as ~/.claude-work are hidden
        panel.directoryURL = URL(fileURLWithPath: Account.home)
        NSApp.activate(ignoringOtherApps: true)
        // The popover and this sheet float above the dialog, whose own level can't be raised, so they step down while it's open.
        let floating = NSApp.windows.filter { $0.isVisible && $0.level > .modalPanel && !$0.className.contains("StatusBar") }
        let levels = floating.map(\.level)
        floating.forEach { $0.level = .normal }
        let response = panel.runModal()
        zip(floating, levels).forEach { $0.level = $1 }
        pickerRevision += 1 // the native radio keeps the clicked option otherwise, even when the panel is cancelled
        guard response == .OK, let path = panel.url?.path else { return }
        if AccountStore.folderUsed(path, provider: provider, in: model.accounts) {
            addError = String(localized: "Folder already used")
        } else {
            addError = nil
            chosenFolder = path
            choice = .existing
        }
    }

    private func add() {
        guard let folder else { return }
        let name = AccountStore.trimmed(newName)
        if AccountStore.nameUsed(name, provider: provider, in: model.accounts) {
            addError = String(localized: "Name already used")
        } else if AccountStore.folderUsed(folder, provider: provider, in: model.accounts) {
            addError = String(localized: "Folder already used")
        } else {
            do {
                if choice == .new {
                    try AccountStore.createFolder(folder)
                    // A folder made just now can't be signed in yet; the refresh confirms it.
                    model.usage[newID] = ProviderUsage(provider: provider, needsConnection: true)
                }
                model.addAccount(Account(id: newID, provider: provider, name: name, folder: folder))
                resetForm()
            } catch {
                addError = String(localized: "Could not create the folder")
            }
        }
    }

    private func resetForm() {
        model.addingAccount = false
        newName = ""
        newID = UUID()
        selectNewFolder()
    }
}

private struct AccountRow: View {
    @ObservedObject var model: GalaxyModel
    let account: Account
    @Binding var copied: UUID?
    @State private var draft: String
    /// Typed but not committed. Only this may rename: a row rebuilt while the sheet changes layout holds an old draft.
    @State private var edited = false
    @State private var nameError: String?
    @State private var confirmingRemove = false
    @FocusState private var editing: Bool

    init(model: GalaxyModel, account: Account, copied: Binding<UUID?>) {
        self.model = model
        self.account = account
        _copied = copied
        _draft = State(initialValue: account.name)
    }

    private var usage: ProviderUsage? { model.usage[account.id] }
    private var connected: Bool { usage != nil && usage?.needsConnection == false && usage?.error == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    TextField("Account name", text: Binding(get: { draft }, set: { draft = $0; edited = true; nameError = nil }), prompt: Text(verbatim: ""))
                        .labelsHidden().textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                        .focused($editing).onSubmit(commit)
                        .accessibilityLabel("Account name")
                    Text(Galaxy.status(usage)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                }
                if let nameError {
                    Text(nameError).font(.system(size: 11)).foregroundStyle(Galaxy.errorText)
                }
                let folder = account.resolvedFolder()
                Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(folder)
            }
            if !connected {
                let command = account.signInCommand()
                Text(verbatim: command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !connected || account.folder != nil {
                HStack {
                    if !connected {
                        Button(copied == account.id ? String(localized: "Copied, paste it in Terminal") : String(localized: "Copy command and open Terminal"), action: copyCommand)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Galaxy.accentText)
                            .accessibilityLabel("Copy sign-in command for \(account.name) and open Terminal")
                    }
                    Spacer()
                    if account.folder != nil {
                        Button("Remove") { confirmingRemove = true }
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .accessibilityLabel("Remove \(account.name) from Orbit")
                    }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Galaxy.card, in: RoundedRectangle(cornerRadius: 12))
        .task(id: account.name) { if !edited { draft = account.name } }
        // task(id:), not onChange: this runs on macOS 13 without the deprecated form. Commit on focus loss.
        .task(id: editing) { if !editing { commit() } }
        .onDisappear(perform: commit)
        .confirmationDialog("Remove \(account.name) from Orbit?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { model.removeAccount(account.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Orbit stops reading this account. Its folder and sign-in stay on your Mac.")
        }
    }

    /// An empty name reverts; a duplicate stays in the field with its error until it changes.
    private func commit() {
        guard edited else { return }
        let name = AccountStore.trimmed(draft)
        if !name.isEmpty, AccountStore.nameUsed(name, provider: account.provider, in: model.accounts, except: account.id) {
            nameError = String(localized: "Name already used")
            return
        }
        edited = false
        if name.isEmpty { draft = account.name } else if name != account.name { model.renameAccount(account.id, to: name) }
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(account.signInCommand(), forType: .string)
        copied = account.id
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
