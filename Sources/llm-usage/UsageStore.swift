import Foundation
import Combine
import UserNotifications

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
    @Published var budgetMax: Double?
    @Published var budgetSpend: Double = 0
    @Published var budgetDuration: String?
    @Published var budgetResetsAt: Date?
    @Published private var lastNotifiedThreshold: Int?
    @Published var notificationsAuthorized: Bool = false

    private var timer: Timer?
    private var apiKey: String?
    private var userId: String?
    private var baseURL: URL?
    static let defaultURL = ""  // intentionally empty — user must provide

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

    private let keyPath: URL
    private let userPath: URL
    private let configPath: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.keyPath = home.appendingPathComponent(".llm-usage-key")
        self.userPath = home.appendingPathComponent(".llm-usage-user")
        self.configPath = home.appendingPathComponent(".llm-usage-config")

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
        }

        Task { await requestNotificationPermission() }
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
        Task { await fetch() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in await self.fetch() }
        }
    }

    func openSetup() {
        setupKey = apiKey ?? ""
        setupUserId = userId ?? ""
        setupURL = baseURL?.absoluteString ?? ""
        needsSetup = true
    }

    func fetch() async {
        guard let apiKey else {
            lastError = "No API key at ~/.llm-usage-key"
            return
        }
        guard let baseURL else {
            lastError = "No gateway URL configured"
            return
        }
        isLoading = true
        defer { isLoading = false }

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

        // Budget is rolling (e.g. 7d) — independent of selected date range.
        await fetchBudget(apiKey: apiKey)
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
