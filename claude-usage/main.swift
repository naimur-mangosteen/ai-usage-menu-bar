import AppKit
import CryptoKit
import ServiceManagement
import UserNotifications

enum ResetTime {
    static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let seconds = Double(raw), seconds.isFinite { return Date(timeIntervalSince1970:seconds) }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from:raw) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from:raw)
    }
    /// At most three characters for the menu bar: days from 2 days out, then hours, then minutes.
    static func short(_ raw: String?, now: Date = Date()) -> String? {
        guard let date = date(raw) else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "due" }
        let hours = Int(min(seconds / 3600, 876000))
        if hours >= 48 { return "\(hours / 24)d" }
        if hours >= 1 { return "\(hours)h" }
        return "\(Int(ceil(seconds / 60)))m"
    }
    static func remaining(_ raw: String?, now: Date = Date()) -> String? {
        guard let date = date(raw) else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "due" }
        let hours = Int(min(seconds / 3600, 876000))
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}
struct WindowUsage: Decodable {
    let utilization: Double
    let resets_at: String?
}
struct Usage: Decodable {
    let five_hour: WindowUsage?
    let seven_day: WindowUsage?
    static func decode(_ data: Data) throws -> Usage {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard obj?.keys.contains("five_hour") == true, obj?.keys.contains("seven_day") == true else { throw MeterError.schema }
        let usage = try JSONDecoder().decode(Usage.self, from: data)
        for value in [usage.five_hour, usage.seven_day].compactMap({ $0?.utilization }) {
            guard value.isFinite, (0...100).contains(value) else { throw MeterError.schema }
        }
        return usage
    }
    /// Menu-bar form: five-hour/weekly percent, e.g. "21/74"; — marks an unavailable window.
    var compact: String { "\(Self.number(five_hour))/\(Self.number(seven_day))" }
    static func number(_ window: WindowUsage?) -> String { window.map { "\(Int($0.utilization.rounded()))" } ?? "—" }
    static func percent(_ window: WindowUsage?) -> String {
        guard let window else { return "—" }
        return "\(Int(window.utilization.rounded()))%"
    }
}
enum MeterError: Error { case missingLogin, keychainDenied, schema }

/// How close an account is to a limit, from the higher of its two windows. Colors the menu-bar title.
enum Level: Equatable {
    case normal, warn, critical
    static func of(_ usage: Usage?) -> Level {
        let top = [usage?.five_hour?.utilization, usage?.seven_day?.utilization].compactMap { $0 }.max() ?? 0
        return top >= 95 ? .critical : top >= 80 ? .warn : .normal
    }
    var color: NSColor? {
        switch self { case .normal: return nil; case .warn: return .systemOrange; case .critical: return .systemRed }
    }
}

/// Compares usage with how much of the window has passed, so you can tell whether you are on track
/// to use the whole allowance before it resets.
enum Pace {
    static let fiveHour: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86400
    /// Percent of the window that has elapsed, from its reset time and length; nil when unknown.
    static func elapsed(_ window: WindowUsage?, length: TimeInterval, now: Date = Date()) -> Double? {
        guard let reset = ResetTime.date(window?.resets_at) else { return nil }
        let left = reset.timeIntervalSince(now)
        guard left > 0, left <= length else { return nil }
        return (1 - left / length) * 100
    }
    /// e.g. "Week pace: 4% used, 18% elapsed — 14 pts under pace". Within 5 points counts as on pace.
    static func line(_ label: String, _ window: WindowUsage?, length: TimeInterval, now: Date = Date()) -> String? {
        guard let window, let elapsed = elapsed(window, length: length, now: now) else { return nil }
        let gap = Int((elapsed - window.utilization).rounded())
        let state = abs(gap) <= 5 ? "on pace" : gap > 0 ? "\(gap) pts under pace" : "\(-gap) pts over pace"
        return "\(label) pace: \(Int(window.utilization.rounded()))% used, \(Int(elapsed.rounded()))% elapsed — \(state)"
    }
}

/// macOS notifications when a window crosses 80% or 95%. Announced once per threshold per window:
/// the reset time identifies the window, so a new window can alert again.
enum Alerts {
    static let thresholds: [Double] = [80, 95]
    /// The threshold to announce now, or nil. Records it in `defaults` so it is not repeated, even after a restart.
    static func due(_ window: WindowUsage?, key: String, defaults: UserDefaults) -> Double? {
        guard let window, let reset = ResetTime.date(window.resets_at),
              let threshold = thresholds.last(where: { window.utilization >= $0 }) else { return nil }
        let resetMinute = Int(reset.timeIntervalSince1970 / 60)   // ignore sub-minute jitter in resets_at
        let stored = defaults.string(forKey: key)?.split(separator: ":").compactMap { Double($0) } ?? []
        if stored.count == 2, Int(stored[0]) == resetMinute, stored[1] >= threshold { return nil }
        defaults.set("\(resetMinute):\(threshold)", forKey: key)
        return threshold
    }
    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// One Claude Code login to monitor. `configDir` nil means the default ~/.claude login.
struct Account: Decodable {
    let label: String
    let badge: String?
    let configDir: String?
    var expandedConfigDir: String? {
        guard let configDir, !configDir.isEmpty else { return nil }
        return (configDir as NSString).expandingTildeInPath
    }
    /// Same naming rule Claude Code uses: "Claude Code-credentials" plus, when CLAUDE_CONFIG_DIR is set,
    /// "-" and the first 8 hex digits of SHA-256 of that directory path.
    var keychainService: String { Self.service(forConfigDir: expandedConfigDir) }
    static func service(forConfigDir dir: String?) -> String {
        guard let dir else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8))
        return "Claude Code-credentials-" + digest.map { String(format:"%02x",$0) }.joined().prefix(8)
    }
    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude Usage/accounts.json")
    /// Accounts to show, plus a warning for the menu when accounts.json exists but can't be used as written.
    static func load() -> (accounts: [Account], warning: String?) {
        parse(FileManager.default.fileExists(atPath: configURL.path) ? (try? Data(contentsOf: configURL)) ?? Data() : nil)
    }
    static func parse(_ data: Data?) -> (accounts: [Account], warning: String?) {
        let fallback = [Account(label:"Claude Code", badge:nil, configDir:nil)]
        guard let data else { return (fallback, nil) }   // no accounts.json: the default login, no warning
        guard let accounts = try? JSONDecoder().decode([Account].self, from: data), !accounts.isEmpty else {
            return (fallback, "accounts.json is invalid or empty — showing the default login.")
        }
        return (Array(accounts.prefix(4)), accounts.count > 4 ? "accounts.json lists \(accounts.count) accounts — showing the first 4." : nil)
    }
}

struct Credential: Decodable {
    struct OAuth: Decodable {
        let accessToken: String
        let expiresAt: Double?
        var expiresSoon: Bool { expiresAt.map { $0 <= Date().timeIntervalSince1970*1000+60_000 } ?? false }
    }
    let claudeAiOauth: OAuth
    /// Reads through /usr/bin/security, the same trusted tool Claude Code uses to read and write this item.
    /// Claude Code rewrites the item on every token refresh, which resets its partition list to `apple-tool:`;
    /// reading it directly with SecItemCopyMatching therefore re-prompted after each refresh.
    /// The secret only travels over this process's stdout pipe; it is never logged or put in arguments.
    static func read(service: String) throws -> OAuth {
        let process = Process()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw MeterError.keychainDenied }
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if process.terminationStatus == 44 { throw MeterError.missingLogin }   // errSecItemNotFound
        guard process.terminationStatus == 0 else { throw MeterError.keychainDenied }
        guard let data = decodeSecret(output),
              let credential = try? JSONDecoder().decode(Credential.self, from: data),
              !credential.claudeAiOauth.accessToken.isEmpty else { throw MeterError.missingLogin }
        return credential.claudeAiOauth
    }
    /// `security -w` prints printable data as-is and anything else as hex.
    static func decodeSecret(_ raw: Data) -> Data? {
        guard var text = String(data: raw, encoding: .utf8) else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") { return Data(text.utf8) }
        guard text.count % 2 == 0, text.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        return Data(bytes)
    }
}
enum NativeRenewal {
    static func run(configDir: String?) -> Bool {
        guard let script = Bundle.main.path(forResource:"renew_login",ofType:"py") else { return false }
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments = [script]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        if let configDir { env["CLAUDE_CONFIG_DIR"] = configDir } else { env.removeValue(forKey:"CLAUDE_CONFIG_DIR") }
        process.environment = env
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
    }
}
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// One menu-bar item for one Claude Code login.
@MainActor
final class AccountMeter: NSObject, NSMenuDelegate {
    /// Minimum gap between manual refreshes, so the Refresh button can't hammer the usage API.
    nonisolated static let manualRefreshGap: TimeInterval = 30
    static let titleFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    let account: Account
    let index: Int
    let configWarning: String?
    var item: NSStatusItem!
    var lastAttempt: Date?
    var usage: Usage?
    var lastSuccess: Date?
    var nextCheck = Date.distantPast
    var issue: String? = "Loading usage…"
    var busy = false
    var failures = 0
    var previousToken: String?
    var lastCode: Int?
    let delegate = NoRedirect()
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    init(account: Account, index: Int, configWarning: String? = nil) {
        self.account = account; self.index = index; self.configWarning = configWarning
        super.init()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "ClaudeUsage-\(index)"
        item.button?.font = Self.titleFont
        // Built in menuNeedsUpdate each time it opens, so the countdowns are current while you read them.
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        item.menu = menu
        render()
    }
    @objc func refresh() {
        guard !busy, Date() >= nextCheck else { render(); return }
        busy = true; lastAttempt = Date(); render()
        let service = account.keychainService, configDir = account.expandedConfigDir
        Task {
            do {
                var credential = try await Task.detached { try Credential.read(service: service) }.value
                var renewed = false
                if credential.expiresSoon {
                    issue = "Renewing Claude login…"; render()
                    renewed = true
                    _ = await Task.detached { NativeRenewal.run(configDir: configDir) }.value
                    credential = try await Task.detached { try Credential.read(service: service) }.value
                }
                var token = credential.accessToken
                if previousToken != token { usage = nil; lastSuccess = nil; previousToken = token }
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                var (data, response) = try await session.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 401 {
                    // Reload first: another Claude Code process may have just rotated the token.
                    if !renewed {
                        issue = "Renewing Claude login…"; render()
                        _ = await Task.detached { NativeRenewal.run(configDir: configDir) }.value
                    }
                    token = try await Task.detached { try Credential.read(service: service).accessToken }.value
                    previousToken = token
                    request.setValue("Bearer \(token)", forHTTPHeaderField:"Authorization")
                    (data, response) = try await session.data(for:request)
                }
                let http = response as? HTTPURLResponse
                lastCode = http?.statusCode
                if http?.statusCode == 200 {
                    usage = try Usage.decode(data); lastSuccess = Date(); issue = nil; failures = 0
                    nextCheck = Date().addingTimeInterval(300)
                    announceThresholds()
                } else {
                    failures += 1
                    nextCheck = Date().addingTimeInterval(max(backoff(), retryAfter(http?.value(forHTTPHeaderField: "Retry-After"))))
                    switch http?.statusCode {
                    case 401: usage = nil; lastSuccess = nil; issue = "Login could not be renewed. Sign in to Claude Code again."
                    case 403: usage = nil; lastSuccess = nil; issue = "Usage access denied. Check Claude Code subscription login."
                    case 429: issue = "Rate limited — waiting before retrying."
                    case 404: issue = "Usage endpoint unavailable."
                    default: issue = "Usage service unavailable — retrying automatically."
                    }
                }
            } catch MeterError.missingLogin {
                usage = nil; lastSuccess = nil; nextCheck = Date().addingTimeInterval(300)
                issue = configDir == nil ? "No Claude Code login found. Run: claude auth login"
                                         : "Not signed in. Run: CLAUDE_CONFIG_DIR=\(account.configDir ?? "") claude auth login"
            } catch MeterError.keychainDenied {
                usage = nil; lastSuccess = nil; issue = "Keychain access denied. Choose Retry Keychain Access below."; nextCheck = .distantFuture
            } catch MeterError.schema {
                issue = "Usage response format changed."; nextCheck = Date().addingTimeInterval(3600)
            } catch {
                failures += 1; issue = "Could not refresh — check your connection."; nextCheck = Date().addingTimeInterval(backoff())
            }
            busy = false; render()
        }
    }
    func backoff() -> Double { min(3600, 300 * pow(2, Double(min(max(failures-1,0),4)))) }
    func retryAfter(_ raw: String?) -> Double {
        guard let raw else { return 0 }
        if let seconds = Double(raw), seconds.isFinite { return max(0, seconds)+60 }
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT:0); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from:raw).map { max(0,$0.timeIntervalSinceNow)+60 } ?? 0
    }
    @objc func retryKeychain() { nextCheck = .distantPast; refresh() }
    /// Manual Refresh. It used to share the 5-minute schedule, so the item stayed disabled almost all the time.
    @objc func forceRefresh() {
        guard Self.canForceRefresh(busy: busy, lastAttempt: lastAttempt, rateLimitedUntil: rateLimitedUntil) else { render(); return }
        nextCheck = .distantPast; refresh()
    }
    /// Set only while a 429 / Retry-After is in force; a manual refresh must not cut that short.
    var rateLimitedUntil: Date? { lastCode == 429 && nextCheck > Date() ? nextCheck : nil }
    nonisolated static func canForceRefresh(busy: Bool, lastAttempt: Date?, rateLimitedUntil: Date?, now: Date = Date()) -> Bool {
        guard !busy, rateLimitedUntil == nil else { return false }
        return lastAttempt.map { now.timeIntervalSince($0) >= manualRefreshGap } ?? true
    }
    func announceThresholds() {
        for (key, label, window) in [("5h", "5-hour", usage?.five_hour), ("week", "Weekly", usage?.seven_day)] {
            guard let threshold = Alerts.due(window, key: "alert.\(index).\(key)", defaults: .standard) else { continue }
            let reset = ResetTime.remaining(window?.resets_at).map { " Resets in \($0)." } ?? ""
            Alerts.post(title: "Claude \(label) limit at \(Int(threshold))%",
                        body: "\(account.label): \(Usage.percent(window)) used.\(reset)")
        }
    }
    func line(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let row = NSMenuItem(title:title, action:action, keyEquivalent:""); row.target = self; return row
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(line("Claude usage • \(account.label)"))
        menu.addItem(line("5-hour: \(Usage.percent(usage?.five_hour))   Weekly: \(Usage.percent(usage?.seven_day))"))
        if let configWarning { menu.addItem(line(configWarning)) }
        if let issue { menu.addItem(line(issue)) }
        if usage != nil && (usage?.five_hour == nil || usage?.seven_day == nil) { menu.addItem(line("— means this usage window is unavailable.")) }
        let fmt = DateFormatter(); fmt.timeStyle = .short; fmt.dateStyle = .short
        if let date = lastSuccess { menu.addItem(line("Updated: \(fmt.string(from:date))")) }
        for (label,window) in [("5h",usage?.five_hour),("Week",usage?.seven_day)] {
            if let date = ResetTime.date(window?.resets_at), let remaining = ResetTime.remaining(window?.resets_at) {
                menu.addItem(line("\(label) resets in \(remaining) — \(fmt.string(from:date))"))
            } else { menu.addItem(line("\(label) reset time unavailable")) }
        }
        let paces = [Pace.line("5h", usage?.five_hour, length: Pace.fiveHour), Pace.line("Week", usage?.seven_day, length: Pace.week)].compactMap { $0 }
        if !paces.isEmpty { menu.addItem(.separator()); paces.forEach { menu.addItem(line($0)) } }
        menu.addItem(.separator())
        let refreshItem = line(busy ? "Refreshing…" : "Refresh", action:#selector(forceRefresh))
        refreshItem.isEnabled = Self.canForceRefresh(busy: busy, lastAttempt: lastAttempt, rateLimitedUntil: rateLimitedUntil)
        menu.addItem(refreshItem)
        if nextCheck == .distantFuture { menu.addItem(line("Retry Keychain Access",action:#selector(retryKeychain))) }
        else if nextCheck > Date() { menu.addItem(line("Next check: \(fmt.string(from:nextCheck))")) }
        menu.addItem(line("Open Claude Usage Settings",action:#selector(openUsage)))
        menu.addItem(.separator()); menu.addItem(line("Quit Claude Usage",action:#selector(quit)))
    }
    func render() {
        let stale = usage != nil && (issue != nil || (lastSuccess.map { Date().timeIntervalSince($0)>600 } ?? true))
        let countdown = ResetTime.short(usage?.seven_day?.resets_at).map { "·" + $0 } ?? ""
        let prefix = account.badge.map { $0.isEmpty ? "" : "\($0) " } ?? ""
        let title = prefix + (usage?.compact ?? "—/—") + countdown + (stale ? "*" : (issue != nil && !busy ? "!" : ""))
        let level = Level.of(usage)
        var attributes: [NSAttributedString.Key: Any] = [.font: Self.titleFont]
        if let color = level.color { attributes[.foregroundColor] = color }
        item.button?.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        let levelWord = level == .critical ? ", near limit" : level == .warn ? ", above 80%" : ""
        item.button?.setAccessibilityLabel("Claude usage, \(account.label): \(title)\(levelWord)")
        item.button?.toolTip = (issue.map { $0 + "\n" } ?? "")
            + "Claude usage (\(account.label)): 5-hour % / weekly % · time to weekly reset · * stale · ! issue"
            + (configWarning.map { "\n" + $0 } ?? "")
        // Local verification receipt contains only display state; never credentials or response bodies.
        if let path = ProcessInfo.processInfo.environment["CLAUDE_METER_DIAGNOSTICS"] {
            let record: [String:Any] = ["account":account.label,"title":title,"status":issue ?? "ok","httpStatus":lastCode ?? 0,"updated":lastSuccess?.description ?? "never","busy":busy,"statusItemVisible":item.isVisible,"buttonWindowVisible":item.button?.window?.isVisible ?? false]
            let url = URL(fileURLWithPath:path + (index == 0 ? "" : ".\(index)"))
            if let data = try? JSONSerialization.data(withJSONObject:record,options:.sortedKeys) { try? data.write(to:url,options:.atomic) }
        }
    }
    @objc func openUsage() { NSWorkspace.shared.open(URL(string:"https://claude.ai/settings/usage")!) }
    @objc func quit() { NSApp.terminate(nil) }
}

@MainActor
final class Meter: NSObject, NSApplicationDelegate {
    var meters: [AccountMeter] = []
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let (accounts, warning) = Account.load()
        meters = accounts.enumerated().map { AccountMeter(account:$1, index:$0, configWarning: warning) }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        refreshAll()
    }
    /// Wait for the network after wake: refreshing at once usually failed, showed "!" and started a 5-minute backoff.
    @objc func wake() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            self?.refreshAll()
        }
    }
    func refreshAll() { meters.forEach { $0.refresh() } }
}

if CommandLine.arguments.contains("--enable-login") {
    do {
        try SMAppService.mainApp.register()
        print("Login status: \(SMAppService.mainApp.status.rawValue)")
        if SMAppService.mainApp.status != .enabled { exit(2) }
    } catch { print("Login registration failed: \(error.localizedDescription)"); exit(1) }
} else if CommandLine.arguments.contains("--login-status") {
    print("Login status: \(SMAppService.mainApp.status.rawValue)")
    if SMAppService.mainApp.status != .enabled { exit(2) }
} else if CommandLine.arguments.contains("--self-test") {
    func check(_ value: Bool) { if !value { fatalError("Self-test failed") } }
    let valid = try Usage.decode(Data(#"{"five_hour":{"utilization":25.2},"seven_day":{"utilization":15}}"#.utf8))
    check(valid.compact == "25/15")
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    check(ResetTime.short(String(1_000_000 + 5*86400 + 19*3600),now:t0) == "5d")
    check(ResetTime.short(String(1_000_000 + 39*3600 + 59*60),now:t0) == "39h")
    check(ResetTime.short(String(1_000_000 + 40*60),now:t0) == "40m")
    let missing = try Usage.decode(Data(#"{"five_hour":null,"seven_day":null}"#.utf8))
    check(missing.compact == "—/—")
    for value in [#"{}"#, #"{"five_hour":{"utilization":101},"seven_day":null}"#, #"{"five_hour":{"utilization":-1},"seven_day":null}"#] {
        do { _ = try Usage.decode(Data(value.utf8)); fatalError("Invalid payload accepted") } catch {}
    }
    let now = Date(timeIntervalSince1970: 1_000_000)
    check(ResetTime.remaining(String(1_000_000 + 2*86400 + 3*3600),now:now) == "2d 3h")
    check(ResetTime.remaining(String(1_000_000 + 90*60),now:now) == "1h 30m")
    check(ResetTime.remaining("999999",now:now) == "due")
    check(ResetTime.remaining(nil,now:now) == nil)
    check(ResetTime.date("2026-10-18T14:00:00.000Z") == ResetTime.date("2026-10-18T14:00:00Z"))
    // Keychain service naming must match Claude Code's rule.
    check(Account.service(forConfigDir:nil) == "Claude Code-credentials")
    check(Account.service(forConfigDir:"/Users/alex/.claude-work") == "Claude Code-credentials-c381b4cb")
    check(Credential.decodeSecret(Data("{\"a\":1}\n".utf8)) == Data("{\"a\":1}".utf8))
    check(Credential.decodeSecret(Data("7b7d\n".utf8)) == Data("{}".utf8))
    // Manual refresh: allowed when idle, throttled for 30 s, never during a 429 back-off.
    check(AccountMeter.canForceRefresh(busy:false, lastAttempt:nil, rateLimitedUntil:nil, now:now))
    check(!AccountMeter.canForceRefresh(busy:true, lastAttempt:nil, rateLimitedUntil:nil, now:now))
    check(!AccountMeter.canForceRefresh(busy:false, lastAttempt:now.addingTimeInterval(-10), rateLimitedUntil:nil, now:now))
    check(AccountMeter.canForceRefresh(busy:false, lastAttempt:now.addingTimeInterval(-31), rateLimitedUntil:nil, now:now))
    check(!AccountMeter.canForceRefresh(busy:false, lastAttempt:nil, rateLimitedUntil:now.addingTimeInterval(60), now:now))
    // Level colors from the higher window.
    func usage(_ a: Double, _ b: Double) -> Usage { try! Usage.decode(Data(#"{"five_hour":{"utilization":\#(a)},"seven_day":{"utilization":\#(b)}}"#.utf8)) }
    check(Level.of(usage(10, 79)) == .normal && Level.of(usage(80, 5)) == .warn && Level.of(usage(3, 95)) == .critical && Level.of(nil) == .normal)
    // Pace: 1 day into the week with 4% used is 10 pts under; 1 h left of 5 h at 80% is on pace.
    let weekReset = String(1_000_000 + 6*86400)
    check(Pace.line("Week", WindowUsage(utilization:4, resets_at:weekReset), length:Pace.week, now:now) == "Week pace: 4% used, 14% elapsed — 10 pts under pace")
    check(Pace.line("5h", WindowUsage(utilization:80, resets_at:String(1_000_000 + 3600)), length:Pace.fiveHour, now:now) == "5h pace: 80% used, 80% elapsed — on pace")
    check(Pace.line("5h", WindowUsage(utilization:90, resets_at:String(1_000_000 + 4*3600)), length:Pace.fiveHour, now:now) == "5h pace: 90% used, 20% elapsed — 70 pts over pace")
    check(Pace.line("5h", WindowUsage(utilization:1, resets_at:nil), length:Pace.fiveHour, now:now) == nil)
    // Alerts: once per threshold per window, again for a new window.
    let suite = "local.claude.usage.selftest.\(ProcessInfo.processInfo.processIdentifier)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    check(Alerts.due(WindowUsage(utilization:50, resets_at:weekReset), key:"k", defaults:defaults) == nil)
    check(Alerts.due(WindowUsage(utilization:82, resets_at:weekReset), key:"k", defaults:defaults) == 80)
    check(Alerts.due(WindowUsage(utilization:85, resets_at:weekReset), key:"k", defaults:defaults) == nil)
    check(Alerts.due(WindowUsage(utilization:96, resets_at:weekReset), key:"k", defaults:defaults) == 95)
    check(Alerts.due(WindowUsage(utilization:99, resets_at:weekReset), key:"k", defaults:defaults) == nil)
    check(Alerts.due(WindowUsage(utilization:81, resets_at:String(1_000_000 + 13*86400)), key:"k", defaults:defaults) == 80)
    // accounts.json: missing is silent, broken or too long warns.
    check(Account.parse(nil).warning == nil && Account.parse(nil).accounts.count == 1)
    check(Account.parse(Data("{oops".utf8)).warning != nil && Account.parse(Data("[]".utf8)).warning != nil)
    let five = Data(#"[{"label":"a"},{"label":"b"},{"label":"c"},{"label":"d"},{"label":"e"}]"#.utf8)
    check(Account.parse(five).accounts.count == 4 && Account.parse(five).warning != nil)
    print("Usage parsing, reset countdown, account naming, refresh, pace and alert checks passed")
} else {
    MainActor.assumeIsolated {
    let id = Bundle.main.bundleIdentifier ?? "local.claude.usage.companion"
    if NSRunningApplication.runningApplications(withBundleIdentifier:id).contains(where: {$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}) { exit(0) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = Meter()
    app.delegate = delegate
    app.run()
    }
}
