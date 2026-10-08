import Foundation
import Combine
import SwiftUI
import UserNotifications

// MARK: - UI

enum AppTab: String, CaseIterable, Identifiable {
    case overview, insights, models
    var id: String { rawValue }
    var label: String {
        switch self {
        case .overview: return "Overview"
        case .insights: return "Insights"
        case .models: return "Models"
        }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var dailyBreakdown: [DailyActivity] = []
    @Published var rangeSpend: Double = 0
    @Published var rangeTokens: Int = 0
    @Published var rangeRequests: Int = 0
    @Published var todaySpend: Double = 0
    @Published var todayTokens: Int = 0
    @Published var todayRequests: Int = 0
    @Published var lastFetch: Date?
    @Published var lastError: String?
    @Published var isLoading: Bool = false
    @Published var needsSetup: Bool
    @Published var setupKey: String = ""
    @Published var setupUserId: String = ""
    @Published var setupURL: String = ""
    @Published var detectedFromZshrc: Bool = false
    @Published var rangeStart: Date
    @Published var rangeEnd: Date
    @Published var showCustomRange: Bool = false
    @Published var customStartText: String = ""
    @Published var customEndText: String = ""
    @Published var activeTab: AppTab = .overview
    @Published var availableModels: [AvailableModel] = []
    @Published var modelDetails: [String: ModelDetail] = [:]   // keyed by model name from /v2/model/info
    @Published var syncStatus: String = ""               // last sync result text
    private var lastSyncedAt: Date?
    @Published var budgetMax: Double?
    @Published var budgetSpend: Double = 0
    @Published var budgetDuration: String?
    @Published var budgetResetsAt: Date?
    @Published private var lastNotifiedThreshold: Int?
    private var notificationsAuthorized: Bool = false

    private var timer: Timer?
    private var modelsTimer: Timer?
    private var apiKey: String?
    private var userId: String?
    private var baseURL: URL?

    static let isoCal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    // API expects YYYY-MM-DD in UTC
    static let apiDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // Display: DD/MM/YY
    static let displayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yy"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // ISO8601 with timezone
    static let isoDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    var hasBudget: Bool { budgetMax != nil && budgetMax ?? 0 > 0 }

    var isShowingStale: Bool { lastError != nil && !dailyBreakdown.isEmpty }

    var budgetFraction: Double {
        guard let m = budgetMax, m > 0 else { return 0 }
        return min(1.0, budgetSpend / m)
    }

    var budgetRemaining: Double {
        guard let m = budgetMax else { return 0 }
        return max(0, m - budgetSpend)
    }

    var budgetDaysUntilReset: Int? {
        guard let r = budgetResetsAt else { return nil }
        let interval = r.timeIntervalSinceNow
        guard interval > 0 else { return nil }
        return Int(interval / 86400)
    }

    @Published var telemetry: Telemetry = Telemetry()

    private let keyPath: URL
    private let userPath: URL
    private let configPath: URL
    private let modelsPath: URL
    static let modelsRefreshInterval: TimeInterval = 3_600  // 1h — model lists change rarely

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.keyPath = home.appendingPathComponent(".llm-usage-key")
        self.userPath = home.appendingPathComponent(".llm-usage-user")
        self.configPath = home.appendingPathComponent(".llm-usage-config")
        self.modelsPath = home.appendingPathComponent(".llm-usage-models.json")

        let storedKey = Self.readFile(keyPath)
        let uid = Self.readFile(userPath)
        let storedURL = Self.readFile(configPath)

        self.apiKey = storedKey
        self.userId = uid
        self.baseURL = storedURL.flatMap { URL(string: $0) }
        self.setupKey = storedKey ?? ""
        self.setupUserId = uid ?? ""
        self.setupURL = storedURL ?? ""
        self.needsSetup = (storedKey == nil)

        // If no saved key, fall back to ~/.zshrc for an auto-detected value.
        if storedKey == nil, let zshKey = Self.detectFromZshrc() {
            self.setupKey = zshKey
            self.detectedFromZshrc = true
        }

        let (s, e) = Self.currentWeekRange()
        self.rangeStart = s
        self.rangeEnd = e
        self.customStartText = Self.displayFmt.string(from: s)
        self.customEndText = Self.displayFmt.string(from: e)

        if !self.needsSetup {
            startPolling()
            startModelsTimer()
            // Fetch models + costs once at launch so prices are visible immediately.
            Task { await self.refreshModels() }
        }

        loadModelsCache()
        Task { await requestNotificationPermission() }
    }

    private func startModelsTimer() {
        modelsTimer?.invalidate()
        modelsTimer = Timer.scheduledTimer(withTimeInterval: Self.modelsRefreshInterval, repeats: true) { _ in
            Task { @MainActor in
                await self.refreshModels()
            }
        }
    }

    // Per-tab refresh. Each fetches only what its tab needs.
    func refreshOverview() async {
        guard let apiKey, let baseURL else { return }
        isLoading = true
        async let a: Void = fetchActivity(apiKey: apiKey, baseURL: baseURL)
        async let b: Void = fetchBudget(apiKey: apiKey)
        _ = await (a, b)
        isLoading = false
    }

    func refreshInsights() async {
        guard let apiKey, let baseURL else { return }
        isLoading = true
        await fetchTelemetry(apiKey: apiKey)
        isLoading = false
    }

    func refreshModels() async {
        guard let apiKey, let baseURL else { return }
        isLoading = true
        async let list: Void = fetchModels(apiKey: apiKey, baseURL: baseURL)
        async let costs: Void = fetchModelCosts(apiKey: apiKey, baseURL: baseURL)
        _ = await (list, costs)
        isLoading = false
    }

    func refreshCurrentTab() async {
        switch activeTab {
        case .overview: await refreshOverview()
        case .insights: await refreshInsights()
        case .models: await refreshModels()
        }
    }

    private func loadModelsCache() {
        guard let data = try? Data(contentsOf: modelsPath),
              let cache = try? JSONDecoder.iso.decode(ModelsCache.self, from: data) else { return }
        availableModels = cache.models
    }

    private func fetchModels(apiKey: String, baseURL: URL) async {
        var comps = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "return_wildcard_routes", value: "false"),
            URLQueryItem(name: "include_model_access_groups", value: "false"),
            URLQueryItem(name: "only_model_access_groups", value: "false"),
            URLQueryItem(name: "include_metadata", value: "false"),
            URLQueryItem(name: "healthy_only", value: "false"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(ModelsAPIResponse.self, from: data)
            let cache = ModelsCache(fetched_at: Date(), models: decoded.data)
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let encoded = try? enc.encode(cache) {
                try? encoded.write(to: modelsPath, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: modelsPath.path
                )
            }
            availableModels = decoded.data
        } catch {
            NSLog("LLMUsage models fetch error: %@", error.localizedDescription)
        }
    }

    private func fetchModelCosts(apiKey: String, baseURL: URL) async {
        var page = 1
        var collected: [String: ModelDetail] = [:]
        let logPath = "/tmp/llmusage-cost.log"
        try? "starting fetchModelCosts\n".write(toFile: logPath, atomically: true, encoding: .utf8)
        while true {
            var comps = URLComponents(url: baseURL.appendingPathComponent("v2/model/info"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                URLQueryItem(name: "include_team_models", value: "true"),
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "size", value: "50"),
            ]
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 15
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                try? "page \(page) HTTP \(code) bytes=\(data.count)\n".write(toFile: logPath, atomically: false, encoding: .utf8)
                guard code == 200 else { break }
                let decoded = try JSONDecoder().decode(ModelInfoResponse.self, from: data)
                let rows = decoded.data
                if rows.isEmpty { break }
                for row in rows {
                    let mi = row.model_info
                    collected[row.model_name] = ModelDetail(
                        model_name: row.model_name,
                        input_per_million: mi.input_cost_per_token.map { $0 * 1_000_000 },
                        output_per_million: mi.output_cost_per_token.map { $0 * 1_000_000 },
                        max_input_tokens: mi.max_input_tokens,
                        max_output_tokens: mi.max_output_tokens,
                        cache_read_per_million: mi.cache_read_input_token_cost.map { $0 * 1_000_000 },
                        cache_creation_per_million: mi.cache_creation_input_token_cost.map { $0 * 1_000_000 }
                    )
                }
                if rows.count < 50 { break }
                page += 1
            } catch {
                try? "error: \(error)\n".write(toFile: logPath, atomically: false, encoding: .utf8)
                break
            }
        }
        modelDetails = collected
        try? "done: \(collected.count) models, has claude-sonnet-5-5=\(collected["claude-sonnet-5-5"] != nil)\n".write(toFile: logPath, atomically: false, encoding: .utf8)
    }

    private func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            notificationsAuthorized = granted
        } catch {
            notificationsAuthorized = false
        }
    }

    static func detectFromZshrc() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        // Matches `export LITELLM_API_KEY="sk-..."` or `LITELLM_API_KEY='sk-...'` or unquoted.
        let pattern = #"(?:export\s+)?LITELLM_API_KEY\s*=\s*(?:"([^\"]*)"|'([^']*)'|([^\s#]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, range: range) else { return nil }
        for i in 1...3 {
            if let r = Range(match.range(at: i), in: content) {
                let v = String(content[r]).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    static func currentWeekRange(now: Date = Date()) -> (Date, Date) {
        let cal = isoCal
        let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
        let end = cal.date(byAdding: .day, value: 6, to: start) ?? now
        return (start, end)
    }

    var isCurrentWeek: Bool {
        let (s, _) = Self.currentWeekRange()
        return Self.isoCal.isDate(rangeStart, inSameDayAs: s)
    }

    var rangeLabel: String {
        "\(Self.displayFmt.string(from: rangeStart)) – \(Self.displayFmt.string(from: rangeEnd))"
    }

    func shiftRange(byWeeks weeks: Int) {
        guard let ns = Self.isoCal.date(byAdding: .weekOfYear, value: weeks, to: rangeStart),
              let ne = Self.isoCal.date(byAdding: .day, value: 7 * weeks, to: rangeEnd) else { return }
        let (cwStart, _) = Self.currentWeekRange()
        if ns > cwStart { return } // don't allow future
        rangeStart = ns
        rangeEnd = ne
        startPolling()
    }

    func jumpToCurrentWeek() {
        let (s, e) = Self.currentWeekRange()
        rangeStart = s
        rangeEnd = e
        startPolling()
    }

    func openCustomRange() {
        customStartText = Self.displayFmt.string(from: rangeStart)
        customEndText = Self.displayFmt.string(from: rangeEnd)
        showCustomRange = true
    }

    func applyCustomRange() {
        let sFmt = Self.displayFmt
        guard let s = sFmt.date(from: customStartText.trimmingCharacters(in: .whitespaces)),
              let e = sFmt.date(from: customEndText.trimmingCharacters(in: .whitespaces)) else {
            lastError = "Use DD/MM/YY format, e.g. 06/10/26"
            return
        }
        guard s <= e else {
            lastError = "Start must be ≤ end"
            return
        }
        let (cwStart, _) = Self.currentWeekRange()
        if s > cwStart {
            lastError = "Range can't start in the future"
            return
        }
        rangeStart = s
        rangeEnd = e
        showCustomRange = false
        lastError = nil
        startPolling()
    }

    private static func readFile(_ url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func writeSecret(_ value: String, to url: URL) throws {
        try value.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    func saveCredentials() {
        let key = setupKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let uid = setupUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlText = setupURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            lastError = "API key is empty"
            return
        }
        guard !urlText.isEmpty else {
            lastError = "Gateway URL is required"
            return
        }
        guard let url = URL(string: urlText), url.scheme == "https" || url.scheme == "http" else {
            lastError = "Gateway URL must start with http(s)://"
            return
        }
        do {
            try writeSecret(key, to: keyPath)
            if !uid.isEmpty {
                try writeSecret(uid, to: userPath)
            } else {
                try? FileManager.default.removeItem(at: userPath)
            }
            try writeSecret(urlText, to: configPath)
            self.apiKey = key
            self.userId = uid.isEmpty ? nil : uid
            self.baseURL = url
            self.needsSetup = false
            self.lastError = nil
            startPolling()
        } catch {
            self.lastError = "Save failed: \(error.localizedDescription)"
        }
    }

    func startPolling() {
        Task {
            await refreshOverview()
            await refreshInsights()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                await self.refreshOverview()
                await self.refreshInsights()
            }
        }
    }

    func openSetup() {
        setupKey = apiKey ?? ""
        setupUserId = userId ?? ""
        setupURL = baseURL?.absoluteString ?? ""
        needsSetup = true
    }

    func runSync(agents: Set<String>) {
        // Cancel any pending auto-clear so old output doesn't get cleared mid-run.
        clearTask?.cancel()
        clearTask = nil

        // Run the bundled sync-models script. Agents: opencode, pi, codex, cursor, hermes.
        let onlyArg = agents.isEmpty ? "" : "--only=\(agents.sorted().joined(separator: ","))"
        let task = Process()
        let scriptPath = Bundle.main.path(forResource: "sync-models", ofType: nil)
            ?? Bundle.main.bundlePath + "/Contents/Resources/sync-models"
        task.executableURL = URL(fileURLWithPath: scriptPath)
        var args: [String] = []
        if !onlyArg.isEmpty { args.append(onlyArg) }
        task.arguments = args

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        syncStatus = "Syncing…"
        do {
            try task.run()
        } catch {
            syncStatus = "Failed to start: \(error.localizedDescription)"
            return
        }
        // Read output on a background queue, then update on main.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                Task { @MainActor in self.syncStatus = s.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        task.terminationHandler = { _ in
            Task { @MainActor in
                self.syncStatus = self.syncStatus + "\nDone."
                self.lastSyncedAt = Date()
                self.scheduleClear()
            }
        }
    }

    private var clearTask: Task<Void, Never>?

    private func scheduleClear() {
        clearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if !Task.isCancelled {
                self.syncStatus = ""
                self.clearTask = nil
            }
        }
    }

    private func fetchActivity(apiKey: String, baseURL: URL) async {
        let start = Self.apiDateFmt.string(from: rangeStart)
        let end = Self.apiDateFmt.string(from: rangeEnd)

        var comps = URLComponents(url: baseURL.appendingPathComponent("user/daily/activity"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "start_date", value: start),
            URLQueryItem(name: "end_date", value: end),
        ]
        if let userId { items.append(URLQueryItem(name: "user_id", value: userId)) }
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                lastError = "HTTP \(code)"
                return
            }
            let decoded = try JSONDecoder().decode(ActivityResponse.self, from: data)
            dailyBreakdown = decoded.results.sorted { $0.date > $1.date }

            rangeSpend = decoded.metadata?.total_spend
                ?? decoded.results.reduce(0) { $0 + $1.metrics.spend }
            rangeRequests = decoded.metadata?.total_api_requests
                ?? decoded.results.reduce(0) { $0 + $1.metrics.api_requests }
            rangeTokens = decoded.results.reduce(0) { $0 + $1.metrics.total_tokens }

            let todayStr = Self.apiDateFmt.string(from: Date())
            if let today = decoded.results.first(where: { $0.date == todayStr }) {
                todaySpend = today.metrics.spend
                todayTokens = today.metrics.total_tokens
                todayRequests = today.metrics.api_requests
            } else {
                todaySpend = 0; todayTokens = 0; todayRequests = 0
            }
            lastError = nil
            lastFetch = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func fetchTelemetry(apiKey: String) async {
        guard let baseURL else { return }
        var comps = URLComponents(url: baseURL.appendingPathComponent("spend/logs/v2"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "start_date", value: Self.apiDateFmt.string(from: rangeStart)),
            URLQueryItem(name: "end_date", value: Self.apiDateFmt.string(from: rangeEnd)),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "page_size", value: "1000"),
        ]
        if let userId {
            comps.queryItems?.append(URLQueryItem(name: "user_id", value: userId))
        }
        var r = URLRequest(url: comps.url!)
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: r)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(SpendLogResponse.self, from: data)
            let logs = decoded.data ?? []
            // Sample cap: API returns 1000 max per page. If total > sample, flag it.
            telemetry = Self.computeTelemetry(from: logs)
            telemetry.totalInRange = decoded.total ?? logs.count
            telemetry.wasCapped = (telemetry.totalInRange > logs.count)
            NSLog("LLMUsage telemetry: %d/%d logs, %d errors, %d cache tokens",
                  logs.count, telemetry.totalInRange, telemetry.errorCount, telemetry.cacheTokensSaved)
        } catch {
            NSLog("LLMUsage telemetry fetch error: %@", error.localizedDescription)
        }
    }

    private static func computeTelemetry(from logs: [SpendLogEntry]) -> Telemetry {
        var t = Telemetry()
        t.sampleSize = logs.count

        // Latency buckets by model.
        var latencies: [String: [Double]] = [:]
        var errorsByModel: [String: Int] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        for log in logs {
            let model = log.model ?? "unknown"

            // Latency.
            if let s = log.startTime, let e = log.endTime,
               let sd = iso.date(from: s) ?? isoNoFrac.date(from: s),
               let ed = iso.date(from: e) ?? isoNoFrac.date(from: e) {
                let ms = ed.timeIntervalSince(sd) * 1000
                if ms >= 0 && ms < 600_000 { // ignore >10min as outliers
                    latencies[model, default: []].append(ms)
                }
            }

            // Error detection: status set, or error_information present.
            let isError: Bool = {
                if let status = log.metadata?.status, !status.isEmpty,
                   status.lowercased() != "success" && status != "200" {
                    return true
                }
                if log.metadata?.error_information != nil { return true }
                return false
            }()
            if isError { errorsByModel[model, default: 0] += 1 }

            // Tokens.
            let cacheRead = log.metadata?.usage_object?.cache_read_input_tokens ?? 0
            t.cacheTokensSaved += cacheRead
        }

        t.totalRequests = logs.count
        t.errorCount = errorsByModel.values.reduce(0, +)
        t.errorRate = t.totalRequests > 0 ? Double(t.errorCount) / Double(t.totalRequests) : 0
        t.topFailingModel = errorsByModel.max { $0.value < $1.value }.map { ($0.key, $0.value) }

        // Hit-rate: cache_read_input_tokens / total_tokens (closest proxy available).
        let totalAll = logs.reduce(0) { $0 + ($1.metadata?.usage_object?.total_tokens ?? $1.total_tokens ?? 0) }
        t.cacheHitRate = totalAll > 0 ? Double(t.cacheTokensSaved) / Double(totalAll) : 0

        // Top models by latency, capped to 5 by request count.
        let top = latencies
            .filter { !$0.value.isEmpty }
            .sorted { $0.value.count > $1.value.count }
            .prefix(5)
        t.latencyByModel = top.map { (model, values) in
            let sorted = values.sorted()
            let p = { (q: Double) -> Double in
                let i = Int(Double(sorted.count - 1) * q)
                return sorted[max(0, min(i, sorted.count - 1))]
            }
            return ModelLatency(model: model, count: values.count,
                                p50: p(0.5), p95: p(0.95))
        }

        return t
    }

    private func fetchBudget(apiKey: String) async {
        guard let baseURL else { return }
        var comps = URLComponents(url: baseURL.appendingPathComponent("user/info"), resolvingAgainstBaseURL: false)!
        if let userId {
            comps.queryItems = [URLQueryItem(name: "user_id", value: userId)]
        }
        var r = URLRequest(url: comps.url!)
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: r)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                NSLog("LLMUsage budget fetch HTTP %d", (response as? HTTPURLResponse)?.statusCode ?? 0)
                return
            }
            let decoded = try JSONDecoder().decode(UserInfoResponse.self, from: data)
            // If no local user_id, adopt the one returned by /user/info so spend scopes to caller,
            // and persist it so the next launch is scoped from the first poll.
            if userId == nil, let uid = decoded.user_id {
                self.userId = uid
                self.setupUserId = uid
                try? uid.write(to: userPath, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: userPath.path
                )
                NSLog("LLMUsage auto-discovered user_id %@", uid)
            }
            budgetMax = decoded.user_info.max_budget
            budgetSpend = decoded.user_info.spend
            budgetDuration = decoded.user_info.budget_duration
            if let s = decoded.user_info.budget_reset_at {
                budgetResetsAt = Self.isoDateFmt.date(from: s)
            }
            NSLog("LLMUsage budget: max=%@ spend=%.2f duration=%@",
                  String(describing: budgetMax), budgetSpend, budgetDuration ?? "?")
            checkBudgetCrossings()
        } catch {
            NSLog("LLMUsage budget fetch error: %@", error.localizedDescription)
        }
    }

    private func checkBudgetCrossings() {
        guard notificationsAuthorized, let max = budgetMax, max > 0 else { return }
        let pct = Int((budgetSpend / max) * 100)
        for threshold in [80, 90, 100] {
            if pct >= threshold && lastNotifiedThreshold != threshold {
                lastNotifiedThreshold = threshold
                sendBudgetNotification(percent: threshold)
                break
            }
        }
        // Reset memory once spend drops below the lowest threshold (e.g. after budget reset).
        if pct < 80 { lastNotifiedThreshold = nil }
    }

    private func sendBudgetNotification(percent: Int) {
        let content = UNMutableNotificationContent()
        content.title = "LLM Budget Alert"
        content.body = "You've used \(percent)% of your $\(String(format: "%.2f", budgetMax ?? 0)) budget (rolling \(budgetDuration ?? "period"))."
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "llm-budget.\(percent)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { _ in }
        NSLog("LLMUsage notified at %d%% budget", percent)
    }

    var menuBarText: String {
        if lastError != nil { return "⚠︎" }
        return String(format: "$%.2f", rangeSpend)
    }

    var topModelsToday: [(name: String, spend: Double)] {
        guard let today = dailyBreakdown.first else { return [] }
        let models = today.breakdown?.models ?? [:]
        let pairs: [(String, Double)] = models.map { ($0.key, $0.value.metrics.spend) }
        let sorted = pairs.sorted { $0.1 > $1.1 }
        return Array(sorted.prefix(3))
    }
}
