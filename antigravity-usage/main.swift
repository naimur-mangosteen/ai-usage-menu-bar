import AppKit
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
/// One Antigravity quota group, e.g. "Gemini Models" or "Claude and GPT models".
struct QuotaGroup: Decodable {
    let name: String
    let five_hour: WindowUsage?
    let seven_day: WindowUsage?
}
struct Usage: Decodable {
    let groups: [QuotaGroup]
    static func decode(_ data: Data) throws -> Usage {
        guard let usage = try? JSONDecoder().decode(Usage.self, from: data), !usage.groups.isEmpty else { throw MeterError.schema }
        for value in usage.groups.flatMap({ [$0.five_hour, $0.seven_day] }).compactMap({ $0?.utilization }) {
            guard value.isFinite, (0...100).contains(value) else { throw MeterError.schema }
        }
        return usage
    }
    /// The most-used window across groups: any exhausted group blocks its models, so the bar shows the worst one.
    static func worst(_ windows: [WindowUsage?]) -> WindowUsage? { windows.compactMap { $0 }.max { $0.utilization < $1.utilization } }
    var fiveHour: WindowUsage? { Self.worst(groups.map(\.five_hour)) }
    var weekly: WindowUsage? { Self.worst(groups.map(\.seven_day)) }
    /// Menu-bar form: five-hour/weekly percent, e.g. "31/72"; — marks an unavailable window.
    var compact: String { "\(Self.number(fiveHour))/\(Self.number(weekly))" }
    static func number(_ window: WindowUsage?) -> String { window.map { "\(Int($0.utilization.rounded()))" } ?? "—" }
    static func percent(_ window: WindowUsage?) -> String {
        guard let window else { return "—" }
        return "\(Int(window.utilization.rounded()))%"
    }
}
enum MeterError: Error { case schema; case service(String); case halt(String) }
struct AntigravityReader {
    /// Helper exit code meaning agy ran /usage as a model turn; polling must stop.
    static let haltCode: Int32 = 3
    static func read() throws -> Usage {
        guard let script = Bundle.main.path(forResource:"read_usage", ofType:"py") else { throw MeterError.service("Usage helper missing. Rebuild the app.") }
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments = ["-I", script]; process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        // Watchdog: the helper allows agy 80 s at most; past that, stop it (it kills agy's process group on SIGTERM).
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if process.terminationStatus != 0 {
            let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any]
            let message = object?["error"] as? String ?? "Could not read Antigravity usage."
            throw process.terminationStatus == haltCode ? MeterError.halt(message) : MeterError.service(message)
        }
        return try Usage.decode(data)
    }
}
@MainActor
final class Meter: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Minimum gap between manual refreshes; each one starts an agy process.
    nonisolated static let manualRefreshGap: TimeInterval = 30
    nonisolated static let wakeDelay: TimeInterval = 10
    var item: NSStatusItem!
    var timer: Timer?
    var usage: Usage?
    var lastSuccess: Date?
    var lastAttempt: Date?
    var nextCheck = Date.distantPast
    var issue: String? = "Loading usage…"
    var busy = false
    /// Saved, so a halt survives Quit, reinstall and login: relaunching must not spend another turn.
    nonisolated static let haltKey = "haltReason"
    var halted: Bool { UserDefaults.standard.string(forKey: Self.haltKey) != nil }
    var failures = 0
    var holdUntil: Date?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let reason = UserDefaults.standard.string(forKey: Self.haltKey) { issue = reason; nextCheck = .distantFuture }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false; item.menu = menu
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduledRefresh() }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
    }
    /// Scheduled checks pause from sleep until shortly after wake, when the network is usually back.
    @objc func willSleep() { holdUntil = .distantFuture }
    @objc func wake() { holdUntil = Date().addingTimeInterval(Self.wakeDelay) }
    func scheduledRefresh() { if !(holdUntil.map { Date() < $0 } ?? false) { refresh() } }
    func refresh() {
        guard !busy, !halted, Date() >= nextCheck else { render(); return }
        busy = true; lastAttempt = Date(); render()
        Task {
            do {
                usage = try await Task.detached { try AntigravityReader.read() }.value
                lastSuccess = Date(); issue = nil; failures = 0; nextCheck = Date().addingTimeInterval(300)
            } catch MeterError.halt(let message) {
                UserDefaults.standard.set(message, forKey: Self.haltKey); issue = message; nextCheck = .distantFuture
            } catch MeterError.service(let message) {
                usage = nil; lastSuccess = nil; issue = message; failures += 1
                nextCheck = Date().addingTimeInterval(backoff())
            } catch MeterError.schema {
                issue = "Usage response format changed."; nextCheck = Date().addingTimeInterval(3600)
            } catch {
                failures += 1; issue = "Could not refresh Antigravity usage."; nextCheck = Date().addingTimeInterval(backoff())
            }
            busy = false; render()
        }
    }
    func backoff() -> Double { min(3600, 300 * pow(2, Double(min(max(failures-1,0),4)))) }
    nonisolated static func canForceRefresh(busy: Bool, halted: Bool, lastAttempt: Date?, now: Date = Date()) -> Bool {
        guard !busy, !halted else { return false }
        return lastAttempt.map { now.timeIntervalSince($0) >= manualRefreshGap } ?? true
    }
    @objc func forceRefresh() {
        guard Self.canForceRefresh(busy: busy, halted: halted, lastAttempt: lastAttempt) else { render(); return }
        nextCheck = .distantPast; refresh()
    }
    /// Deliberate retry after a halt, e.g. once agy has been updated.
    @objc func checkAgain() { UserDefaults.standard.removeObject(forKey: Self.haltKey); nextCheck = .distantPast; refresh() }
    func line(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let row = NSMenuItem(title:title, action:action, keyEquivalent:""); row.target = self; return row
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(line("Antigravity usage • agy"))
        if let issue { menu.addItem(line(issue)) }
        let fmt = DateFormatter(); fmt.timeStyle = .short; fmt.dateStyle = .short
        if let date = lastSuccess { menu.addItem(line("Updated: \(fmt.string(from:date))")) }
        for group in usage?.groups ?? [] {
            menu.addItem(.separator())
            menu.addItem(line("\(group.name) — 5-hour: \(Usage.percent(group.five_hour))   Weekly: \(Usage.percent(group.seven_day))"))
            for (label, window) in [("5h", group.five_hour), ("Week", group.seven_day)] {
                if let date = ResetTime.date(window?.resets_at), let remaining = ResetTime.remaining(window?.resets_at) {
                    menu.addItem(line("\(label) resets in \(remaining) — \(fmt.string(from:date))"))
                } else if window != nil { menu.addItem(line("\(label) reset time unavailable")) }
            }
        }
        if usage?.groups.contains(where: { $0.five_hour == nil || $0.seven_day == nil }) == true { menu.addItem(line("— means this usage window is unavailable.")) }
        menu.addItem(.separator())
        if halted { menu.addItem(line("Check Again", action:#selector(checkAgain))) }
        else {
            let refreshItem = line(busy ? "Refreshing…" : "Refresh", action:#selector(forceRefresh))
            refreshItem.isEnabled = Self.canForceRefresh(busy: busy, halted: halted, lastAttempt: lastAttempt)
            menu.addItem(refreshItem)
            if nextCheck > Date() { menu.addItem(line("Next check: \(fmt.string(from:nextCheck))")) }
        }
        menu.addItem(.separator()); menu.addItem(line("Quit Antigravity Usage",action:#selector(quit)))
    }
    func render() {
        let stale = usage != nil && (issue != nil || (lastSuccess.map { Date().timeIntervalSince($0)>600 } ?? true))
        let countdown = ResetTime.short(usage?.weekly?.resets_at).map { "·" + $0 } ?? ""
        let title = "AG " + (usage?.compact ?? "—/—") + countdown + (stale ? "*" : (issue != nil && !busy ? "!" : ""))
        item.button?.title = title
        item.button?.setAccessibilityLabel("Antigravity usage: \(title)")
        item.button?.toolTip = (issue.map { $0 + "\n" } ?? "")
            + "Antigravity usage: most-used group's 5-hour % / weekly % · time to weekly reset · * stale · ! issue"
        // Local verification receipt contains only display state; never credentials or response bodies.
        if let path = ProcessInfo.processInfo.environment["ANTIGRAVITY_METER_DIAGNOSTICS"] {
            let record: [String:Any] = ["title":title,"status":issue ?? "ok","updated":lastSuccess?.description ?? "never","busy":busy,"halted":halted,"statusItemVisible":item.isVisible]
            if let data = try? JSONSerialization.data(withJSONObject:record,options:.sortedKeys) { try? data.write(to:URL(fileURLWithPath:path),options:.atomic) }
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
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
    let sample = #"{"groups":[{"name":"Gemini Models","five_hour":{"utilization":31,"resets_at":"2026-11-12T18:00:00Z"},"seven_day":{"utilization":12.4,"resets_at":"2026-11-16T00:00:00Z"}},{"name":"Claude and GPT models","five_hour":null,"seven_day":{"utilization":72,"resets_at":"2026-11-15T00:00:00Z"}}]}"#
    let usage = try Usage.decode(Data(sample.utf8))
    check(usage.compact == "31/72" && usage.weekly?.resets_at == "2026-11-15T00:00:00Z")
    check(try Usage.decode(Data(#"{"groups":[{"name":"x","five_hour":null,"seven_day":null}]}"#.utf8)).compact == "—/—")
    for value in [#"{}"#, #"{"groups":[]}"#, #"{"groups":[{"name":"x","five_hour":{"utilization":101},"seven_day":null}]}"#] {
        do { _ = try Usage.decode(Data(value.utf8)); fatalError("Invalid payload accepted") } catch {}
    }
    let now = Date(timeIntervalSince1970: 1_000_000)
    check(ResetTime.short(String(1_000_000 + 5*86400 + 19*3600),now:now) == "5d")
    check(ResetTime.remaining(String(1_000_000 + 90*60),now:now) == "1h 30m")
    check(Meter.canForceRefresh(busy:false, halted:false, lastAttempt:nil, now:now))
    check(!Meter.canForceRefresh(busy:false, halted:true, lastAttempt:nil, now:now))
    check(!Meter.canForceRefresh(busy:false, halted:false, lastAttempt:now.addingTimeInterval(-10), now:now))
    check(Meter.canForceRefresh(busy:false, halted:false, lastAttempt:now.addingTimeInterval(-31), now:now))
    // The bundled helper's own parser tests (no agy needed).
    guard let script = Bundle.main.path(forResource:"read_usage", ofType:"py") else { fatalError("Usage helper missing") }
    let helper = Process(); helper.executableURL = URL(fileURLWithPath:"/usr/bin/python3"); helper.arguments = ["-I", script, "--self-test"]
    helper.standardOutput = FileHandle.nullDevice; try helper.run(); helper.waitUntilExit(); check(helper.terminationStatus == 0)
    print("Usage parsing, refresh and helper checks passed")
} else {
    MainActor.assumeIsolated {
    let id = Bundle.main.bundleIdentifier ?? "local.antigravity.usage.companion"
    if NSRunningApplication.runningApplications(withBundleIdentifier:id).contains(where: {$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}) { exit(0) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = Meter()
    app.delegate = delegate
    app.run()
    }
}
