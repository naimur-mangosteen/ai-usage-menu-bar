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
/// Cursor's monthly plan usage, as percent used of the billing cycle's allowance.
struct Usage: Decodable {
    let plan: Double?
    let on_demand: Double?
    let resets_at: String?
    let cycle_start: String?
    let membership: String?
    let unlimited: Bool
    static func decode(_ data: Data) throws -> Usage {
        guard let usage = try? JSONDecoder().decode(Usage.self, from: data) else { throw MeterError.schema }
        guard usage.plan != nil || usage.unlimited else { throw MeterError.schema }
        for value in [usage.plan, usage.on_demand].compactMap({ $0 }) {
            guard value.isFinite, (0...100).contains(value) else { throw MeterError.schema }
        }
        return usage
    }
    /// Menu-bar form, e.g. "34%"; "∞" for an unlimited plan.
    var compact: String { unlimited && plan == nil ? "∞" : Self.percent(plan) }
    static func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "—" }
    /// e.g. "Month pace: 34% used, 40% elapsed — on pace". Within 5 points counts as on pace.
    func paceLine(now: Date = Date()) -> String? {
        guard let plan, let start = ResetTime.date(cycle_start), let end = ResetTime.date(resets_at), end > start, now > start, now < end else { return nil }
        let elapsed = now.timeIntervalSince(start) / end.timeIntervalSince(start) * 100
        let gap = Int((elapsed - plan).rounded())
        let state = abs(gap) <= 5 ? "on pace" : gap > 0 ? "\(gap) pts under pace" : "\(-gap) pts over pace"
        return "Month pace: \(Int(plan.rounded()))% used, \(Int(elapsed.rounded()))% elapsed — \(state)"
    }
}
enum MeterError: Error { case schema; case service(String) }
struct CursorReader {
    static func read() throws -> Usage {
        guard let script = Bundle.main.path(forResource:"read_usage", ofType:"py") else { throw MeterError.service("Usage helper missing. Rebuild the app.") }
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments = ["-I", script]; process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        // Watchdog: the helper gives itself 45 s overall; never let a stuck read keep the app on "Refreshing…".
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if process.terminationStatus != 0 {
            let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any]
            throw MeterError.service(object?["error"] as? String ?? "Could not read Cursor usage.")
        }
        return try Usage.decode(data)
    }
}
@MainActor
final class Meter: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Minimum gap between manual refreshes, so the Refresh button can't hammer Cursor's API.
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
    var failures = 0
    var holdUntil: Date?
    func applicationDidFinishLaunching(_ notification: Notification) {
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
        guard !busy, Date() >= nextCheck else { render(); return }
        busy = true; lastAttempt = Date(); render()
        Task {
            do {
                usage = try await Task.detached { try CursorReader.read() }.value
                lastSuccess = Date(); issue = nil; failures = 0; nextCheck = Date().addingTimeInterval(300)
            } catch MeterError.service(let message) {
                usage = nil; lastSuccess = nil; issue = message; failures += 1
                nextCheck = Date().addingTimeInterval(backoff())
            } catch MeterError.schema {
                issue = "Usage response format changed."; nextCheck = Date().addingTimeInterval(3600)
            } catch {
                failures += 1; issue = "Could not refresh Cursor usage."; nextCheck = Date().addingTimeInterval(backoff())
            }
            busy = false; render()
        }
    }
    func backoff() -> Double { min(3600, 300 * pow(2, Double(min(max(failures-1,0),4)))) }
    nonisolated static func canForceRefresh(busy: Bool, lastAttempt: Date?, now: Date = Date()) -> Bool {
        guard !busy else { return false }
        return lastAttempt.map { now.timeIntervalSince($0) >= manualRefreshGap } ?? true
    }
    @objc func forceRefresh() {
        guard Self.canForceRefresh(busy: busy, lastAttempt: lastAttempt) else { render(); return }
        nextCheck = .distantPast; refresh()
    }
    func line(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let row = NSMenuItem(title:title, action:action, keyEquivalent:""); row.target = self; return row
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(line("Cursor usage" + (usage?.membership.map { " • \($0)" } ?? "")))
        menu.addItem(line("Plan: \(usage?.compact ?? "—")" + (usage?.on_demand.map { "   On-demand: \(Usage.percent($0))" } ?? "")))
        if let issue { menu.addItem(line(issue)) }
        let fmt = DateFormatter(); fmt.timeStyle = .short; fmt.dateStyle = .short
        if let date = lastSuccess { menu.addItem(line("Updated: \(fmt.string(from:date))")) }
        if let date = ResetTime.date(usage?.resets_at), let remaining = ResetTime.remaining(usage?.resets_at) {
            menu.addItem(line("Cycle resets in \(remaining) — \(fmt.string(from:date))"))
        } else if usage != nil { menu.addItem(line("Cycle reset time unavailable")) }
        if let pace = usage?.paceLine() { menu.addItem(line(pace)) }
        menu.addItem(.separator())
        let refreshItem = line(busy ? "Refreshing…" : "Refresh", action:#selector(forceRefresh))
        refreshItem.isEnabled = Self.canForceRefresh(busy: busy, lastAttempt: lastAttempt)
        menu.addItem(refreshItem)
        if nextCheck > Date() { menu.addItem(line("Next check: \(fmt.string(from:nextCheck))")) }
        menu.addItem(line("Open Cursor Usage Dashboard",action:#selector(openUsage)))
        menu.addItem(.separator()); menu.addItem(line("Quit Cursor Usage",action:#selector(quit)))
    }
    func render() {
        let stale = usage != nil && (issue != nil || (lastSuccess.map { Date().timeIntervalSince($0)>600 } ?? true))
        let countdown = ResetTime.short(usage?.resets_at).map { "·" + $0 } ?? ""
        let title = "CU " + (usage?.compact ?? "—") + countdown + (stale ? "*" : (issue != nil && !busy ? "!" : ""))
        item.button?.title = title
        item.button?.setAccessibilityLabel("Cursor usage: \(title)")
        item.button?.toolTip = (issue.map { $0 + "\n" } ?? "") + "Cursor usage: plan % used · time to billing-cycle reset · * stale · ! issue"
        // Local verification receipt contains only display state; never credentials or response bodies.
        if let path = ProcessInfo.processInfo.environment["CURSOR_METER_DIAGNOSTICS"] {
            let record: [String:Any] = ["title":title,"status":issue ?? "ok","updated":lastSuccess?.description ?? "never","busy":busy,"statusItemVisible":item.isVisible]
            if let data = try? JSONSerialization.data(withJSONObject:record,options:.sortedKeys) { try? data.write(to:URL(fileURLWithPath:path),options:.atomic) }
        }
    }
    @objc func openUsage() { NSWorkspace.shared.open(URL(string:"https://cursor.com/dashboard?tab=usage")!) }
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
    let sample = #"{"plan":34,"on_demand":null,"resets_at":"2026-12-01T00:00:00.000Z","cycle_start":"2026-11-01T00:00:00.000Z","membership":"pro","unlimited":false}"#
    let usage = try Usage.decode(Data(sample.utf8))
    check(usage.compact == "34%")
    check(try Usage.decode(Data(#"{"plan":null,"on_demand":null,"resets_at":null,"cycle_start":null,"membership":null,"unlimited":true}"#.utf8)).compact == "∞")
    for value in [#"{}"#, #"{"plan":null,"unlimited":false}"#, #"{"plan":101,"unlimited":false}"#] {
        do { _ = try Usage.decode(Data(value.utf8)); fatalError("Invalid payload accepted") } catch {}
    }
    // 12 of 30 days elapsed (40%) with 34% used is 6 pts under; 11 days (37%) is on pace; none after the cycle.
    check(usage.paceLine(now: ResetTime.date("2026-11-13T00:00:00Z")!) == "Month pace: 34% used, 40% elapsed — 6 pts under pace")
    check(usage.paceLine(now: ResetTime.date("2026-11-12T00:00:00Z")!) == "Month pace: 34% used, 37% elapsed — on pace")
    check(usage.paceLine(now: ResetTime.date("2026-12-02T00:00:00Z")!) == nil)
    let now = Date(timeIntervalSince1970: 1_000_000)
    check(ResetTime.short(String(1_000_000 + 12*86400),now:now) == "12d")
    check(Meter.canForceRefresh(busy:false, lastAttempt:nil, now:now))
    check(!Meter.canForceRefresh(busy:true, lastAttempt:nil, now:now))
    check(!Meter.canForceRefresh(busy:false, lastAttempt:now.addingTimeInterval(-10), now:now))
    // The bundled helper's own parser and cookie tests (no Cursor login needed).
    guard let script = Bundle.main.path(forResource:"read_usage", ofType:"py") else { fatalError("Usage helper missing") }
    let helper = Process(); helper.executableURL = URL(fileURLWithPath:"/usr/bin/python3"); helper.arguments = ["-I", script, "--self-test"]
    helper.standardOutput = FileHandle.nullDevice; try helper.run(); helper.waitUntilExit(); check(helper.terminationStatus == 0)
    print("Usage parsing, pace, refresh and helper checks passed")
} else {
    MainActor.assumeIsolated {
    let id = Bundle.main.bundleIdentifier ?? "local.cursor.usage.companion"
    if NSRunningApplication.runningApplications(withBundleIdentifier:id).contains(where: {$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}) { exit(0) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = Meter()
    app.delegate = delegate
    app.run()
    }
}
