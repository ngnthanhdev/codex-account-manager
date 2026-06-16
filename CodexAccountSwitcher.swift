import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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

enum ProfileHealthLevel: String {
    case healthy
    case warning
    case error
    case unknown
}

struct ProfileHealth {
    let level: ProfileHealthLevel
    let title: String
    let detail: String
    let systemImage: String
}

struct TokenStatus {
    let key: String
    let label: String
    let state: String
    let detail: String
}

struct AuthMetadata {
    let profileName: String
    let alias: String
    let authURL: URL
    let exists: Bool
    let authMode: String
    let accountID: String
    let email: String
    let planType: String
    let workspaceID: String
    let workspaceLabel: String
    let seatType: String
    let lastRefresh: String
    let capturedAt: String
    let desktopState: String
    let hasAPIKey: Bool
    let tokens: [String: String]
    let tokenStatuses: [String: TokenStatus]
    let health: ProfileHealth

    var tokenLengths: [String: Int] {
        tokens.mapValues { $0.count }
    }

    var displayName: String {
        alias.isEmpty ? profileName : alias
    }
}

struct ProfileRow: Identifiable {
    let id: String
    let name: String
    let displayName: String
    let isCurrentAuth: Bool
    let isActive: Bool
    let subtitle: String
    let meta: String
    let health: ProfileHealth
}

final class AccountStore: ObservableObject {
    @Published var rows: [ProfileRow] = []
    @Published var selectedID: String = currentSelection
    @Published var activeProfile: String = ""
    @Published var selectedMetadata: AuthMetadata = AccountStore.emptyMetadata()
    @Published var newProfileName: String = ""
    @Published var selectedTokenKey: String = "access_token"
    @Published var revealToken: Bool = false
    @Published var privacyMode: Bool
    @Published var aliasDraft: String = ""
    @Published var isEditingAlias: Bool = false
    @Published var profileNameDraft: String = ""
    @Published var isEditingProfileName: Bool = false
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
        privacyMode = UserDefaults.standard.bool(forKey: "CodexAccountSwitcherPrivacyMode")

        reload()
        startAutoSaveTimer()
    }

    deinit {
        autoSaveTimer?.invalidate()
    }

    static func emptyMetadata() -> AuthMetadata {
        AuthMetadata(
            profileName: "Current Codex",
            alias: "",
            authURL: currentAuthURL(),
            exists: false,
            authMode: "-",
            accountID: "-",
            email: "-",
            planType: "-",
            workspaceID: "-",
            workspaceLabel: "-",
            seatType: "-",
            lastRefresh: "-",
            capturedAt: "-",
            desktopState: "-",
            hasAPIKey: false,
            tokens: [:],
            tokenStatuses: [:],
            health: ProfileHealth(level: .unknown, title: "Unknown", detail: "No auth metadata loaded.", systemImage: "questionmark.circle.fill")
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
                displayName: "Current Codex",
                isCurrentAuth: true,
                isActive: false,
                subtitle: authSummary(for: Self.currentAuthURL()),
                meta: "Live auth file",
                health: metadataForCurrentAuth().health
            )
        ]

        for name in profileNames {
            let metadata = metadata(forProfile: name)
            let label = metadata.email != "-" ? metadata.email : shortAccount(metadata.accountID)
            let meta = profileContextLine(metadata)
            nextRows.append(
                ProfileRow(
                    id: name,
                    name: name,
                    displayName: metadata.displayName,
                    isCurrentAuth: false,
                    isActive: name == activeProfile,
                    subtitle: label,
                    meta: meta,
                    health: metadata.health
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
        aliasDraft = selectedMetadata.alias
        isEditingAlias = false
        profileNameDraft = selectedID == currentSelection ? "" : selectedID
        isEditingProfileName = false
    }

    func togglePrivacyMode() {
        privacyMode.toggle()
        UserDefaults.standard.set(privacyMode, forKey: "CodexAccountSwitcherPrivacyMode")
    }

    func displaySensitive(_ value: String) -> String {
        guard privacyMode, value != "-", !value.isEmpty else { return value }
        if value.contains("@") {
            let parts = value.split(separator: "@", maxSplits: 1).map(String.init)
            let name = parts.first ?? ""
            let domain = parts.count > 1 ? parts[1] : ""
            return "\(String(name.prefix(2)))***@\(domain)"
        }
        return shortAccount(value)
    }

    func saveAlias() {
        guard selectedID != currentSelection else {
            message = "Current Codex cannot be aliased. Capture it as a profile first."
            return
        }
        let cleaned = aliasDraft
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try writeProfileEnvValue(profile: selectedID, key: "local_alias", value: cleaned.isEmpty ? nil : cleaned)
            message = cleaned.isEmpty ? "Cleared alias for \(selectedID)." : "Saved alias for \(selectedID)."
            isEditingAlias = false
            reload()
        } catch {
            message = "Failed to save alias: \(error.localizedDescription)"
        }
    }

    func cancelAliasEdit() {
        aliasDraft = selectedMetadata.alias
        isEditingAlias = false
    }

    func renameSelectedProfile() {
        guard selectedID != currentSelection else {
            message = "Current Codex cannot be renamed. Capture it as a profile first."
            return
        }
        let oldName = selectedID
        let cleaned = profileNameDraft
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            message = "Enter a new profile name before renaming."
            return
        }
        guard cleaned != oldName else {
            isEditingProfileName = false
            return
        }
        guard isValidProfileName(cleaned) else {
            message = "Profile names may only use letters, numbers, dots, dashes, and underscores."
            return
        }
        perform(["rename", oldName, cleaned], successMessage: "Renamed \(oldName) to \(cleaned)") {
            self.selectedID = cleaned
            self.profileNameDraft = cleaned
            self.isEditingProfileName = false
        }
    }

    func cancelProfileRename() {
        profileNameDraft = selectedID == currentSelection ? "" : selectedID
        isEditingProfileName = false
    }

    func captureCurrent() {
        let trimmed = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "Enter a profile name before capturing."
            return
        }
        guard isValidProfileName(trimmed) else {
            message = "Profile names may only use letters, numbers, dots, dashes, and underscores."
            return
        }
        perform(["capture", trimmed], successMessage: "Captured \(trimmed)") {
            self.selectedID = trimmed
            self.newProfileName = ""
        }
    }

    func switchSelected() {
        guard selectedID != currentSelection else {
            message = "Choose a saved profile to switch."
            return
        }
        guard selectedID != activeProfile else {
            message = "\(selectedID) is already the active profile."
            return
        }
        perform(["switch", selectedID], successMessage: "Switched to \(selectedID)")
    }

    func saveActiveProfile() {
        guard !activeProfile.isEmpty else {
            message = "No active profile yet. Capture the current login first."
            return
        }
        perform(["capture", activeProfile], successMessage: "Saved \(activeProfile)")
    }

    func saveActiveAuthNow() {
        guard !activeProfile.isEmpty else {
            message = "No active profile yet. Capture the current login first."
            return
        }
        perform(["save-auth", activeProfile], successMessage: "Saved fresh token into \(activeProfile)")
    }

    func deleteSelected() {
        guard selectedID != currentSelection else {
            message = "Current Codex cannot be deleted."
            return
        }
        guard selectedID != activeProfile else {
            message = "The active profile cannot be deleted. Switch to another profile first."
            return
        }
        let deleting = selectedID
        perform(["delete", deleting], successMessage: "Deleted \(deleting)") {
            self.selectedID = currentSelection
        }
    }

    func importAuthFile() {
        let trimmed = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "Enter a profile name before importing auth.json."
            return
        }
        guard isValidProfileName(trimmed) else {
            message = "Profile names may only use letters, numbers, dots, dashes, and underscores."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Import auth.json"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else {
            message = "Import cancelled."
            return
        }

        perform(["import-auth", trimmed, url.path], successMessage: "Imported auth.json as \(trimmed)") {
            self.selectedID = trimmed
            self.newProfileName = ""
        }
    }

    func exportSelectedProfile() {
        guard selectedID != currentSelection else {
            message = "Choose a saved profile to export a backup."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Profile Backup"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "\(selectedID).codex-profile.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else {
            message = "Export cancelled."
            return
        }

        perform(["export-profile", selectedID, url.path], successMessage: "Exported \(selectedID) backup. Keep it private; it contains auth data.")
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
            message = "This token is not available in auth.json."
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
        let hasAccess = firstString([tokens["access_token"], tokens["accessToken"]]).isEmpty == false
        let hasRefresh = firstString([tokens["refresh_token"], tokens["refreshToken"]]).isEmpty == false
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
            capturedAt: "-",
            alias: "",
            desktopState: "-"
        )
    }

    private func metadata(forProfile name: String) -> AuthMetadata {
        readAuthMetadata(
            name: name,
            authURL: profileAuthURL(name),
            capturedAt: profileEnvValue(name, key: "captured_at"),
            alias: profileEnvValue(name, key: "local_alias", fallback: ""),
            desktopState: profileDesktopState(name)
        )
    }

    private func readAuthMetadata(name: String, authURL: URL, capturedAt: String, alias: String, desktopState: String) -> AuthMetadata {
        guard let data = try? Data(contentsOf: authURL), !data.isEmpty else {
            return AuthMetadata(
                profileName: name,
                alias: alias,
                authURL: authURL,
                exists: false,
                authMode: "-",
                accountID: "-",
                email: "-",
                planType: "-",
                workspaceID: "-",
                workspaceLabel: "-",
                seatType: "-",
                lastRefresh: "-",
                capturedAt: capturedAt,
                desktopState: desktopState,
                hasAPIKey: false,
                tokens: [:],
                tokenStatuses: [:],
                health: ProfileHealth(level: .error, title: "Missing auth", detail: "auth.json is missing or empty.", systemImage: "xmark.octagon.fill")
            )
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AuthMetadata(
                profileName: name,
                alias: alias,
                authURL: authURL,
                exists: true,
                authMode: "-",
                accountID: "-",
                email: "-",
                planType: "-",
                workspaceID: "-",
                workspaceLabel: "-",
                seatType: "-",
                lastRefresh: "-",
                capturedAt: capturedAt,
                desktopState: desktopState,
                hasAPIKey: false,
                tokens: [:],
                tokenStatuses: [:],
                health: ProfileHealth(level: .error, title: "Invalid auth", detail: "auth.json could not be parsed.", systemImage: "exclamationmark.triangle.fill")
            )
        }

        let tokenMap = raw["tokens"] as? [String: Any] ?? [:]
        var tokens: [String: String] = [:]
        let tokenAliases: [(String, [Any?])] = [
            ("access_token", [tokenMap["access_token"], tokenMap["accessToken"]]),
            ("refresh_token", [tokenMap["refresh_token"], tokenMap["refreshToken"]]),
            ("id_token", [tokenMap["id_token"], tokenMap["idToken"]])
        ]
        for (key, values) in tokenAliases {
            let value = firstString(values)
            if !value.isEmpty { tokens[key] = value }
        }

        let idTokenClaims = decodeJWTClaims(tokens["id_token"])
        let accessClaims = decodeJWTClaims(tokens["access_token"])
        let authClaims = firstDictionary([
            idTokenClaims["https://api.openai.com/auth"],
            accessClaims["https://api.openai.com/auth"]
        ])
        let email = firstString([
            idTokenClaims["email"],
            accessClaims["email"],
            accessClaims["https://api.openai.com/profile/email"]
        ])
        let accountID = firstString([
            tokenMap["account_id"],
            tokenMap["accountId"],
            idTokenClaims["https://api.openai.com/auth"],
            idTokenClaims["chatgpt_account_id"],
            idTokenClaims["sub"],
            accessClaims["sub"]
        ])
        let planType = firstString([
            authClaims["chatgpt_plan_type"],
            idTokenClaims["chatgpt_plan_type"],
            accessClaims["chatgpt_plan_type"]
        ])
        let workspaceID = firstString([
            authClaims["workspace_id"],
            authClaims["chatgpt_workspace_id"],
            authClaims["organization_id"],
            idTokenClaims["workspace_id"],
            idTokenClaims["organization_id"]
        ])
        let workspaceLabel = firstString([
            authClaims["workspace_label"],
            authClaims["workspace_name"],
            authClaims["organization_name"],
            idTokenClaims["workspace_label"],
            idTokenClaims["organization_name"]
        ])
        let seatType = firstString([
            authClaims["seat_type"],
            authClaims["chatgpt_seat_type"],
            idTokenClaims["seat_type"]
        ])
        let statuses = buildTokenStatuses(tokens: tokens)
        let hasAPIKey = (raw["OPENAI_API_KEY"] as? String)?.isEmpty == false
        let health = profileHealth(
            exists: true,
            hasAPIKey: hasAPIKey,
            tokens: tokens,
            tokenStatuses: statuses,
            desktopState: desktopState
        )

        return AuthMetadata(
            profileName: name,
            alias: alias,
            authURL: authURL,
            exists: true,
            authMode: stringValue(raw["auth_mode"], fallback: "-"),
            accountID: accountID.isEmpty ? "-" : accountID,
            email: email.isEmpty ? "-" : email,
            planType: planType.isEmpty ? "-" : normalizeSlug(planType),
            workspaceID: workspaceID.isEmpty ? "-" : workspaceID,
            workspaceLabel: workspaceLabel.isEmpty ? "-" : workspaceLabel,
            seatType: seatType.isEmpty ? "-" : normalizeSlug(seatType),
            lastRefresh: firstString([raw["last_refresh"], raw["lastRefreshAt"], raw["lastRefresh"]]).isEmpty ? "-" : firstString([raw["last_refresh"], raw["lastRefreshAt"], raw["lastRefresh"]]),
            capturedAt: capturedAt,
            desktopState: desktopState,
            hasAPIKey: hasAPIKey,
            tokens: tokens,
            tokenStatuses: statuses,
            health: health
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
                if let accountID = dict["chatgpt_account_id"] as? String, !accountID.isEmpty {
                    return accountID
                }
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

    private func firstDictionary(_ values: [Any?]) -> [String: Any] {
        for value in values {
            if let dict = value as? [String: Any] {
                return dict
            }
        }
        return [:]
    }

    private func buildTokenStatuses(tokens: [String: String]) -> [String: TokenStatus] {
        var statuses: [String: TokenStatus] = [:]
        statuses["access_token"] = expiringTokenStatus(
            key: "access_token",
            label: "Access",
            token: tokens["access_token"]
        )
        statuses["id_token"] = expiringTokenStatus(
            key: "id_token",
            label: "ID token",
            token: tokens["id_token"]
        )
        if tokens["refresh_token"]?.isEmpty == false {
            statuses["refresh_token"] = TokenStatus(
                key: "refresh_token",
                label: "Refresh",
                state: "Stored",
                detail: "Available for token refresh."
            )
        } else {
            statuses["refresh_token"] = TokenStatus(
                key: "refresh_token",
                label: "Refresh",
                state: "Missing",
                detail: "Re-authentication is likely required."
            )
        }
        return statuses
    }

    private func expiringTokenStatus(key: String, label: String, token: String?) -> TokenStatus {
        guard let token, !token.isEmpty else {
            return TokenStatus(key: key, label: label, state: "Missing", detail: "Token is not present.")
        }
        guard let expiry = tokenExpiryDate(token) else {
            return TokenStatus(key: key, label: label, state: "Unknown", detail: "No expiry claim found.")
        }
        if expiry <= Date() {
            return TokenStatus(key: key, label: label, state: "Expired", detail: formatRelativeExpiry(expiry))
        }
        return TokenStatus(key: key, label: label, state: "Valid", detail: formatRelativeExpiry(expiry))
    }

    private func tokenExpiryDate(_ token: String) -> Date? {
        let claims = decodeJWTClaims(token)
        guard let raw = claims["exp"] else { return nil }
        if let value = raw as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        if let value = raw as? TimeInterval {
            return Date(timeIntervalSince1970: value)
        }
        if let value = raw as? NSNumber {
            return Date(timeIntervalSince1970: value.doubleValue)
        }
        if let value = raw as? String, let seconds = TimeInterval(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    private func formatRelativeExpiry(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func profileHealth(
        exists: Bool,
        hasAPIKey: Bool,
        tokens: [String: String],
        tokenStatuses: [String: TokenStatus],
        desktopState: String
    ) -> ProfileHealth {
        guard exists else {
            return ProfileHealth(level: .error, title: "Missing auth", detail: "auth.json is missing.", systemImage: "xmark.octagon.fill")
        }
        if hasAPIKey {
            return ProfileHealth(level: .healthy, title: "API key auth", detail: "OPENAI_API_KEY is present.", systemImage: "terminal.fill")
        }
        if tokens.isEmpty {
            return ProfileHealth(level: .error, title: "No tokens", detail: "No usable token entries were found.", systemImage: "key.slash.fill")
        }
        if tokenStatuses["refresh_token"]?.state == "Missing" {
            return ProfileHealth(level: .error, title: "Reauth needed", detail: "Refresh token is missing.", systemImage: "person.badge.key.fill")
        }
        if tokenStatuses["access_token"]?.state == "Expired" {
            return ProfileHealth(level: .warning, title: "Refresh soon", detail: "Access token is expired; refresh token is stored.", systemImage: "clock.badge.exclamationmark.fill")
        }
        if desktopState == "Missing" {
            return ProfileHealth(level: .warning, title: "Auth only", detail: "Codex Desktop state was not captured.", systemImage: "macwindow.badge.exclamationmark")
        }
        return ProfileHealth(level: .healthy, title: "Ready", detail: "Auth and Desktop state look usable.", systemImage: "checkmark.seal.fill")
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

    private func profileEnvURL(_ name: String) -> URL {
        switcherHome
            .appendingPathComponent("profiles")
            .appendingPathComponent(name)
            .appendingPathComponent("profile.env")
    }

    private func profileEnvValue(_ name: String, key: String, fallback: String = "-") -> String {
        let envURL = profileEnvURL(name)
        guard let text = try? String(contentsOf: envURL, encoding: .utf8) else {
            return fallback
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\(key)=") {
                return String(line.dropFirst(key.count + 1))
            }
        }
        return fallback
    }

    private func writeProfileEnvValue(profile name: String, key: String, value: String?) throws {
        let envURL = profileEnvURL(name)
        var lines: [String] = []
        if let text = try? String(contentsOf: envURL, encoding: .utf8) {
            lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.hasPrefix("\(key)=") }
        } else {
            lines = ["name=\(name)"]
        }
        if let value, !value.isEmpty {
            lines.append("\(key)=\(value)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: envURL, atomically: true, encoding: .utf8)
    }

    private func profileDesktopState(_ name: String) -> String {
        let url = switcherHome
            .appendingPathComponent("profiles")
            .appendingPathComponent(name)
            .appendingPathComponent("app-support")
            .appendingPathComponent("Codex")
        return FileManager.default.fileExists(atPath: url.path) ? "Captured" : "Missing"
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
        let metadata = readAuthMetadata(name: "Current Codex", authURL: url, capturedAt: "-", alias: "", desktopState: "-")
        if metadata.email != "-" {
            return metadata.email
        }
        return shortAccount(metadata.accountID)
    }

    private func profileContextLine(_ metadata: AuthMetadata) -> String {
        let plan = metadata.planType == "-" ? "unknown plan" : metadata.planType
        let workspace = metadata.workspaceLabel != "-" ? metadata.workspaceLabel : (metadata.workspaceID != "-" ? shortAccount(metadata.workspaceID) : "Personal / unknown workspace")
        return "\(plan) | \(workspace)"
    }

    private func shortAccount(_ value: String) -> String {
        guard value != "-", value.count > 12 else { return value }
        return "\(value.prefix(8))...\(value.suffix(4))"
    }

    private func normalizeSlug(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
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
                            isSelected: store.selectedID == row.id,
                            privacyMode: store.privacyMode
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
            Label("Add profile", systemImage: "plus.circle.fill")
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

            Button {
                store.importAuthFile()
            } label: {
                Label("Import auth.json", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(store.isWorking)
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

            Button {
                store.togglePrivacyMode()
            } label: {
                Label(store.privacyMode ? "Show Details" : "Hide Details", systemImage: store.privacyMode ? "eye.slash" : "eye")
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
                tokenStatusPanel
                importExportPanel
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
                        aliasHeader
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

                    profileNameControl
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
                SummaryTile(title: "Health", value: store.selectedMetadata.health.title, systemImage: store.selectedMetadata.health.systemImage, color: healthColor(store.selectedMetadata.health))
                SummaryTile(title: "Auth file", value: store.selectedMetadata.exists ? "Found" : "Missing", systemImage: "doc.text.magnifyingglass", color: store.selectedMetadata.exists ? .green : .red)
                SummaryTile(title: "Tokens", value: "\(store.selectedMetadata.tokens.count)", systemImage: "key.horizontal.fill", color: .orange)
                SummaryTile(title: "API key", value: store.selectedMetadata.hasAPIKey ? "Present" : "None", systemImage: "terminal.fill", color: store.selectedMetadata.hasAPIKey ? .purple : .secondary)
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var aliasHeader: some View {
        HStack(spacing: 6) {
            if store.isEditingAlias {
                TextField("Profile alias", text: $store.aliasDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                    .onSubmit {
                        store.saveAlias()
                    }
                Button {
                    store.saveAlias()
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.borderless)
                .disabled(store.isWorking)
                Button {
                    store.cancelAliasEdit()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            } else {
                Text(store.selectedMetadata.displayName)
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(1)
                if store.selectedID != currentSelection {
                    Button {
                        store.aliasDraft = store.selectedMetadata.alias
                        store.isEditingAlias = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Edit local alias")
                }
            }
        }
    }

    private var profileNameControl: some View {
        HStack(spacing: 6) {
            if store.selectedID == currentSelection {
                Label("Live Codex auth", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if store.isEditingProfileName {
                TextField("Profile name", text: $store.profileNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit {
                        store.renameSelectedProfile()
                    }
                Button {
                    store.renameSelectedProfile()
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.borderless)
                .disabled(store.isWorking)
                Button {
                    store.cancelProfileRename()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            } else {
                Text("Profile ID: \(store.selectedID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    store.profileNameDraft = store.selectedID
                    store.isEditingProfileName = true
                } label: {
                    Label("Rename", systemImage: "text.cursor")
                }
                .font(.caption)
                .buttonStyle(.link)
                .disabled(store.isWorking)
            }
        }
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
                metadataRow("Email", store.displaySensitive(store.selectedMetadata.email))
                metadataRow("Account ID", store.displaySensitive(store.selectedMetadata.accountID))
                metadataRow("Plan", store.selectedMetadata.planType)
                metadataRow("Workspace", workspaceDisplay)
                metadataRow("Seat", store.selectedMetadata.seatType)
                metadataRow("Last refresh", store.selectedMetadata.lastRefresh)
                metadataRow("Captured at", store.selectedMetadata.capturedAt)
                metadataRow("Desktop state", store.selectedMetadata.desktopState)
                metadataRow("Auth path", store.selectedMetadata.authURL.path)
            }
        }
    }

    private var importExportPanel: some View {
        SectionPanel(title: "Backup & Import", systemImage: "archivebox.fill") {
            HStack(spacing: 10) {
                Button {
                    store.exportSelectedProfile()
                } label: {
                    ActionButtonLabel(
                        title: "Export Backup",
                        subtitle: "Zip selected profile",
                        systemImage: "square.and.arrow.up.fill"
                    )
                }
                .buttonStyle(SecondaryActionButtonStyle(color: .blue))
                .disabled(store.isWorking || store.selectedID == currentSelection)

                Button {
                    store.importAuthFile()
                } label: {
                    ActionButtonLabel(
                        title: "Import Auth",
                        subtitle: "Create auth-only profile",
                        systemImage: "doc.badge.plus"
                    )
                }
                .buttonStyle(SecondaryActionButtonStyle(color: .purple))
                .disabled(store.isWorking)

                Button {
                    store.openProfilesFolder()
                } label: {
                    ActionButtonLabel(
                        title: "Profiles Folder",
                        subtitle: "Open local store",
                        systemImage: "folder.fill"
                    )
                }
                .buttonStyle(SecondaryActionButtonStyle(color: .gray))
                .disabled(store.isWorking)
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.orange)
                Text("Backups are local zip files and include sensitive auth data. Store them somewhere private.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tokenStatusPanel: some View {
        SectionPanel(title: "Token Status", systemImage: "key.radiowaves.forward.fill") {
            VStack(spacing: 8) {
                ForEach(["access_token", "refresh_token", "id_token"], id: \.self) { key in
                    let status = store.selectedMetadata.tokenStatuses[key] ?? TokenStatus(key: key, label: store.friendlyTokenName(key), state: "Missing", detail: "Token is not present.")
                    TokenStatusRow(status: status, color: tokenStatusColor(status))
                }
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
        if store.selectedMetadata.alias.isEmpty == false, store.selectedMetadata.profileName != "Current Codex" {
            let email = store.selectedMetadata.email != "-" ? store.displaySensitive(store.selectedMetadata.email) : store.selectedMetadata.profileName
            return "\(email) | \(workspaceDisplay)"
        }
        if store.selectedMetadata.email != "-" {
            return store.displaySensitive(store.selectedMetadata.email)
        }
        if store.selectedMetadata.accountID != "-" {
            return store.displaySensitive(store.selectedMetadata.accountID)
        }
        return store.selectedMetadata.authURL.path
    }

    private var workspaceDisplay: String {
        if store.selectedMetadata.workspaceLabel != "-" {
            return store.selectedMetadata.workspaceLabel
        }
        if store.selectedMetadata.workspaceID != "-" {
            return store.displaySensitive(store.selectedMetadata.workspaceID)
        }
        return "Personal / unknown workspace"
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

    private func healthColor(_ health: ProfileHealth) -> Color {
        switch health.level {
        case .healthy: return .green
        case .warning: return .orange
        case .error: return .red
        case .unknown: return .secondary
        }
    }

    private func tokenStatusColor(_ status: TokenStatus) -> Color {
        switch status.state.lowercased() {
        case "valid", "stored", "parsed": return .green
        case "expired", "missing": return .red
        case "unknown": return .orange
        default: return .secondary
        }
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
    let privacyMode: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: row.isCurrentAuth ? "bolt.circle.fill" : "person.crop.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 34, height: 34)
                    .background(iconColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 5) {
                    Text(row.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(masked(row.subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(masked(row.meta))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 6) {
                    if row.isActive {
                        StatusPill(text: "Active", color: .green, systemImage: "checkmark.circle.fill")
                    }
                    HealthBadge(health: row.health)
                }
                .frame(minWidth: 74, alignment: .trailing)
            }
            .padding(12)
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

    private func masked(_ value: String) -> String {
        guard privacyMode else { return value }
        if let range = value.range(of: #"[\w.+-]+@[\w.-]+"#, options: .regularExpression) {
            let email = String(value[range])
            let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
            let maskedEmail = "\(String((parts.first ?? "").prefix(2)))***@\(parts.count > 1 ? parts[1] : "")"
            return value.replacingCharacters(in: range, with: maskedEmail)
        }
        return value
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
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
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

private struct HealthBadge: View {
    let health: ProfileHealth

    var body: some View {
        Label(health.title, systemImage: health.systemImage)
            .font(.system(size: 10, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: 90, alignment: .trailing)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .help(health.detail)
    }

    private var color: Color {
        switch health.level {
        case .healthy: return .green
        case .warning: return .orange
        case .error: return .red
        case .unknown: return .secondary
        }
    }
}

private struct TokenStatusRow: View {
    let status: TokenStatus
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.label)
                    .font(.system(size: 12, weight: .semibold))
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(status.state)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch status.state.lowercased() {
        case "valid", "stored", "parsed": return "checkmark.circle.fill"
        case "expired", "missing": return "exclamationmark.triangle.fill"
        default: return "questionmark.circle.fill"
        }
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
        menu.addItem(NSMenuItem(title: "Open Codex", action: #selector(menuOpenCodex), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        for row in store.rows where !row.isCurrentAuth {
            let title = row.isActive ? "\(row.displayName)  (active)" : row.displayName
            let item = NSMenuItem(title: title, action: #selector(menuSwitchProfile(_:)), keyEquivalent: "")
            item.representedObject = row.id
            item.target = self
            item.isEnabled = !row.isActive
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let saveActiveItem = NSMenuItem(title: "Save Active State", action: #selector(menuSaveActiveState), keyEquivalent: "")
        saveActiveItem.isEnabled = !store.activeProfile.isEmpty && !store.isWorking
        menu.addItem(saveActiveItem)
        let saveTokenItem = NSMenuItem(title: "Save Fresh Token", action: #selector(menuSaveFreshToken), keyEquivalent: "")
        saveTokenItem.isEnabled = !store.activeProfile.isEmpty && !store.isWorking
        menu.addItem(saveTokenItem)
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

    @objc private func menuOpenCodex() {
        store.openCodex()
    }

    @objc private func menuSaveActiveState() {
        store.saveActiveProfile()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.rebuildMenu()
        }
    }

    @objc private func menuSaveFreshToken() {
        store.saveActiveAuthNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.rebuildMenu()
        }
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
