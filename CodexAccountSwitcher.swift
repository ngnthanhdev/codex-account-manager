import AppKit
import Combine
import Foundation
import SwiftUI

private let currentSelection = "__current_codex_auth__"

private func debugLog(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Logs")
        .appendingPathComponent("CodexAccountSwitcher.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

struct CommandResult {
    let status: Int32
    let output: String
}

struct AuthMetadata {
    let profileName: String
    let authURL: URL
    let exists: Bool
    let authMode: String
    let accountID: String
    let email: String
    let lastRefresh: String
    let capturedAt: String
    let hasAPIKey: Bool
    let tokens: [String: String]

    var tokenLengths: [String: Int] {
        tokens.mapValues { $0.count }
    }
}

struct ProfileRow: Identifiable {
    let id: String
    let name: String
    let isCurrentAuth: Bool
    let isActive: Bool
    let subtitle: String
}

final class AccountStore: ObservableObject {
    @Published var rows: [ProfileRow] = []
    @Published var selectedID: String = currentSelection
    @Published var activeProfile: String = ""
    @Published var selectedMetadata: AuthMetadata = AccountStore.emptyMetadata()
    @Published var newProfileName: String = ""
    @Published var selectedTokenKey: String = "access_token"
    @Published var revealToken: Bool = false
    @Published var isWorking: Bool = false
    @Published var message: String = "Ready"

    let switcherHome: URL
    private let scriptPath: String
    private var autoSaveTimer: Timer?
    private var isAutoSaving = false
    private var lastAutoSaveFingerprint = ""

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switcherHome = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("CodexAccountSwitcher")

        if let bundled = Bundle.main.path(forResource: "codex-account-switcher", ofType: "sh") {
            scriptPath = bundled
        } else {
            scriptPath = FileManager.default.currentDirectoryPath + "/codex-account-switcher.sh"
        }

        reload()
        startAutoSaveTimer()
    }

    deinit {
        autoSaveTimer?.invalidate()
    }

    static func emptyMetadata() -> AuthMetadata {
        AuthMetadata(
            profileName: "Current Codex",
            authURL: currentAuthURL(),
            exists: false,
            authMode: "-",
            accountID: "-",
            email: "-",
            lastRefresh: "-",
            capturedAt: "-",
            hasAPIKey: false,
            tokens: [:]
        )
    }

    static func currentAuthURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("auth.json")
    }

    func reload() {
        activeProfile = run(["active"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileNames = run(["list", "--plain"]).output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var nextRows: [ProfileRow] = [
            ProfileRow(
                id: currentSelection,
                name: "Current Codex",
                isCurrentAuth: true,
                isActive: false,
                subtitle: authSummary(for: Self.currentAuthURL())
            )
        ]

        for name in profileNames {
            let metadata = metadata(forProfile: name)
            let label = metadata.email != "-" ? metadata.email : shortAccount(metadata.accountID)
            nextRows.append(
                ProfileRow(
                    id: name,
                    name: name,
                    isCurrentAuth: false,
                    isActive: name == activeProfile,
                    subtitle: name == activeProfile ? "Active - \(label)" : label
                )
            )
        }

        rows = nextRows
        if !rows.contains(where: { $0.id == selectedID }) {
            selectedID = rows.first?.id ?? currentSelection
        }
        loadSelected()
    }

    func loadSelected() {
        if selectedID == currentSelection {
            selectedMetadata = metadataForCurrentAuth()
        } else {
            selectedMetadata = metadata(forProfile: selectedID)
        }
        if selectedMetadata.tokens[selectedTokenKey] == nil {
            selectedTokenKey = selectedMetadata.tokens.keys.sorted().first ?? "access_token"
        }
    }

    func captureCurrent() {
        let trimmed = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "Nhap ten profile truoc khi capture."
            return
        }
        guard isValidProfileName(trimmed) else {
            message = "Profile chi duoc dung chu, so, dot, dash, underscore."
            return
        }
        perform(["capture", trimmed], successMessage: "Captured \(trimmed)") {
            self.selectedID = trimmed
            self.newProfileName = ""
        }
    }

    func switchSelected() {
        guard selectedID != currentSelection else {
            message = "Chon mot saved profile de switch."
            return
        }
        guard selectedID != activeProfile else {
            message = "\(selectedID) dang la active profile."
            return
        }
        perform(["switch", selectedID], successMessage: "Switched to \(selectedID)")
    }

    func saveActiveProfile() {
        guard !activeProfile.isEmpty else {
            message = "Chua co active profile. Capture current truoc."
            return
        }
        perform(["capture", activeProfile], successMessage: "Saved \(activeProfile)")
    }

    func saveActiveAuthNow() {
        guard !activeProfile.isEmpty else {
            message = "Chua co active profile. Capture current truoc."
            return
        }
        perform(["save-auth", activeProfile], successMessage: "Saved fresh token into \(activeProfile)")
    }

    func deleteSelected() {
        guard selectedID != currentSelection else {
            message = "Khong the delete Current Codex."
            return
        }
        guard selectedID != activeProfile else {
            message = "Khong the delete active profile. Switch sang profile khac truoc."
            return
        }
        let deleting = selectedID
        perform(["delete", deleting], successMessage: "Deleted \(deleting)") {
            self.selectedID = currentSelection
        }
    }

    func openProfilesFolder() {
        _ = run(["open-folder"])
    }

    func openCodex() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Codex"]
        try? task.run()
    }

    func copySelectedToken() {
        guard let token = selectedMetadata.tokens[selectedTokenKey], !token.isEmpty else {
            message = "Khong co token nay trong auth.json."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        message = "Copied \(friendlyTokenName(selectedTokenKey)) token to clipboard."
    }

    func tokenDisplay() -> String {
        guard let token = selectedMetadata.tokens[selectedTokenKey], !token.isEmpty else {
            return "No token found."
        }
        if revealToken {
            return token
        }
        let visiblePrefix = String(token.prefix(8))
        let visibleSuffix = String(token.suffix(6))
        return "\(visiblePrefix)...\(visibleSuffix)  (\(token.count) chars, hidden)"
    }

    func friendlyTokenName(_ key: String) -> String {
        switch key {
        case "access_token": return "Access"
        case "refresh_token": return "Refresh"
        case "id_token": return "ID"
        default: return key
        }
    }

    private func perform(_ args: [String], successMessage: String, afterSuccess: (() -> Void)? = nil) {
        isWorking = true
        message = "Working..."
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.run(args)
            DispatchQueue.main.async {
                self.isWorking = false
                if result.status == 0 {
                    afterSuccess?()
                    self.message = successMessage
                    self.reload()
                } else {
                    self.message = result.output.isEmpty ? "Command failed." : result.output
                }
            }
        }
    }

    private func startAutoSaveTimer() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            self?.autoSaveActiveAuthIfNeeded()
        }
        autoSaveActiveAuthIfNeeded()
    }

    private func autoSaveActiveAuthIfNeeded() {
        guard !isWorking, !isAutoSaving, !activeProfile.isEmpty else { return }

        let profile = activeProfile
        let currentURL = Self.currentAuthURL()
        let savedURL = profileAuthURL(profile)
        guard let currentData = try? Data(contentsOf: currentURL),
              !currentData.isEmpty,
              authLooksUsable(currentData) else {
            return
        }

        let savedData = try? Data(contentsOf: savedURL)
        guard savedData != currentData else { return }

        let fingerprint = "\(profile):\(currentData.count):\(currentData.hashValue)"
        guard fingerprint != lastAutoSaveFingerprint else { return }

        isAutoSaving = true
        DispatchQueue.global(qos: .utility).async {
            let result = self.run(["save-auth", profile])
            DispatchQueue.main.async {
                self.isAutoSaving = false
                self.lastAutoSaveFingerprint = fingerprint
                if result.status == 0 {
                    self.message = "Auto-saved fresh token into \(profile)."
                    self.reload()
                } else {
                    debugLog("auto save auth failed: \(result.output)")
                }
            }
        }
    }

    private func authLooksUsable(_ data: Data) -> Bool {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let apiKey = raw["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return true
        }
        guard let tokens = raw["tokens"] as? [String: Any] else {
            return false
        }
        let hasAccess = (tokens["access_token"] as? String)?.isEmpty == false
        let hasRefresh = (tokens["refresh_token"] as? String)?.isEmpty == false
        return hasAccess || hasRefresh
    }

    private func run(_ arguments: [String]) -> CommandResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: scriptPath)
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return CommandResult(status: task.terminationStatus, output: output)
        } catch {
            return CommandResult(status: 127, output: error.localizedDescription)
        }
    }

    private func metadataForCurrentAuth() -> AuthMetadata {
        readAuthMetadata(
            name: "Current Codex",
            authURL: Self.currentAuthURL(),
            capturedAt: "-"
        )
    }

    private func metadata(forProfile name: String) -> AuthMetadata {
        readAuthMetadata(
            name: name,
            authURL: profileAuthURL(name),
            capturedAt: profileCapturedAt(name)
        )
    }

    private func readAuthMetadata(name: String, authURL: URL, capturedAt: String) -> AuthMetadata {
        guard let data = try? Data(contentsOf: authURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AuthMetadata(
                profileName: name,
                authURL: authURL,
                exists: false,
                authMode: "-",
                accountID: "-",
                email: "-",
                lastRefresh: "-",
                capturedAt: capturedAt,
                hasAPIKey: false,
                tokens: [:]
            )
        }

        let tokenMap = raw["tokens"] as? [String: Any] ?? [:]
        var tokens: [String: String] = [:]
        for key in ["access_token", "refresh_token", "id_token"] {
            if let value = tokenMap[key] as? String, !value.isEmpty {
                tokens[key] = value
            }
        }

        let idTokenClaims = decodeJWTClaims(tokens["id_token"])
        let accessClaims = decodeJWTClaims(tokens["access_token"])
        let email = firstString([
            idTokenClaims["email"],
            accessClaims["email"],
            accessClaims["https://api.openai.com/profile/email"]
        ])
        let accountID = firstString([
            tokenMap["account_id"],
            idTokenClaims["https://api.openai.com/auth"],
            idTokenClaims["sub"],
            accessClaims["sub"]
        ])

        return AuthMetadata(
            profileName: name,
            authURL: authURL,
            exists: true,
            authMode: stringValue(raw["auth_mode"], fallback: "-"),
            accountID: accountID.isEmpty ? "-" : accountID,
            email: email.isEmpty ? "-" : email,
            lastRefresh: stringValue(raw["last_refresh"], fallback: "-"),
            capturedAt: capturedAt,
            hasAPIKey: (raw["OPENAI_API_KEY"] as? String)?.isEmpty == false,
            tokens: tokens
        )
    }

    private func decodeJWTClaims(_ jwt: String?) -> [String: Any] {
        guard let jwt else { return [:] }
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return raw
    }

    private func firstString(_ values: [Any?]) -> String {
        for value in values {
            if let string = value as? String, !string.isEmpty {
                return string
            }
            if let dict = value as? [String: Any] {
                if let accountID = dict["account_id"] as? String, !accountID.isEmpty {
                    return accountID
                }
                if let userID = dict["user_id"] as? String, !userID.isEmpty {
                    return userID
                }
            }
        }
        return ""
    }

    private func stringValue(_ value: Any?, fallback: String) -> String {
        guard let value else { return fallback }
        if let string = value as? String, !string.isEmpty {
            return string
        }
        return "\(value)"
    }

    private func profileAuthURL(_ name: String) -> URL {
        switcherHome
            .appendingPathComponent("profiles")
            .appendingPathComponent(name)
            .appendingPathComponent("auth")
            .appendingPathComponent("auth.json")
    }

    private func profileCapturedAt(_ name: String) -> String {
        let envURL = switcherHome
            .appendingPathComponent("profiles")
            .appendingPathComponent(name)
            .appendingPathComponent("profile.env")
        guard let text = try? String(contentsOf: envURL, encoding: .utf8) else {
            return "-"
        }
        for line in text.split(separator: "\n") {
            if line.hasPrefix("captured_at=") {
                return String(line.dropFirst("captured_at=".count))
            }
        }
        return "-"
    }

    private func authSummary(for url: URL) -> String {
        let metadata = readAuthMetadata(name: "Current Codex", authURL: url, capturedAt: "-")
        if metadata.email != "-" {
            return metadata.email
        }
        return shortAccount(metadata.accountID)
    }

    private func shortAccount(_ value: String) -> String {
        guard value != "-", value.count > 12 else { return value }
        return "\(value.prefix(8))...\(value.suffix(4))"
    }

    private func isValidProfileName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }
}

struct ManagerView: View {
    @ObservedObject var store: AccountStore

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.6)
            detail
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 980, minHeight: 660)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.badge.key.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Manager")
                        .font(.system(size: 20, weight: .semibold))
                    Text("\(profileCount) saved profiles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.rows) { row in
                        ProfileCardButton(
                            row: row,
                            isSelected: store.selectedID == row.id
                        ) {
                            store.selectedID = row.id
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .onReceive(store.$selectedID.dropFirst()) { _ in
                store.revealToken = false
                store.loadSelected()
            }

            capturePanel
            statusPanel
            utilityButtons
        }
        .padding(18)
        .frame(width: 320)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.46))
    }

    private var capturePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Capture current login", systemImage: "plus.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            HStack {
                TextField("profile name", text: $store.newProfileName)
                    .textFieldStyle(.roundedBorder)
                Button {
                    store.captureCurrent()
                } label: {
                    Label("Capture", systemImage: "tray.and.arrow.down.fill")
                }
                .disabled(store.isWorking)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusPanel: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: messageIcon)
                .foregroundStyle(messageColor)
                .frame(width: 18)
            Text(store.message)
                .font(.caption)
                .foregroundStyle(messageColor)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(messageColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var utilityButtons: some View {
        VStack(spacing: 8) {
            Button {
                store.openCodex()
            } label: {
                Label("Open Codex", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                store.openProfilesFolder()
            } label: {
                Label("Profiles Folder", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.bordered)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerPanel
                actionPanel
                metadataPanel
                tokenVault
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var headerPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: selectedIcon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(selectedIconColor)
                    .frame(width: 54, height: 54)
                    .background(selectedIconColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(store.selectedMetadata.profileName)
                            .font(.system(size: 28, weight: .semibold))
                            .lineLimit(1)
                        if store.selectedID == store.activeProfile {
                            StatusPill(text: "Active", color: .green, systemImage: "checkmark.circle.fill")
                        }
                        if store.selectedID == currentSelection {
                            StatusPill(text: "Live auth", color: .blue, systemImage: "bolt.fill")
                        }
                    }

                    Text(selectedSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button {
                    store.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isWorking)
            }

            HStack(spacing: 10) {
                SummaryTile(title: "Auth file", value: store.selectedMetadata.exists ? "Found" : "Missing", systemImage: "doc.text.magnifyingglass", color: store.selectedMetadata.exists ? .green : .red)
                SummaryTile(title: "Tokens", value: "\(store.selectedMetadata.tokens.count)", systemImage: "key.horizontal.fill", color: .orange)
                SummaryTile(title: "API key", value: store.selectedMetadata.hasAPIKey ? "Present" : "None", systemImage: "terminal.fill", color: store.selectedMetadata.hasAPIKey ? .purple : .secondary)
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account Actions")
                .font(.headline)

            HStack(spacing: 10) {
                Button {
                    store.switchSelected()
                } label: {
                    ActionButtonLabel(
                        title: "Switch",
                        subtitle: "Restore selected profile",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(store.isWorking || store.selectedID == currentSelection || store.selectedID == store.activeProfile)

                Button {
                    store.saveActiveProfile()
                } label: {
                    ActionButtonLabel(
                        title: "Save Active",
                        subtitle: "Update full app state",
                        systemImage: "externaldrive.fill.badge.checkmark"
                    )
                }
                .buttonStyle(SecondaryActionButtonStyle(color: .green))
                .disabled(store.isWorking || store.activeProfile.isEmpty)

                Button {
                    store.saveActiveAuthNow()
                } label: {
                    ActionButtonLabel(
                        title: "Save Token",
                        subtitle: "Store fresh auth only",
                        systemImage: "key.fill"
                    )
                }
                .buttonStyle(SecondaryActionButtonStyle(color: .orange))
                .disabled(store.isWorking || store.activeProfile.isEmpty)

                Button {
                    confirmDelete()
                } label: {
                    ActionButtonLabel(
                        title: "Delete",
                        subtitle: "Remove saved profile",
                        systemImage: "trash.fill"
                    )
                }
                .buttonStyle(SecondaryActionButtonStyle(color: .red))
                .disabled(store.isWorking || store.selectedID == currentSelection || store.selectedID == store.activeProfile)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var metadataPanel: some View {
        SectionPanel(title: "Profile Details", systemImage: "list.bullet.rectangle") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                metadataRow("Auth mode", store.selectedMetadata.authMode)
                metadataRow("Email", store.selectedMetadata.email)
                metadataRow("Account ID", store.selectedMetadata.accountID)
                metadataRow("Last refresh", store.selectedMetadata.lastRefresh)
                metadataRow("Captured at", store.selectedMetadata.capturedAt)
                metadataRow("Auth path", store.selectedMetadata.authURL.path)
            }
        }
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var tokenVault: some View {
        SectionPanel(title: "Token Vault", systemImage: "lock.shield.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Picker("Token", selection: $store.selectedTokenKey) {
                        ForEach(store.selectedMetadata.tokens.keys.sorted(), id: \.self) { key in
                            let length = store.selectedMetadata.tokenLengths[key] ?? 0
                            Text("\(store.friendlyTokenName(key)) (\(length))").tag(key)
                        }
                    }
                    .frame(width: 210)

                    Toggle("Reveal token", isOn: $store.revealToken)
                        .toggleStyle(.checkbox)

                    Spacer()

                    Button {
                        store.copySelectedToken()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(store.selectedMetadata.tokens[store.selectedTokenKey] == nil)
                }

                ScrollView {
                    Text(store.tokenDisplay())
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 132)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text("Tokens stay local and are hidden by default. They are never printed to terminal, logs, or network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var profileCount: Int {
        store.rows.filter { !$0.isCurrentAuth }.count
    }

    private var selectedSubtitle: String {
        if store.selectedMetadata.email != "-" {
            return store.selectedMetadata.email
        }
        if store.selectedMetadata.accountID != "-" {
            return store.selectedMetadata.accountID
        }
        return store.selectedMetadata.authURL.path
    }

    private var selectedIcon: String {
        store.selectedID == currentSelection ? "bolt.circle.fill" : "person.crop.circle.fill"
    }

    private var selectedIconColor: Color {
        store.selectedID == currentSelection ? .blue : .indigo
    }

    private var messageColor: Color {
        let lower = store.message.lowercased()
        if lower.contains("failed") || lower.contains("error") || lower.contains("khong") || lower.contains("cannot") {
            return .red
        }
        if lower.contains("saved") || lower.contains("captured") || lower.contains("switched") || lower.contains("copied") {
            return .green
        }
        return .secondary
    }

    private var messageIcon: String {
        messageColor == .red ? "exclamationmark.triangle.fill" : "info.circle.fill"
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete profile \(store.selectedID)?"
        alert.informativeText = "This removes the saved auth and Codex Desktop state for this profile from the switcher store."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.deleteSelected()
        }
    }
}

private struct ProfileCardButton: View {
    let row: ProfileRow
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: row.isCurrentAuth ? "bolt.circle.fill" : "person.crop.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 30, height: 30)
                    .background(iconColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if row.isActive {
                            StatusPill(text: "Active", color: .green, systemImage: "checkmark.circle.fill")
                        }
                    }
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.65) : Color(nsColor: .separatorColor).opacity(0.35), lineWidth: isSelected ? 1.3 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var iconColor: Color {
        row.isCurrentAuth ? .blue : (row.isActive ? .green : .indigo)
    }

    private var cardBackground: Color {
        isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor)
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10, weight: .bold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.13))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SectionPanel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ActionButtonLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(12)
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SecondaryActionButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color)
            .background(color.opacity(configuration.isPressed ? 0.18 : 0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color.opacity(0.26), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = AccountStore()
    private var statusItem: NSStatusItem?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.regular)
        setupStatusItem()
        rebuildMenu()
        setupMainMenu()
        DispatchQueue.main.async {
            self.showManager()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        debugLog("applicationShouldHandleReopen visible=\(flag)")
        showManager()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        debugLog("applicationDidBecomeActive visible=\(window?.isVisible == true)")
        if window == nil || window?.isVisible == false {
            showManager()
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = Bundle.main.image(forResource: "StatusIcon") {
                image.size = NSSize(width: 16, height: 16)
                image.isTemplate = true
                button.image = image
            }
            button.title = " Codex"
        }
        statusItem = item
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Open Manager", action: #selector(openManager), keyEquivalent: "o"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Codex Account Switcher", action: #selector(quit), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Show Manager", action: #selector(openManager), keyEquivalent: "m"))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func rebuildMenu() {
        store.reload()
        let menu = NSMenu()

        let active = store.activeProfile.isEmpty ? "No active profile" : "Active: \(store.activeProfile)"
        let activeItem = NSMenuItem(title: active, action: nil, keyEquivalent: "")
        activeItem.isEnabled = false
        menu.addItem(activeItem)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Open Manager", action: #selector(openManager), keyEquivalent: "m"))
        menu.addItem(NSMenuItem(title: "Capture Current...", action: #selector(openManager), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        for row in store.rows where !row.isCurrentAuth {
            let title = row.isActive ? "\(row.name)  (active)" : row.name
            let item = NSMenuItem(title: title, action: #selector(menuSwitchProfile(_:)), keyEquivalent: "")
            item.representedObject = row.id
            item.target = self
            item.isEnabled = !row.isActive
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(menuRefresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open Profiles Folder", action: #selector(menuOpenFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.toolTip = active
    }

    @objc private func openManager() {
        showManager()
    }

    private func showManager() {
        debugLog("showManager start windowExists=\(window != nil)")
        if window == nil {
            let controller = NSHostingController(rootView: ManagerView(store: store))
            let newWindow = NSWindow(contentViewController: controller)
            newWindow.title = "Codex Account Manager"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.isReleasedWhenClosed = false
            newWindow.collectionBehavior = [.moveToActiveSpace]
            newWindow.level = .floating
            newWindow.minSize = NSSize(width: 980, height: 660)
            let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 80, y: 80, width: 1200, height: 800)
            let frame = NSRect(
                x: visibleFrame.midX - 540,
                y: visibleFrame.midY - 360,
                width: 1080,
                height: 720
            )
            newWindow.setFrame(frame, display: true)
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
        window?.makeMain()
        window?.makeKey()
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.window?.level = .normal
        }
        debugLog("showManager end visible=\(window?.isVisible == true) frame=\(String(describing: window?.frame))")
    }

    @objc private func menuSwitchProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? String else { return }
        store.selectedID = profile
        store.loadSelected()
        store.switchSelected()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.rebuildMenu()
        }
    }

    @objc private func menuRefresh() {
        rebuildMenu()
    }

    @objc private func menuOpenFolder() {
        store.openProfilesFolder()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
