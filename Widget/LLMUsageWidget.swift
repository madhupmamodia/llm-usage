import WidgetKit
import SwiftUI

// MARK: - Models (mirror of app's response shape)

struct DailyMetrics: Codable {
    let spend: Double
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int
    let api_requests: Int
}

struct DailyActivity: Codable {
    let date: String
    let metrics: DailyMetrics
}

struct ActivityResponse: Codable {
    let results: [DailyActivity]
}

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let todaySpend: Double
    let weekSpend: Double
    let weekTokens: Int
    let weekRequests: Int
    let lastError: String?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, todaySpend: 0, weekSpend: 0, weekTokens: 0, weekRequests: 0, lastError: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = loadEntry()
        // Refresh every 30 min (WidgetKit rate-limits aggressive refreshes)
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> UsageEntry {
        let keyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".llm-usage-key")
        let userPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".llm-usage-user")
        guard let key = try? String(contentsOf: keyPath, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return UsageEntry(date: .now, todaySpend: 0, weekSpend: 0,
                              weekTokens: 0, weekRequests: 0,
                              lastError: "no key at ~/.llm-usage-key")
        }
        let userId = (try? String(contentsOf: userPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let cal = Calendar(identifier: .iso8601)
        let now = Date()
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        let start = f.string(from: weekStart)
        let end = f.string(from: now)

        // Gateway URL: read from ~/.llm-usage-config, fall back to Multiplier default.
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".llm-usage-config")
        let storedURL = (try? String(contentsOf: configPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = (storedURL?.isEmpty == false ? storedURL : nil)
            ?? "https://llm-gateway.usemultiplier.cloud"

        var comps = URLComponents(string: "\(baseURL)/user/daily/activity")!
        var items = [
            URLQueryItem(name: "start_date", value: start),
            URLQueryItem(name: "end_date", value: end),
        ]
        if let userId, !userId.isEmpty {
            items.append(URLQueryItem(name: "user_id", value: userId))
        }
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let sema = DispatchSemaphore(value: 0)
        var entry = UsageEntry(date: .now, todaySpend: 0, weekSpend: 0,
                               weekTokens: 0, weekRequests: 0, lastError: nil)
        URLSession.shared.dataTask(with: req) { data, _, err in
            defer { sema.signal() }
            if let err {
                entry.lastError = err.localizedDescription
                return
            }
            guard let data,
                  let decoded = try? JSONDecoder().decode(ActivityResponse.self, from: data) else {
                entry.lastError = "decode failed"
                return
            }
            let weekSpend = decoded.results.reduce(0) { $0 + $1.metrics.spend }
            let weekTokens = decoded.results.reduce(0) { $0 + $1.metrics.total_tokens }
            let weekRequests = decoded.results.reduce(0) { $0 + $1.metrics.api_requests }
            let todayStr = f.string(from: now)
            let todaySpend = decoded.results.first(where: { $0.date == todayStr })?.metrics.spend ?? 0
            entry = UsageEntry(date: .now, todaySpend: todaySpend, weekSpend: weekSpend,
                               weekTokens: weekTokens, weekRequests: weekRequests, lastError: nil)
        }.resume()
        _ = sema.wait(timeout: .now() + 12)
        return entry
    }
}

// MARK: - View

struct UsageWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall: small
        case .systemMedium: medium
        default: medium
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("LLM", systemImage: "sparkles").font(.caption2).foregroundStyle(.secondary)
            Text(String(format: "$%.2f", entry.weekSpend))
                .font(.title2.weight(.semibold)).monospacedDigit()
            Text("week")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "$%.2f", entry.todaySpend))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            Text("today").font(.caption2).foregroundStyle(.tertiary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("LLM Usage", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.secondary)
                Text(String(format: "$%.2f", entry.weekSpend))
                    .font(.title.weight(.semibold)).monospacedDigit()
                Text("this week").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                row("Today", value: String(format: "$%.2f", entry.todaySpend))
                row("Tokens", value: formatTokens(entry.weekTokens))
                row("Requests", value: "\(entry.weekRequests)")
            }
            Spacer()
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Widget

struct UsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        LLMUsageWidget()
    }
}

struct LLMUsageWidget: Widget {
    let kind = "LLMUsageWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("LLM Usage")
        .description("Multipllier LLM gateway spend (week + today).")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}