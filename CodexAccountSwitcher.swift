import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private let currentSelection = "__current_codex_auth__"
private let usageSnapshotsDefaultsKey = "CodexAccountSwitcherUsageSnapshotsByProfile.v2"
private let usageValidSinceDefaultsKey = "CodexAccountSwitcherUsageValidSinceByProfile.v2"
private let managedHomesFolderName = "managed-codex-homes"
private let themeModeDefaultsKey = "CodexAccountSwitcherThemeMode"

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

enum AppThemeMode: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .dark: return .dark
        }
    }

    var accent: Color {
        switch self {
        case .light: return Color(red: 0.06, green: 0.43, blue: 0.92)
        case .dark: return Color(red: 0.45, green: 0.72, blue: 1.0)
        }
    }
}

struct UsageLimitWindow: Codable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetAt: Date?

    var leftPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct CodexUsageSnapshot: Codable {
    let contextUsed: Int
    let contextWindow: Int
    let model: String
    let updatedAt: Date?
    let observedAt: Date?
    let primaryLimit: UsageLimitWindow?
    let secondaryLimit: UsageLimitWindow?

    static let empty = CodexUsageSnapshot(
        contextUsed: 0,
        contextWindow: 272000,
        model: "-",
        updatedAt: nil,
        observedAt: nil,
        primaryLimit: nil,
        secondaryLimit: nil
    )

    var contextLeftPercent: Double {
        guard contextWindow > 0 else { return 0 }
        return max(0, min(100, 100 - (Double(contextUsed) / Double(contextWindow) * 100)))
    }
}

private struct RateLimitSnapshot {
    let primary: UsageLimitWindow?
    let secondary: UsageLimitWindow?
    let observedAt: Date
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
    @Published var themeMode: AppThemeMode
    @Published var aliasDraft: String = ""
    @Published var isEditingAlias: Bool = false
    @Published var profileNameDraft: String = ""
    @Published var isEditingProfileName: Bool = false
    @Published var isWorking: Bool = false
    @Published var message: String = "Ready"
    @Published var usageSnapshot: CodexUsageSnapshot = .empty
    @Published var usageSnapshotsByProfile: [String: CodexUsageSnapshot] = [:]
    private var usageValidSinceByProfile: [String: Date] = [:]

    let switcherHome: URL
    private let scriptPath: String
    private let codexHome: URL
    private let codexAppSupport: URL
    private let managedHomesRoot: URL
    private var autoSaveTimer: Timer?
    private var isAutoSaving = false
    private var lastAutoSaveFingerprint = ""

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switcherHome = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("CodexAccountSwitcher")
        codexHome = home.appendingPathComponent(".codex")
        codexAppSupport = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Codex")
        managedHomesRoot = switcherHome.appendingPathComponent(managedHomesFolderName)

        if let bundled = Bundle.main.path(forResource: "codex-account-switcher", ofType: "sh") {
            scriptPath = bundled
        } else {
            scriptPath = FileManager.default.currentDirectoryPath + "/codex-account-switcher.sh"
        }
        privacyMode = UserDefaults.standard.bool(forKey: "CodexAccountSwitcherPrivacyMode")
        let storedThemeMode = UserDefaults.standard.string(forKey: themeModeDefaultsKey) ?? AppThemeMode.dark.rawValue
        themeMode = AppThemeMode(rawValue: storedThemeMode) ?? .dark
        usageSnapshotsByProfile = loadUsageSnapshotsByProfile()
        usageValidSinceByProfile = loadUsageValidSinceByProfile()

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

    func reload(refreshUsage: Bool = true) {
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
        if refreshUsage {
            refreshUsageSnapshotsAsync()
        }
    }

    func refreshUsageSnapshotsAsync() {
        let profileIDs = rows.map(\.id)
        DispatchQueue.global(qos: .utility).async {
            var snapshots: [String: CodexUsageSnapshot] = [:]
            for profileID in profileIDs {
                let minDate = self.usageValidSinceByProfile[profileID]
                if let snapshot = self.readUsageSnapshot(forProfile: profileID, minRateLimitDate: minDate) {
                    snapshots[profileID] = snapshot
                }
            }

            DispatchQueue.main.async {
                guard !snapshots.isEmpty else { return }
                for (profileID, snapshot) in snapshots {
                    self.usageSnapshotsByProfile[profileID] = snapshot
                }
                let activeID = self.activeProfile.isEmpty ? currentSelection : self.activeProfile
                self.usageSnapshot = snapshots[activeID] ?? snapshots[currentSelection] ?? self.usageSnapshot
                self.saveUsageSnapshotsByProfile()
            }
        }
    }

    func refreshUsageSnapshotAsync() {
        let profileID = activeProfile.isEmpty ? currentSelection : activeProfile
        let minDate = usageValidSinceByProfile[profileID]
        DispatchQueue.global(qos: .utility).async {
            let snapshot = self.readUsageSnapshot(forProfile: profileID, minRateLimitDate: minDate)
            DispatchQueue.main.async {
                guard let snapshot else { return }
                self.usageSnapshot = snapshot
                self.usageSnapshotsByProfile[profileID] = snapshot
                self.saveUsageSnapshotsByProfile()
            }
        }
    }

    func cacheUsageSnapshotForActiveProfile() {
        let profileID = activeProfile.isEmpty ? currentSelection : activeProfile
        let snapshot = readUsageSnapshot(forProfile: profileID, minRateLimitDate: usageValidSinceByProfile[profileID])
        guard let snapshot else { return }
        usageSnapshot = snapshot
        usageSnapshotsByProfile[profileID] = snapshot
        saveUsageSnapshotsByProfile()
    }

    func markUsageValidFromNow(for profileID: String) {
        usageValidSinceByProfile[profileID] = Date()
        saveUsageValidSinceByProfile()
        usageSnapshot = usageSnapshot(for: profileID)
    }

    func usageSnapshot(for profileID: String) -> CodexUsageSnapshot {
        usageSnapshotsByProfile[profileID] ?? .empty
    }

    private func loadUsageSnapshotsByProfile() -> [String: CodexUsageSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: usageSnapshotsDefaultsKey),
              let snapshots = try? JSONDecoder().decode([String: CodexUsageSnapshot].self, from: data) else {
            return [:]
        }
        return snapshots
    }

    private func saveUsageSnapshotsByProfile() {
        guard let data = try? JSONEncoder().encode(usageSnapshotsByProfile) else { return }
        UserDefaults.standard.set(data, forKey: usageSnapshotsDefaultsKey)
    }

    private func loadUsageValidSinceByProfile() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: usageValidSinceDefaultsKey),
              let values = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        return values
    }

    private func saveUsageValidSinceByProfile() {
        guard let data = try? JSONEncoder().encode(usageValidSinceByProfile) else { return }
        UserDefaults.standard.set(data, forKey: usageValidSinceDefaultsKey)
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

    func setThemeMode(_ mode: AppThemeMode) {
        themeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: themeModeDefaultsKey)
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

    func addAccountWithCodexLogin() {
        guard !isWorking else { return }
        let accountID = UUID()
        let homeURL = managedHomesRoot.appendingPathComponent(accountID.uuidString, isDirectory: true)
        isWorking = true
        message = "Adding account... Complete the Codex login in the browser or terminal prompt."

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.runCodexLogin(homeURL: homeURL, timeout: 120)
            guard result.status == 0 else {
                try? FileManager.default.removeItem(at: homeURL)
                DispatchQueue.main.async {
                    self.isWorking = false
                    self.message = result.output.isEmpty ? "Codex login failed." : result.output
                }
                return
            }

            let profileName = self.profileNameForManagedHome(homeURL, fallbackID: accountID)
            let importResult = self.run(["import-home", profileName, homeURL.path])
            DispatchQueue.main.async {
                self.isWorking = false
                if importResult.status == 0 {
                    self.selectedID = profileName
                    self.message = "Added \(profileName)."
                    self.reload()
                } else {
                    try? FileManager.default.removeItem(at: homeURL)
                    self.message = importResult.output.isEmpty ? "Failed to import logged-in account." : importResult.output
                }
            }
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
        cacheUsageSnapshotForActiveProfile()
        let targetProfile = selectedID
        perform(["switch", targetProfile], successMessage: "Switched to \(targetProfile)", refreshUsage: false) {
            self.markUsageValidFromNow(for: targetProfile)
        }
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

    private func perform(_ args: [String], successMessage: String, refreshUsage: Bool = true, afterSuccess: (() -> Void)? = nil) {
        isWorking = true
        message = "Working..."
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.run(args)
            DispatchQueue.main.async {
                self.isWorking = false
                if result.status == 0 {
                    afterSuccess?()
                    self.message = successMessage
                    self.reload(refreshUsage: refreshUsage)
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
            self?.refreshUsageSnapshotsAsync()
        }
        autoSaveActiveAuthIfNeeded()
        refreshUsageSnapshotsAsync()
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

    private func runExecutable(_ executable: String, _ arguments: [String]) -> CommandResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
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

    private func runCodexLogin(homeURL: URL, timeout: TimeInterval) -> CommandResult {
        do {
            try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        } catch {
            return CommandResult(status: 1, output: error.localizedDescription)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["codex", "login"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = homeURL.path
        environment["PATH"] = effectiveLoginPath(environment["PATH"])
        task.environment = environment

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
        } catch {
            return CommandResult(status: 127, output: "Could not start `codex login`: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if task.isRunning {
            task.terminate()
            Thread.sleep(forTimeInterval: 1)
            if task.isRunning {
                kill(task.processIdentifier, SIGKILL)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return CommandResult(status: 124, output: output.isEmpty ? "Codex login timed out." : output)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return CommandResult(status: task.terminationStatus, output: output)
    }

    private func effectiveLoginPath(_ currentPath: String?) -> String {
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        guard let currentPath, !currentPath.isEmpty else { return fallback }
        return "\(currentPath):\(fallback)"
    }

    private func profileNameForManagedHome(_ homeURL: URL, fallbackID: UUID) -> String {
        let metadata = readAuthMetadata(
            name: fallbackID.uuidString,
            authURL: homeURL.appendingPathComponent("auth.json"),
            capturedAt: "-",
            alias: "",
            desktopState: "-"
        )
        let base: String
        if metadata.email != "-" {
            base = metadata.email
                .split(separator: "@")
                .first
                .map(String.init) ?? "codex"
        } else if metadata.accountID != "-" {
            base = String(metadata.accountID.prefix(12))
        } else {
            base = "codex"
        }

        let cleaned = base
            .lowercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber || character == "." || character == "_" || character == "-" {
                    return character
                }
                return "-"
            }
        let prefix = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        let candidate = prefix.isEmpty ? "codex" : prefix
        return uniqueProfileName(startingWith: candidate)
    }

    private func uniqueProfileName(startingWith base: String) -> String {
        let profilesURL = switcherHome.appendingPathComponent("profiles")
        var candidate = base
        var index = 2
        while FileManager.default.fileExists(atPath: profilesURL.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }

    private func readUsageSnapshot(forProfile profileID: String, minRateLimitDate: Date?) -> CodexUsageSnapshot? {
        for root in usageRoots(forProfile: profileID) {
            if let snapshot = readUsageSnapshot(from: root, minRateLimitDate: minRateLimitDate) {
                return snapshot
            }
        }
        return nil
    }

    private func readUsageSnapshot(from root: URL, minRateLimitDate: Date?) -> CodexUsageSnapshot? {
        let stateDB = root.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: stateDB.path) else {
            return nil
        }

        let query = "select coalesce(tokens_used,0), coalesce(model,''), coalesce(updated_at_ms, updated_at * 1000) from threads where tokens_used > 0 order by updated_at desc limit 1;"
        let result = runExecutable("/usr/bin/sqlite3", ["-separator", "\t", stateDB.path, query])
        guard result.status == 0 else {
            debugLog("usage snapshot sqlite failed: \(result.output)")
            return nil
        }

        let parts = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 3 else {
            return nil
        }

        let used = Int(parts[0]) ?? 0
        let model = parts[1].isEmpty ? "-" : parts[1]
        let updatedMillis = TimeInterval(parts[2]) ?? 0
        let contextWindow = contextWindowForModel(model)
        let limits = readRateLimits(from: root, minDate: minRateLimitDate)

        return CodexUsageSnapshot(
            contextUsed: used,
            contextWindow: contextWindow,
            model: model,
            updatedAt: updatedMillis > 0 ? Date(timeIntervalSince1970: updatedMillis / 1000) : nil,
            observedAt: limits?.observedAt,
            primaryLimit: limits?.primary,
            secondaryLimit: limits?.secondary
        )
    }

    private func usageRoots(forProfile profileID: String) -> [URL] {
        var roots: [URL] = []
        if profileID == currentSelection || profileID == activeProfile {
            roots.append(codexHome)
            roots.append(codexAppSupport)
        }
        if profileID != currentSelection {
            let profileSupport = profileAppSupportURL(profileID)
            roots.append(profileSupport)
            let managedHome = profileEnvValue(profileID, key: "managed_codex_home", fallback: "")
            if !managedHome.isEmpty {
                roots.append(URL(fileURLWithPath: managedHome, isDirectory: true))
            }
        }
        var seen: Set<String> = []
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func contextWindowForModel(_ model: String) -> Int {
        let windows = [
            "gpt-5.5": 272000,
            "gpt-5.2": 272000,
            "gpt-5.1": 272000,
            "gpt-5": 272000
        ]
        return windows[model] ?? 272000
    }

    private func readRateLimits(from root: URL, minDate: Date?) -> RateLimitSnapshot? {
        let logsDB = root.appendingPathComponent("logs_2.sqlite")
        guard FileManager.default.fileExists(atPath: logsDB.path) else {
            return nil
        }

        let minSeconds = minDate.map { Int($0.timeIntervalSince1970) } ?? 0
        let query = "select ts, feedback_log_body from logs where ts >= \(minSeconds) and feedback_log_body like '%\"type\":\"codex.rate_limits\"%' order by ts desc, ts_nanos desc, id desc limit 1;"
        let result = runExecutable("/usr/bin/sqlite3", ["-separator", "\t", logsDB.path, query])
        guard result.status == 0 else {
            debugLog("rate limit sqlite failed: \(result.output)")
            return nil
        }

        let parts = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 2,
              let observedSeconds = TimeInterval(parts[0]),
              let range = parts[1].range(of: #"{"type":"codex.rate_limits""#),
              let data = String(parts[1][range.lowerBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimits = raw["rate_limits"] as? [String: Any] else {
            return nil
        }

        return RateLimitSnapshot(
            primary: parseUsageLimit(rateLimits["primary"]),
            secondary: parseUsageLimit(rateLimits["secondary"]),
            observedAt: Date(timeIntervalSince1970: observedSeconds)
        )
    }

    private func parseUsageLimit(_ value: Any?) -> UsageLimitWindow? {
        guard let raw = value as? [String: Any],
              let usedPercent = doubleValue(raw["used_percent"]),
              let windowMinutes = intValue(raw["window_minutes"]) else {
            return nil
        }
        let resetAt: Date?
        if let seconds = doubleValue(raw["reset_at"]) {
            resetAt = Date(timeIntervalSince1970: seconds)
        } else {
            resetAt = nil
        }
        return UsageLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetAt: resetAt
        )
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

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
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
        let url = profileAppSupportURL(name)
        return FileManager.default.fileExists(atPath: url.path) ? "Captured" : "Missing"
    }

    private func profileAppSupportURL(_ name: String) -> URL {
        switcherHome
            .appendingPathComponent("profiles")
            .appendingPathComponent(name)
            .appendingPathComponent("app-support")
            .appendingPathComponent("Codex")
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

private struct LiquidGlassBackground: View {
    let themeMode: AppThemeMode

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            LinearGradient(
                colors: [
                    themeMode.accent.opacity(themeMode == .dark ? 0.22 : 0.16),
                    Color(nsColor: .windowBackgroundColor).opacity(themeMode == .dark ? 0.54 : 0.70),
                    Color(nsColor: .controlAccentColor).opacity(themeMode == .dark ? 0.10 : 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Rectangle()
                .fill(themeMode == .dark ? Color.black.opacity(0.18) : Color.white.opacity(0.10))
        }
        .ignoresSafeArea()
    }
}

private struct LiquidGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color
    let isProminent: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint.opacity(isProminent ? 0.13 : 0.06))
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isProminent ? 0.30 : 0.20),
                                tint.opacity(isProminent ? 0.28 : 0.16),
                                Color.black.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(isProminent ? 0.16 : 0.08), radius: isProminent ? 18 : 10, x: 0, y: isProminent ? 10 : 5)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private extension View {
    func liquidGlass(
        cornerRadius: CGFloat = 8,
        tint: Color = Color.accentColor,
        isProminent: Bool = false
    ) -> some View {
        modifier(LiquidGlassModifier(cornerRadius: cornerRadius, tint: tint, isProminent: isProminent))
    }
}

struct ManagerView: View {
    @ObservedObject var store: AccountStore
    @State private var hoveredProfileID: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Color.white.opacity(store.themeMode == .dark ? 0.08 : 0.18))
                .frame(width: 1)
            detail
        }
        .background(LiquidGlassBackground(themeMode: store.themeMode))
        .preferredColorScheme(store.themeMode.colorScheme)
        .tint(store.themeMode.accent)
        .frame(minWidth: 980, minHeight: 660)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.badge.key.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(store.themeMode.accent)
                    .frame(width: 38, height: 38)
                    .liquidGlass(cornerRadius: 8, tint: store.themeMode.accent, isProminent: true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Manager")
                        .font(.system(size: 20, weight: .semibold))
                    Text("\(profileCount) saved profiles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 2)

            themeControl

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.rows) { row in
                        ProfileCardButton(
                            row: row,
                            isSelected: store.selectedID == row.id,
                            privacyMode: store.privacyMode
                        ) {
                            store.selectedID = row.id
                        } onHover: { isHovering in
                            hoveredProfileID = isHovering ? row.id : nil
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .onReceive(store.$selectedID.dropFirst()) { _ in
                store.revealToken = false
                store.loadSelected()
            }

            utilityButtons
        }
        .padding(18)
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(store.themeMode == .dark ? 0.07 : 0.22))
                .frame(width: 1)
        }
    }

    private var themeControl: some View {
        HStack(spacing: 6) {
            ForEach(AppThemeMode.allCases) { mode in
                Button {
                    store.setThemeMode(mode)
                } label: {
                    Label(mode.title, systemImage: mode.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.themeMode == mode ? store.themeMode.accent : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(store.themeMode == mode ? store.themeMode.accent.opacity(0.16) : Color.clear)
                )
            }
        }
        .padding(4)
        .liquidGlass(cornerRadius: 8, tint: store.themeMode.accent)
    }

    private var statusPanel: some View {
        HStack(alignment: .center, spacing: 10) {
            Label("Activity", systemImage: messageIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(messageColor)
                .frame(width: 92, alignment: .leading)

            Text(statusDisplayText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .liquidGlass(cornerRadius: 8, tint: messageColor)
        .help(store.message)
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
        .padding(10)
        .liquidGlass(cornerRadius: 8, tint: store.themeMode.accent)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerPanel
                actionPanel
                usagePanel
                tokenStatusPanel
                metadataPanel
                tokenVault
                statusPanel
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
                    .liquidGlass(cornerRadius: 8, tint: selectedIconColor, isProminent: true)

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
        .liquidGlass(cornerRadius: 8, tint: selectedIconColor, isProminent: true)
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
            HStack {
                Label("Account Actions", systemImage: "person.crop.circle.badge.gearshape")
                    .font(.headline)
                Spacer()
                Button {
                    store.addAccountWithCodexLogin()
                } label: {
                    Label(store.isWorking ? "Adding..." : "Add Account", systemImage: "person.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.isWorking)
            }

            HStack(spacing: 8) {
                TextField("profile name", text: $store.newProfileName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)

                Button {
                    store.captureCurrent()
                } label: {
                    Label("Capture", systemImage: "tray.and.arrow.down.fill")
                }
                .disabled(store.isWorking)

                Button {
                    store.importAuthFile()
                } label: {
                    Label("Import auth.json", systemImage: "square.and.arrow.down")
                }
                .disabled(store.isWorking)
            }
            .controlSize(.small)
            .padding(10)
            .liquidGlass(cornerRadius: 8, tint: store.themeMode.accent)

            HStack(spacing: 10) {
                Button {
                    store.switchSelected()
                } label: {
                    ActionButtonLabel(
                        title: "Switch",
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
                        systemImage: "trash.fill"
                    )
                }
                .buttonStyle(SecondaryActionButtonStyle(color: .red))
                .disabled(store.isWorking || store.selectedID == currentSelection || store.selectedID == store.activeProfile)
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 8, tint: store.themeMode.accent)
    }

    private var usagePanel: some View {
        let snapshot = store.usageSnapshot(for: usageProfileID)
        return SectionPanel(title: "Codex Usage", systemImage: "chart.bar.xaxis") {
            VStack(spacing: 12) {
                UsageMeterRow(
                    title: "Context",
                    leftPercent: snapshot.contextLeftPercent,
                    detail: "\(formatNumber(snapshot.contextUsed)) used / \(compactNumber(snapshot.contextWindow))",
                    resetText: snapshot.model == "-" ? "No thread data" : snapshot.model,
                    color: .blue
                )

                UsageMeterRow(
                    title: "5h limit",
                    leftPercent: snapshot.primaryLimit?.leftPercent,
                    detail: nil,
                    resetText: resetText(for: snapshot.primaryLimit),
                    color: .green
                )

                UsageMeterRow(
                    title: "7d limit",
                    leftPercent: snapshot.secondaryLimit?.leftPercent,
                    detail: nil,
                    resetText: resetText(for: snapshot.secondaryLimit),
                    color: .orange
                )
            }
        }
    }

    private var usageProfileID: String {
        hoveredProfileID ?? store.selectedID
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
                .liquidGlass(cornerRadius: 8, tint: store.themeMode.accent)

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
        if lower.contains("saved") || lower.contains("captured") || lower.contains("switched") || lower.contains("copied") || lower.contains("added") {
            return .green
        }
        return .secondary
    }

    private var messageIcon: String {
        messageColor == .red ? "exclamationmark.triangle.fill" : "info.circle.fill"
    }

    private var statusDisplayText: String {
        let trimmed = store.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("Starting local login server") {
            return "Login started. Continue in the browser, then return here."
        }
        return trimmed.isEmpty ? "Ready" : trimmed
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

    private func resetText(for limit: UsageLimitWindow?) -> String {
        guard let limit else { return "No recent data" }
        guard let resetAt = limit.resetAt else { return "Reset unknown" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "resets \(formatter.localizedString(for: resetAt, relativeTo: Date()))"
    }

    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func compactNumber(_ value: Int) -> String {
        if value >= 1000 {
            return "\(value / 1000)K"
        }
        return "\(value)"
    }
}

private struct ProfileCardButton: View {
    let row: ProfileRow
    let isSelected: Bool
    let privacyMode: Bool
    let action: () -> Void
    let onHover: (Bool) -> Void

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
                .frame(width: 92, alignment: .trailing)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(cardBackground)
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.72) : Color.white.opacity(0.12), lineWidth: isSelected ? 1.3 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
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
        isSelected ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.035)
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
            .frame(width: 82, alignment: .center)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(color.opacity(0.22), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
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
        .liquidGlass(cornerRadius: 8, tint: color)
    }
}

private struct UsageMeterRow: View {
    let title: String
    let leftPercent: Double?
    let detail: String?
    let resetText: String
    let color: Color

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 82, alignment: .leading)

                meterBar
                    .frame(minWidth: 240, maxWidth: .infinity)

                HStack(spacing: 5) {
                    Text(leftText)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(leftPercent == nil ? .secondary : .primary)
                    if let detail {
                        Text("(\(detail))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(resetText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 250, alignment: .leading)
            }
        }
    }

    private var meterBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let progress = max(0, min(1, (leftPercent ?? 0) / 100))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .separatorColor).opacity(0.32))

                RoundedRectangle(cornerRadius: 3)
                    .fill(leftPercent == nil ? Color.secondary.opacity(0.24) : color.opacity(0.78))
                    .frame(width: max(0, width * progress))
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var leftText: String {
        guard let leftPercent else { return "-- left" }
        return "\(Int(leftPercent.rounded()))% left"
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
            .frame(width: 82, alignment: .center)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(color.opacity(0.22), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
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
                .background(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(color.opacity(0.22), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .padding(10)
        .liquidGlass(cornerRadius: 8, tint: color)
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
        .liquidGlass(cornerRadius: 8, tint: Color.accentColor)
    }
}

private struct ActionButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(12)
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.72 : 0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .opacity(configuration.isPressed ? 0.10 : 0.04)
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SecondaryActionButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color)
            .background(.ultraThinMaterial)
            .background(color.opacity(configuration.isPressed ? 0.18 : 0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(color.opacity(0.28), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

final class MenuBarState: ObservableObject {
    @Published var selectedProfileID: String = ""
    @Published var hoveredProfileID: String?
}

private struct MenuBarSwitcherView: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var state: MenuBarState

    let openManager: () -> Void
    let refresh: () -> Void
    let switchProfile: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            MenuBarUsageView(snapshot: store.usageSnapshot(for: usageProfileID), profileName: usageProfileName)

            if savedRows.isEmpty {
                emptyState
            } else {
                accountList
                switchButton
            }

            if !store.message.isEmpty {
                messageRow
            }

            Divider()

            HStack(spacing: 8) {
                Button(action: openManager) {
                    Label("Open Manager", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: quit) {
                    Label("Quit", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(width: 326)
        .background(LiquidGlassBackground(themeMode: store.themeMode))
        .preferredColorScheme(store.themeMode.colorScheme)
        .tint(store.themeMode.accent)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.badge.key.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(store.themeMode.accent)
                .frame(width: 30, height: 30)
                .liquidGlass(cornerRadius: 7, tint: store.themeMode.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Accounts")
                    .font(.system(size: 14, weight: .semibold))
                Text(activeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                store.setThemeMode(store.themeMode == .dark ? .light : .dark)
            } label: {
                Image(systemName: store.themeMode.systemImage)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Switch theme")

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(store.isWorking)
            .help("Refresh accounts")
        }
    }

    private var accountList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(savedRows) { row in
                    Button {
                        state.selectedProfileID = row.id
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: row.id == state.selectedProfileID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(row.id == state.selectedProfileID ? Color.accentColor : .secondary)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(row.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 6)

                            if row.isActive {
                                Text("Active")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.ultraThinMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .stroke(Color.green.opacity(0.22), lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(row.id == state.selectedProfileID ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.04))
                                )
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(row.id == state.selectedProfileID ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        state.hoveredProfileID = isHovering ? row.id : nil
                    }
                }
            }
        }
        .frame(maxHeight: 230)
    }

    private var switchButton: some View {
        Button(action: switchProfile) {
            Label(switchTitle, systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canSwitch)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No saved accounts")
                .font(.system(size: 13, weight: .semibold))
            Text("Open the manager to capture the current Codex account first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 8, tint: store.themeMode.accent)
    }

    private var messageRow: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: messageColor == .red ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(messageColor)
            Text(menuMessageText)
                .font(.caption)
                .foregroundStyle(messageColor)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .liquidGlass(cornerRadius: 8, tint: messageColor)
    }

    private var savedRows: [ProfileRow] {
        store.rows.filter { !$0.isCurrentAuth }
    }

    private var selectedRow: ProfileRow? {
        savedRows.first { $0.id == state.selectedProfileID }
    }

    private var activeText: String {
        if let active = savedRows.first(where: { $0.id == store.activeProfile }) {
            return "Active: \(active.displayName)"
        }
        return "No active account"
    }

    private var switchTitle: String {
        guard let selectedRow else { return "Switch" }
        return selectedRow.isActive ? "Already Active" : "Switch to \(selectedRow.displayName)"
    }

    private var canSwitch: Bool {
        guard let selectedRow else { return false }
        return !store.isWorking && !selectedRow.isActive
    }

    private var usageProfileID: String {
        if let hoveredProfileID = state.hoveredProfileID {
            return hoveredProfileID
        }
        if !state.selectedProfileID.isEmpty {
            return state.selectedProfileID
        }
        if !store.activeProfile.isEmpty {
            return store.activeProfile
        }
        return currentSelection
    }

    private var usageProfileName: String {
        if let row = savedRows.first(where: { $0.id == usageProfileID }) {
            return row.displayName
        }
        return usageProfileID == currentSelection ? "Current Codex" : usageProfileID
    }

    private var messageColor: Color {
        let lower = store.message.lowercased()
        if lower.contains("failed") || lower.contains("error") || lower.contains("cannot") {
            return .red
        }
        if lower.contains("saved") || lower.contains("captured") || lower.contains("switched") || lower.contains("copied") {
            return .green
        }
        return .secondary
    }

    private var menuMessageText: String {
        let trimmed = store.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("Starting local login server") {
            return "Login started. Continue in the browser, then return here."
        }
        return trimmed
    }
}

private struct MenuBarUsageView: View {
    let snapshot: CodexUsageSnapshot
    let profileName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                Text("Codex Usage")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(profileName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            MenuBarUsageMeterRow(
                title: "Context",
                leftPercent: snapshot.contextLeftPercent,
                detail: "\(compactNumber(snapshot.contextUsed))/\(compactNumber(snapshot.contextWindow))"
            )

            MenuBarUsageMeterRow(
                title: "5h",
                leftPercent: snapshot.primaryLimit?.leftPercent,
                detail: resetText(for: snapshot.primaryLimit)
            )

            MenuBarUsageMeterRow(
                title: "7d",
                leftPercent: snapshot.secondaryLimit?.leftPercent,
                detail: resetText(for: snapshot.secondaryLimit)
            )
        }
        .padding(10)
        .liquidGlass(cornerRadius: 8, tint: Color.accentColor)
    }

    private func resetText(for limit: UsageLimitWindow?) -> String {
        guard let limit, let resetAt = limit.resetAt else { return "No data" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: resetAt, relativeTo: Date())
    }

    private func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 {
            return "\(value / 1_000_000)M"
        }
        if value >= 1000 {
            return "\(value / 1000)K"
        }
        return "\(value)"
    }
}

private struct MenuBarUsageMeterRow: View {
    let title: String
    let leftPercent: Double?
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)

            GeometryReader { proxy in
                let progress = max(0, min(1, (leftPercent ?? 0) / 100))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .separatorColor).opacity(0.32))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(leftPercent == nil ? Color.secondary.opacity(0.25) : Color.accentColor.opacity(0.78))
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 9)

            VStack(alignment: .trailing, spacing: 1) {
                Text(leftText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(leftPercent == nil ? .secondary : .primary)
                Text(detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 76, alignment: .trailing)
        }
    }

    private var leftText: String {
        guard let leftPercent else { return "--%" }
        return "\(Int(leftPercent.rounded()))%"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = AccountStore()
    private let menuBarState = MenuBarState()
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("applicationDidFinishLaunching")
        ProcessInfo.processInfo.disableAutomaticTermination("Codex Account Switcher stays available from the menu bar.")
        NSApp.setActivationPolicy(.regular)
        setupStatusItem()
        setupStatusPopover()
        setupMainMenu()
        refreshMenuBarAccounts()
        DispatchQueue.main.async {
            self.showManager()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        debugLog("applicationShouldHandleReopen visible=\(flag)")
        showManager()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
            button.target = self
            button.action = #selector(toggleStatusPopover)
        }
        statusItem = item
    }

    private func setupStatusPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 326, height: 540)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarSwitcherView(
                store: store,
                state: menuBarState,
                openManager: { [weak self] in
                    self?.closeStatusPopover()
                    self?.showManager()
                },
                refresh: { [weak self] in
                    self?.refreshMenuBarAccounts()
                },
                switchProfile: { [weak self] in
                    self?.switchSelectedMenuBarProfile()
                },
                quit: { [weak self] in
                    self?.closeStatusPopover()
                    self?.quit()
                }
            )
        )
        statusPopover = popover
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

    private func refreshMenuBarAccounts() {
        store.reload(refreshUsage: false)
        let savedRows = store.rows.filter { !$0.isCurrentAuth }
        let selectedIsValid = savedRows.contains { $0.id == menuBarState.selectedProfileID }
        if !selectedIsValid {
            if savedRows.contains(where: { $0.id == store.activeProfile }) {
                menuBarState.selectedProfileID = store.activeProfile
            } else {
                menuBarState.selectedProfileID = savedRows.first?.id ?? ""
            }
        }
        statusItem?.button?.toolTip = store.activeProfile.isEmpty ? "Codex Accounts" : "Active: \(store.activeProfile)"
    }

    @objc private func openManager() {
        showManager()
    }

    @objc private func toggleStatusPopover() {
        guard let button = statusItem?.button, let statusPopover else { return }
        if statusPopover.isShown {
            closeStatusPopover()
            return
        }
        refreshMenuBarAccounts()
        statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startPopoverEventMonitoring()
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

    private func switchSelectedMenuBarProfile() {
        let profile = menuBarState.selectedProfileID
        guard !profile.isEmpty, profile != store.activeProfile else { return }
        store.selectedID = profile
        store.loadSelected()
        store.switchSelected()
    }

    private func closeStatusPopover() {
        statusPopover?.performClose(nil)
        stopPopoverEventMonitoring()
    }

    private func startPopoverEventMonitoring() {
        stopPopoverEventMonitoring()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.statusPopover?.isShown == true else { return event }
            let popoverWindow = self.statusPopover?.contentViewController?.view.window
            let statusButtonWindow = self.statusItem?.button?.window
            if event.window !== popoverWindow && event.window !== statusButtonWindow {
                self.closeStatusPopover()
            }
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeStatusPopover()
        }
    }

    private func stopPopoverEventMonitoring() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopPopoverEventMonitoring()
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
