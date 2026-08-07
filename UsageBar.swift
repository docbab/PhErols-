// UsageBar — macOS status bar tracker for Claude Code + Codex rate limits.
//
// Sources:
//   Claude: GET https://api.anthropic.com/api/oauth/usage  (OAuth token from login keychain)
//   Codex:  last `rate_limits` event in the newest ~/.codex/sessions/**/*.jsonl rollout
//           (no live endpoint — chatgpt.com/backend-api rejects non-browser clients)

import SwiftUI
import Charts
import ServiceManagement

// MARK: - Model

enum Scope: String, Codable { case short, long }

struct Gauge: Identifiable, Codable, Equatable {
    let tool: String        // "Claude" | "Codex"
    let scope: Scope
    let window: String     // "5h", "7d"
    let usedPercent: Double
    let resetsAt: Date?
    var id: String { "\(tool)-\(scope.rawValue)" }
    var remaining: Double { min(100, max(0, 100 - usedPercent)) }
}

struct Sample: Codable {
    let t: Date
    let gauges: [Gauge]
}

/// Codex reports the window length in minutes; anything under a day is a short (session) window.
func scope(forWindowMinutes m: Int?) -> Scope { (m ?? 0) <= 1440 ? .short : .long }

func windowLabel(minutes m: Int?) -> String {
    guard let m, m > 0 else { return "?" }
    if m % 10080 == 0 { return "\(m / 10080)w" }
    if m % 1440 == 0 { return "\(m / 1440)d" }
    return "\(m / 60)h"
}

// MARK: - Claude

private struct ClaudeUsage: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
    }
    let five_hour: Window?
    let seven_day: Window?
}

let iso = ISO8601DateFormatter()

func parseClaude(_ data: Data) throws -> [Gauge] {
    let u = try JSONDecoder().decode(ClaudeUsage.self, from: data)
    func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        // API sends fractional seconds; ISO8601DateFormatter needs to be told.
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s) ?? {
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }()
    }
    var out: [Gauge] = []
    if let w = u.five_hour, let p = w.utilization {
        out.append(Gauge(tool: "Claude", scope: .short, window: "5h", usedPercent: p, resetsAt: date(w.resets_at)))
    }
    if let w = u.seven_day, let p = w.utilization {
        out.append(Gauge(tool: "Claude", scope: .long, window: "7d", usedPercent: p, resetsAt: date(w.resets_at)))
    }
    return out
}

/// Shelling out to /usr/bin/security keeps the keychain ACL happy without embedding
/// Security framework code — the Apple-signed binary is already trusted for this item.
func claudeToken() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let json = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any]
    else { return nil }
    return oauth["accessToken"] as? String
}

/// The usage endpoint is itself rate limited and the Claude Code CLI polls it too, so a
/// 429 here means "back off", not "broken". `Retry-After` is often 0 — treat it as a floor.
struct RateLimited: Error { let retryAfter: TimeInterval }

/// 5m base, doubling to an hour. Windows are 5h/7d — minute resolution buys nothing.
func nextBackoff(_ current: TimeInterval, base: TimeInterval = 300, cap: TimeInterval = 3600) -> TimeInterval {
    min(max(current * 2, base), cap)
}

func fetchClaude() async throws -> [Gauge] {
    guard let token = claudeToken() else { throw Err.msg("Claude: not logged in") }
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.timeoutInterval = 15
    req.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, resp) = try await URLSession.shared.data(for: req)
    let http = resp as? HTTPURLResponse
    let code = http?.statusCode ?? 0
    if code == 429 || code == 529 {
        let ra = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0
        throw RateLimited(retryAfter: ra)
    }
    guard code == 200 else { throw Err.msg("Claude: HTTP \(code)") }
    return try parseClaude(data)
}

// MARK: - Codex

private struct CodexEnvelope: Decodable {
    struct Payload: Decodable { let rate_limits: CodexLimits? }
    let payload: Payload?
}

private struct CodexLimits: Decodable {
    struct W: Decodable {
        let used_percent: Double?
        let window_minutes: Int?
        let resets_at: Double?
    }
    let primary: W?
    let secondary: W?
}

func parseCodex(line: Data) -> [Gauge]? {
    guard let limits = try? JSONDecoder().decode(CodexEnvelope.self, from: line).payload?.rate_limits
    else { return nil }
    let gauges = [limits.primary, limits.secondary].compactMap { w -> Gauge? in
        guard let w, let used = w.used_percent else { return nil }
        return Gauge(tool: "Codex",
                     scope: scope(forWindowMinutes: w.window_minutes),
                     window: windowLabel(minutes: w.window_minutes),
                     usedPercent: used,
                     resetsAt: w.resets_at.map { Date(timeIntervalSince1970: $0) })
    }
    return gauges.isEmpty ? nil : gauges
}

/// Newest rollout files first; the freshest `rate_limits` event wins.
func fetchCodex() throws -> [Gauge] {
    let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")
    guard let walk = FileManager.default.enumerator(at: root,
                                                    includingPropertiesForKeys: [.contentModificationDateKey])
    else { throw Err.msg("Codex: no sessions dir") }
    var files: [(URL, Date)] = []
    for case let url as URL in walk where url.pathExtension == "jsonl" {
        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        files.append((url, m))
    }
    for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(5) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            if let g = parseCodex(line: Data(line.utf8)) { return g }
        }
    }
    throw Err.msg("Codex: no usage data yet")
}

// MARK: - Advice

/// Tuning knobs — real usage patterns differ per plan, so these are meant to be edited.
enum Thresholds {
    static let burnRemainingPct = 50.0      // short window still has this much left...
    static let burnResetWithin: TimeInterval = 60 * 60   // ...and resets within an hour -> spend it
    static let saveRemainingPct = 25.0      // long window has this little left...
    static let saveResetAfter: TimeInterval = 48 * 3600  // ...and won't reset for days -> conserve
}

struct Advice: Identifiable, Equatable {
    enum Kind: String { case burn, save }
    let kind: Kind
    let tool: String
    let title: String
    let body: String
    var id: String { "\(tool)-\(kind.rawValue)" }
}

func untilText(_ d: TimeInterval) -> String {
    if d < 60 { return "곧" }
    if d < 3600 { return "\(Int(d / 60))분 후" }
    if d < 86400 { return "\(Int(d / 3600))시간 후" }
    return "\(Int(d / 86400))일 후"
}

/// Conserve advice wins over spend advice: a scarce weekly budget outranks a expiring 5h window.
func advise(_ gauges: [Gauge], now: Date) -> [Advice] {
    var out: [Advice] = []
    for tool in Set(gauges.map(\.tool)).sorted() {
        let mine = gauges.filter { $0.tool == tool }
        let short = mine.first { $0.scope == .short }
        let long = mine.first { $0.scope == .long }

        if let g = long, let r = g.resetsAt {
            let until = r.timeIntervalSince(now)
            if g.remaining <= Thresholds.saveRemainingPct, until >= Thresholds.saveResetAfter {
                out.append(Advice(kind: .save, tool: tool,
                                  title: "\(tool) 장기 한도 부족",
                                  body: "\(g.window) 한도 \(Int(g.remaining))% 남음, 리셋 \(untilText(until)). 토큰 아껴 쓰기."))
                continue   // don't also tell them to burn tokens
            }
        }
        if let g = short, let r = g.resetsAt {
            let until = r.timeIntervalSince(now)
            if g.remaining >= Thresholds.burnRemainingPct, until <= Thresholds.burnResetWithin, until > 0 {
                out.append(Advice(kind: .burn, tool: tool,
                                  title: "\(tool) 단기 한도 여유",
                                  body: "\(g.window) 한도 \(Int(g.remaining))% 남았는데 리셋 \(untilText(until)). 지금 토큰 팍팍 쓰기."))
            }
        }
    }
    return out
}

/// AppleScript string literal escaping — only backslash and double quote are special.
func asLiteral(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

// ponytail: notifications go out via osascript, so the banner is attributed to Script Editor.
// UNUserNotificationCenter silently refuses to grant authorization to this ad-hoc-signed bundle
// (requestAuthorization returns granted=false). Switch to UNUserNotificationCenter once the app
// is signed with a real Developer ID.
func notify(_ a: Advice) {
    let script = "display notification \(asLiteral(a.body)) with title \(asLiteral(a.title))"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    p.standardError = FileHandle.nullDevice
    try? p.run()
}

// MARK: - Update check

/// Where `build.sh dist` publishes to. Read without a token, so the repo must be public —
/// a private repo is a 404 to everyone who isn't logged in.
let releasesRepo = "docbab/PhErols-"

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

struct Release: Equatable { let version: String; let url: URL }

/// Component-wise numeric compare — a string compare calls "1.10" older than "1.9".
func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }
    let y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0
        let r = i < y.count ? y[i] : 0
        if l != r { return l > r }
    }
    return false
}

/// `/releases/latest` redirects to `/releases/tag/<tag>`, so the landing URL carries the version.
/// A repo with no published release lands on plain `/releases` instead — hence the path check.
func version(fromRedirect url: URL) -> String? {
    let parts = url.pathComponents
    guard let i = parts.firstIndex(of: "tag"), i > 0, parts[i - 1] == "releases",
          i + 1 < parts.count
    else { return nil }
    let tag = parts[i + 1]
    let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    return v.isEmpty ? nil : v
}

/// The HTML endpoint, not api.github.com: the unauthenticated API allows 60 requests an hour
/// per IP, shared with every other tool on the machine and with everyone behind the same office
/// NAT, so the check would silently stop working. A HEAD that follows the redirect has no limit.
func fetchRelease() async -> Release? {
    guard let url = URL(string: "https://github.com/\(releasesRepo)/releases/latest")
    else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "HEAD"
    req.timeoutInterval = 15
    req.cachePolicy = .reloadIgnoringLocalCacheData
    guard let (_, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200,
          let final = resp.url, let v = version(fromRedirect: final)
    else { return nil }
    return Release(version: v, url: final)
}

// MARK: - Login item

/// macOS registers the bundle by path, so moving or renaming UsageBar.app breaks the
/// login item — re-toggle after moving it.
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - Tracker

enum Err: Error, LocalizedError {
    case msg(String)
    var errorDescription: String? { if case .msg(let s) = self { return s }; return nil }
}

@MainActor
final class Tracker: ObservableObject {
    @Published var gauges: [Gauge] = []
    @Published var history: [Sample] = []
    @Published var notes: [String] = []
    @Published var updatedAt: Date?
    @Published var advices: [Advice] = []
    @Published var update: Release?

    /// Notify on a state change only, so a standing condition isn't announced every minute.
    private var notified: Set<String> = []

    private let store: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "UsageBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "history.json")
    }()

    private var timer: Timer?
    private let maxSamples = 2880   // 60s cadence -> ~2 days of graph

    /// Claude is a remote call on a rate-limited endpoint, so it runs on its own schedule and
    /// its last good reading survives a failed poll. Codex is a local file read — free every tick.
    private var claudeGauges: [Gauge] = []
    private var claudeNextTry = Date.distantPast
    private var claudeBackoff: TimeInterval = 0
    private let claudeInterval: TimeInterval = 300

    /// Hourly is plenty for a release check, and the unauthenticated GitHub API allows
    /// only 60 requests an hour per IP.
    private var updateNextTry = Date.distantPast

    init() {
        if let d = try? Data(contentsOf: store),
           let h = try? JSONDecoder().decode([Sample].self, from: d) { history = h }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// Manual refresh clears the backoff — the user pressing the button is worth one retry.
    func refresh(force: Bool = false) async {
        var found: [Gauge] = []
        var problems: [String] = []

        if force { claudeNextTry = .distantPast; claudeBackoff = 0; updateNextTry = .distantPast }

        if Date() >= updateNextTry {
            updateNextTry = Date().addingTimeInterval(3600)
            if let r = await fetchRelease(), isNewer(r.version, than: appVersion) { update = r }
            else { update = nil }
        }

        if Date() >= claudeNextTry {
            do {
                claudeGauges = try await fetchClaude()
                claudeBackoff = 0
                claudeNextTry = Date().addingTimeInterval(claudeInterval)
            } catch let e as RateLimited {
                claudeBackoff = nextBackoff(claudeBackoff)
                let wait = max(e.retryAfter, claudeBackoff)
                claudeNextTry = Date().addingTimeInterval(wait)
                problems.append("Claude: 요청 제한 — \(Int(wait / 60))분 후 재시도"
                                + (claudeGauges.isEmpty ? "" : " (아래는 마지막 측정값)"))
            } catch {
                claudeGauges = []
                claudeNextTry = Date().addingTimeInterval(claudeInterval)
                problems.append(error.localizedDescription)
            }
        }
        found += claudeGauges

        do { found += try fetchCodex() }
        catch { problems.append(error.localizedDescription) }

        notes = problems
        guard !found.isEmpty else { return }
        gauges = found.sorted { ($0.scope.rawValue, $0.tool) < ($1.scope.rawValue, $1.tool) }
        updatedAt = Date()

        advices = advise(gauges, now: Date())
        let live = Set(advices.map(\.id))
        for a in advices where !notified.contains(a.id) { notify(a) }
        notified = live

        // Only append when something moved, so an idle day is one point, not 1440.
        if history.last?.gauges != gauges {
            history.append(Sample(t: Date(), gauges: gauges))
            if history.count > maxSamples { history.removeFirst(history.count - maxSamples) }
            try? JSONEncoder().encode(history).write(to: store, options: .atomic)
        }
    }

    /// Status bar text: worst remaining per tool.
    var barTitle: String {
        guard !gauges.isEmpty else { return "—" }
        let cols = ["Claude": "C", "Codex": "X"].sorted { $0.value < $1.value }.compactMap { tool, tag -> String? in
            guard let low = gauges.filter({ $0.tool == tool }).map(\.remaining).min() else { return nil }
            let mark = advices.first { $0.tool == tool }.map { $0.kind == .burn ? "⚡" : "🐢" } ?? ""
            return "\(tag) \(Int(low))%\(mark)"
        }
        return cols.joined(separator: "  ")
    }
}

// MARK: - UI

func barColor(_ remaining: Double) -> Color {
    remaining <= 10 ? .red : remaining <= 30 ? .orange : .green
}

struct GaugeRow: View {
    let g: Gauge
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(g.tool) · \(g.window)").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(g.remaining))% 남음")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(barColor(g.remaining))
            }
            ProgressView(value: g.remaining, total: 100).tint(barColor(g.remaining))
            if let r = g.resetsAt {
                Text("리셋 \(r.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

struct HistoryChart: View {
    let history: [Sample]

    private struct Point: Identifiable {
        let id = UUID()
        let t: Date
        let key: String
        let remaining: Double
    }

    private var points: [Point] {
        history.flatMap { s in
            s.gauges.map { Point(t: s.t, key: "\($0.tool) \($0.window)", remaining: $0.remaining) }
        }
    }

    var body: some View {
        if points.count < 2 {
            Text("그래프는 두 번째 측정부터 표시됩니다")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(height: 40)
        } else {
            Chart(points) { p in
                LineMark(x: .value("시각", p.t), y: .value("남은 %", p.remaining))
                    .foregroundStyle(by: .value("한도", p.key))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) }
            .chartLegend(position: .bottom, spacing: 4)
            .frame(height: 110)
        }
    }
}

struct MenuView: View {
    @ObservedObject var tracker: Tracker
    @State private var loginAtStart = LoginItem.enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let u = tracker.update {
                Button { NSWorkspace.shared.open(u.url) } label: {
                    HStack(spacing: 6) {
                        Text("⬆")
                        Text("새 버전 \(u.version) 있음 · 받기")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ForEach(tracker.advices) { a in
                HStack(alignment: .top, spacing: 6) {
                    Text(a.kind == .burn ? "⚡" : "🐢")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.title).font(.system(size: 11, weight: .semibold))
                        Text(a.body).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((a.kind == .burn ? Color.green : Color.orange).opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 6))
            }

            section("단기 한도", tracker.gauges.filter { $0.scope == .short })
            section("장기 한도", tracker.gauges.filter { $0.scope == .long })

            Divider()
            Text("남은 사용량 추이").font(.system(size: 11, weight: .semibold))
            HistoryChart(history: tracker.history)

            ForEach(tracker.notes, id: \.self) { n in
                Text(n).font(.system(size: 10)).foregroundStyle(.orange)
            }

            Divider()
            Toggle("로그인 시 자동 실행", isOn: $loginAtStart)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .onChange(of: loginAtStart) { _, on in
                    do { try LoginItem.set(on) }
                    catch {
                        tracker.notes.append("자동 실행 설정 실패: \(error.localizedDescription)")
                        loginAtStart = LoginItem.enabled
                    }
                }

            HStack {
                Text((tracker.updatedAt.map { "갱신 \($0.formatted(date: .omitted, time: .standard))" } ?? "갱신 안 됨")
                     + " · v\(appVersion)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("새로고침") { Task { await tracker.refresh(force: true) } }
                Button("종료") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
        .padding(12)
        .frame(width: 300)
    }

    @ViewBuilder
    private func section(_ title: String, _ gauges: [Gauge]) -> some View {
        if !gauges.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(gauges) { GaugeRow(g: $0) }
            }
        }
    }
}

@main
struct UsageBarApp: App {
    @StateObject private var tracker = Tracker()

    init() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { selfTest(); exit(0) }
        // Lets a user (or a release check) confirm the update path end to end without a GUI.
        if args.contains("--checkupdate") {
            // Detached: App.init runs on the main actor, so a plain Task would inherit it and
            // deadlock against the semaphore wait below.
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                if let r = await fetchRelease() {
                    print("installed v\(appVersion), latest v\(r.version) — "
                          + (isNewer(r.version, than: appVersion) ? "update available: \(r.url)" : "up to date"))
                } else {
                    print("installed v\(appVersion), no release found at \(releasesRepo)")
                }
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        // Headless toggle, also how build.sh verifies registration works.
        if let i = args.firstIndex(of: "--login") {
            let want = args.count > i + 1 ? args[i + 1] : "status"
            if want == "on" || want == "off" {
                do { try LoginItem.set(want == "on") }
                catch { print("login \(want) failed: \(error.localizedDescription)"); exit(1) }
            }
            print("login item: \(LoginItem.enabled ? "enabled" : "disabled")")
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(tracker: tracker)
        } label: {
            Text(tracker.barTitle).font(.system(size: 12).monospacedDigit())
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Self check

func selfTest() {
    let claude = Data("""
    {"five_hour":{"utilization":43.0,"resets_at":"2026-08-06T10:29:59.797967+00:00"},
     "seven_day":{"utilization":27.0,"resets_at":"2026-08-07T03:59:59.797997+00:00"}}
    """.utf8)
    let cg = try! parseClaude(claude)
    assert(cg.count == 2, "claude: expected 2 windows, got \(cg.count)")
    assert(cg[0].scope == .short && Int(cg[0].remaining) == 57, "claude short remaining wrong")
    assert(cg[1].scope == .long && Int(cg[1].remaining) == 73, "claude long remaining wrong")
    assert(cg[0].resetsAt != nil, "claude: fractional-second date failed to parse")

    let codex = Data("""
    {"timestamp":"2026-08-06T05:34:06.593Z","type":"event_msg","payload":{"type":"token_count",
     "rate_limits":{"primary":{"used_percent":100.0,"window_minutes":10080,"resets_at":1786358838},
     "secondary":{"used_percent":12.5,"window_minutes":300,"resets_at":1786300000}}}}
    """.utf8)
    let xg = parseCodex(line: codex)!
    assert(xg.count == 2, "codex: expected 2 windows")
    assert(xg[0].scope == .long && xg[0].window == "1w" && xg[0].remaining == 0, "codex weekly wrong")
    assert(xg[1].scope == .short && xg[1].window == "5h" && xg[1].remaining == 87.5, "codex 5h wrong")

    // A non-usage line must not be mistaken for one.
    assert(parseCodex(line: Data(#"{"type":"event_msg","payload":{"type":"agent_message"}}"#.utf8)) == nil)

    // Advice rules.
    let now = Date(timeIntervalSince1970: 1_000_000)
    func g(_ tool: String, _ s: Scope, remaining: Double, resetsIn: TimeInterval) -> Gauge {
        Gauge(tool: tool, scope: s, window: s == .short ? "5h" : "7d",
              usedPercent: 100 - remaining, resetsAt: now.addingTimeInterval(resetsIn))
    }
    // Short window flush and expiring soon -> spend.
    let burn = advise([g("Claude", .short, remaining: 62, resetsIn: 30 * 60),
                       g("Claude", .long, remaining: 80, resetsIn: 5 * 86400)], now: now)
    assert(burn.map(\.kind) == [.burn], "expected burn advice, got \(burn.map(\.kind))")

    // Long window scarce and far from reset -> conserve, and nothing else.
    let save = advise([g("Codex", .short, remaining: 90, resetsIn: 10 * 60),
                       g("Codex", .long, remaining: 5, resetsIn: 4 * 86400)], now: now)
    assert(save.map(\.kind) == [.save], "conserve must suppress burn, got \(save.map(\.kind))")

    // Quiet cases: short window resets far away; long window scarce but resetting soon.
    assert(advise([g("Claude", .short, remaining: 90, resetsIn: 4 * 3600)], now: now).isEmpty)
    assert(advise([g("Claude", .long, remaining: 5, resetsIn: 3600)], now: now).isEmpty)
    // AppleScript literals must survive quotes and backslashes.
    assert(asLiteral(#"a"b\c"#) == #""a\"b\\c""#, "bad escaping: \(asLiteral(#"a"b\c"#))")

    // Already-reset timestamps must not fire.
    assert(advise([g("Claude", .short, remaining: 90, resetsIn: -600)], now: now).isEmpty)

    // 429 backoff: first failure waits the base interval, then doubles, capped at an hour.
    assert(nextBackoff(0) == 300, "first backoff must be the base interval")
    assert(nextBackoff(300) == 600 && nextBackoff(600) == 1200, "backoff must double")
    assert(nextBackoff(3000) == 3600 && nextBackoff(3600) == 3600, "backoff must cap at 1h")

    // Version compare must be numeric, not lexical, and must not nag on an equal version.
    assert(isNewer("1.10", than: "1.9"), "1.10 is newer than 1.9")
    assert(!isNewer("1.9", than: "1.10"), "compare must not be lexical")
    assert(isNewer("1.2.1", than: "1.2"), "trailing component counts")
    assert(!isNewer("1.2", than: "1.2") && !isNewer("1.2", than: "1.2.0"), "equal must not nag")
    assert(!isNewer("0.9", than: "1.0"), "older release must not prompt")

    // Version comes from the URL /releases/latest redirects to.
    func redirect(_ s: String) -> String? { version(fromRedirect: URL(string: s)!) }
    assert(redirect("https://github.com/docbab/PhErols-/releases/tag/v1.2") == "1.2", "tag parse")
    assert(redirect("https://github.com/o/r/releases/tag/1.2") == "1.2", "bare tag, no v prefix")
    // No release published: GitHub lands on the releases index, which carries no version.
    assert(redirect("https://github.com/o/r/releases") == nil, "index page must not parse")
    assert(redirect("https://github.com/o/tag/x") == nil, "'tag' outside /releases/ must not parse")

    print("selftest ok")
}
