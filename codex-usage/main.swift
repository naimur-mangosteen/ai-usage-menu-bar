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
enum MeterError: Error { case schema; case service(String) }
struct CodexReader {
    static func read() throws -> Usage {
        guard let script = Bundle.main.path(forResource:"read_usage", ofType:"py") else { throw MeterError.service("Usage helper missing. Rebuild the app.") }
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments = [script]; process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if process.terminationStatus != 0 {
            let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any]
            throw MeterError.service(object?["error"] as? String ?? "Could not read Codex usage.")
        }
        return try Usage.decode(data)
    }
}
@MainActor
final class Meter: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var timer: Timer?
    var usage: Usage?
    var lastSuccess: Date?
    var nextCheck = Date.distantPast
    var issue: String? = "Loading usage…"
    var busy = false
    var failures = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
    }
    @objc func wake() { refresh() }
    @objc func refresh() {
        guard !busy, Date() >= nextCheck else { render(); return }
        busy = true; render()
        Task {
            do {
                usage = try await Task.detached { try CodexReader.read() }.value
                lastSuccess = Date(); issue = nil; failures = 0; nextCheck = Date().addingTimeInterval(300)
            } catch MeterError.service(let message) {
                usage = nil; lastSuccess = nil; issue = message; failures += 1
                nextCheck = Date().addingTimeInterval(backoff())
            } catch MeterError.schema {
                issue = "Usage response format changed."; nextCheck = Date().addingTimeInterval(3600)
            } catch {
                failures += 1; issue = "Could not refresh Codex usage."; nextCheck = Date().addingTimeInterval(backoff())
            }
            busy = false; render()
        }
    }
    func backoff() -> Double { min(3600, 300 * pow(2, Double(min(max(failures-1,0),4)))) }
    func line(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let row = NSMenuItem(title:title, action:action, keyEquivalent:""); row.target = self; return row
    }
    func render() {
        let stale = usage != nil && (issue != nil || (lastSuccess.map { Date().timeIntervalSince($0)>600 } ?? true))
        let countdown = ResetTime.short(usage?.seven_day?.resets_at).map { "·" + $0 } ?? ""
        let title = "CX " + (usage?.compact ?? "—/—") + countdown + (stale ? "*" : (issue != nil && !busy ? "!" : ""))
        item.button?.title = title
        item.button?.setAccessibilityLabel("Codex usage: \(title)")
        item.button?.toolTip = issue ?? "Codex usage — 5-hour and weekly limits; countdown is until weekly reset"
        let menu = NSMenu()
        menu.addItem(line("Codex usage • ChatGPT account"))
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
        if nextCheck > Date() { menu.addItem(line("Next check: \(fmt.string(from:nextCheck))")) }
        menu.addItem(line("Open Codex Usage Settings",action:#selector(openUsage)))
        menu.addItem(.separator()); menu.addItem(line("Quit",action:#selector(quit)))
        item.menu = menu
        // Local verification receipt contains only display state; never credentials or response bodies.
        if let path = ProcessInfo.processInfo.environment["CODEX_METER_DIAGNOSTICS"] {
            let record: [String:Any] = ["title":title,"status":issue ?? "ok","updated":lastSuccess?.description ?? "never","busy":busy,"statusItemVisible":item.isVisible,"buttonWindowVisible":item.button?.window?.isVisible ?? false,"buttonFrame":item.button?.window.map { NSStringFromRect($0.frame) } ?? "unavailable"]
            if let data = try? JSONSerialization.data(withJSONObject:record,options:.sortedKeys) { try? data.write(to:URL(fileURLWithPath:path),options:.atomic) }
        }
    }
    @objc func openUsage() { NSWorkspace.shared.open(URL(string:"https://chatgpt.com/codex/settings/usage")!) }
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
    print("Usage parsing and reset countdown checks passed")
} else {
    MainActor.assumeIsolated {
    let id = Bundle.main.bundleIdentifier ?? "local.codex.usage.companion"
    if NSRunningApplication.runningApplications(withBundleIdentifier:id).contains(where: {$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}) { exit(0) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = Meter()
    app.delegate = delegate
    app.run()
    }
}
