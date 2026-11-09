import AppKit
import CryptoKit
import ServiceManagement

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
    static func load() -> [Account] {
        let fallback = [Account(label:"Claude Code", badge:nil, configDir:nil)]
        guard let data = try? Data(contentsOf: configURL),
              let accounts = try? JSONDecoder().decode([Account].self, from: data), !accounts.isEmpty else { return fallback }
        return Array(accounts.prefix(4))
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
final class AccountMeter: NSObject {
    let account: Account
    let index: Int
    var item: NSStatusItem!
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
    init(account: Account, index: Int) {
        self.account = account; self.index = index
        super.init()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "ClaudeUsage-\(index)"
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        render()
    }
    @objc func refresh() {
        guard !busy, Date() >= nextCheck else { render(); return }
        busy = true; render()
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
    @objc func forceRefresh() { nextCheck = .distantPast; refresh() }
    func line(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let row = NSMenuItem(title:title, action:action, keyEquivalent:""); row.target = self; return row
    }
    func render() {
        let stale = usage != nil && (issue != nil || (lastSuccess.map { Date().timeIntervalSince($0)>600 } ?? true))
        let countdown = ResetTime.short(usage?.seven_day?.resets_at).map { "·" + $0 } ?? ""
        let prefix = account.badge.map { $0.isEmpty ? "" : "\($0) " } ?? ""
        let title = prefix + (usage?.compact ?? "—/—") + countdown + (stale ? "*" : (issue != nil && !busy ? "!" : ""))
        item.button?.title = title
        item.button?.setAccessibilityLabel("Claude usage, \(account.label): \(title)")
        item.button?.toolTip = issue ?? "Claude usage (\(account.label)) — 5-hour and weekly limits; countdown is until weekly reset"
        let menu = NSMenu()
        menu.addItem(line("Claude usage • \(account.label)"))
        menu.addItem(line("5-hour: \(Usage.percent(usage?.five_hour))   Weekly: \(Usage.percent(usage?.seven_day))"))
        menu.addItem(line("Bar: 5-hour % / weekly % · time to weekly reset · * stale · ! issue"))
        if let issue { menu.addItem(line(issue)) }
        if usage != nil && (usage?.five_hour == nil || usage?.seven_day == nil) { menu.addItem(line("— means this usage window is unavailable.")) }
        let fmt = DateFormatter(); fmt.timeStyle = .short; fmt.dateStyle = .short
        if let date = lastSuccess { menu.addItem(line("Updated: \(fmt.string(from:date))")) }
        for (label,window) in [("5h",usage?.five_hour),("Week",usage?.seven_day)] {
            if let date = ResetTime.date(window?.resets_at), let remaining = ResetTime.remaining(window?.resets_at) {
                menu.addItem(line("\(label) resets in \(remaining) — \(fmt.string(from:date))"))
            } else { menu.addItem(line("\(label) reset time unavailable")) }
        }
        menu.addItem(.separator())
        let refreshItem = line(busy ? "Refreshing…" : "Refresh", action:#selector(refresh))
        refreshItem.isEnabled = !busy && Date() >= nextCheck; menu.autoenablesItems = false; menu.addItem(refreshItem)
        if nextCheck == .distantFuture { menu.addItem(line("Retry Keychain Access",action:#selector(retryKeychain))) }
        else if nextCheck > Date() { menu.addItem(line("Next check: \(fmt.string(from:nextCheck))")) }
        menu.addItem(line("Open Claude Usage Settings",action:#selector(openUsage)))
        menu.addItem(.separator()); menu.addItem(line("Quit Claude Usage",action:#selector(quit)))
        item.menu = menu
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
        meters = Account.load().enumerated().map { AccountMeter(account:$1, index:$0) }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        refreshAll()
    }
    @objc func wake() { refreshAll() }
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
    print("Usage parsing, reset countdown and account naming checks passed")
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
