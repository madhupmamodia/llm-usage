import SwiftUI
import AppKit

@main
struct LLMUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            Image(systemName: "chart.bar.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct MenuContent: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        if store.needsSetup {
            SetupView(store: store)
        } else if store.showCustomRange {
            CustomRangeView(store: store)
        } else {
            StatsView(store: store)
        }
    }
}

struct SetupView: View {
    @ObservedObject var store: UsageStore
    @FocusState private var keyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("LLM Usage — Setup", systemImage: "chart.bar.fill")
                .font(.headline)
            Text("Paste your LLM gateway API key. Find it in 1Password or ask the platform team.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("API key").font(.caption2).foregroundStyle(.secondary)
                    if store.detectedFromZshrc {
                        Text("detected from ~/.zshrc")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                SecureField("sk-...", text: $store.setupKey)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFocused)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Gateway URL").font(.caption2).foregroundStyle(.secondary)
                TextField("https://your-gateway.example.com", text: $store.setupURL)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Your user_id (optional — scopes to your spend)").font(.caption2).foregroundStyle(.secondary)
                TextField("e.g. 6647xxxxxxxxxxxx", text: $store.setupUserId)
                    .textFieldStyle(.roundedBorder)
            }

            if let err = store.lastError {
                Text("⚠︎ \(err)").font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Save") { store.saveCredentials() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.setupKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { keyFocused = true }
    }
}

struct StatsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            navHeader
            if let err = store.lastError {
                errorBanner(err)
            } else if store.isShowingStale, let last = store.lastFetch {
                Label("stale — last successful \(last.formatted(date: .omitted, time: .standard))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            row("Today",    String(format: "$%.2f", store.todaySpend))
            row(rangeTitle, String(format: "$%.2f", store.rangeSpend))
            row("Tokens",   formatTokens(store.rangeTokens), secondary: true)
            row("Requests", "\(store.rangeRequests)", secondary: true)

            if store.hasBudget {
                Divider().padding(.vertical, 2)
                budgetSection
            }

            if store.telemetry.sampleSize > 0 {
                Divider().padding(.vertical, 2)
                telemetrySection
            }

            if !store.topModelsToday.isEmpty {
                Divider().padding(.vertical, 2)
                Text("Top models today")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(store.topModelsToday, id: \.name) { item in
                    modelRow(name: shortName(item.name),
                             spend: String(format: "$%.2f", item.spend))
                }
            }

            if let last = store.lastFetch {
                Divider().padding(.vertical, 2)
                Text("Updated \(last.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider().padding(.vertical, 2)
            HStack {
                Button(store.isLoading ? "Refreshing…" : "Refresh") {
                    Task { await store.fetch() }
                }
                .disabled(store.isLoading)
                Button("Change key") { store.openSetup() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func errorBanner(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("⚠︎ \(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Spacer()
                Button("Retry") { Task { await store.fetch() } }
                    .controlSize(.small)
                    .disabled(store.isLoading)
            }
            if Self.looksLikeNetworkError(err) {
                Text("Check VPN or gateway URL in setup.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let last = store.lastFetch {
                Text("Last good fetch: \(last.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static func looksLikeNetworkError(_ msg: String) -> Bool {
        let s = msg.lowercased()
        let needles = ["timed out", "timeout", "network", "connection",
                       "unreachable", "offline", "could not connect", "host is down"]
        return needles.contains { s.contains($0) }
    }

    private var rangeTitle: String {
        store.isCurrentWeek ? "This week" : "Range"
    }

    private var navHeader: some View {
        HStack(spacing: 4) {
            Button { store.shiftRange(byWeeks: -1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)

            Text(store.rangeLabel)
                .font(.system(size: 12).monospacedDigit())
                .frame(minWidth: 110)

            Button { store.shiftRange(byWeeks: 1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(store.isCurrentWeek)
            .opacity(store.isCurrentWeek ? 0.3 : 1.0)

            Spacer(minLength: 8)

            Menu {
                Button("Jump to current week") { store.jumpToCurrentWeek() }
                    .disabled(store.isCurrentWeek)
                Divider()
                Button("Custom range…") { store.openCustomRange() }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.bottom, 6)
    }

    private func row(_ label: String, _ value: String, secondary: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(secondary ? .secondary : .primary)
            Spacer(minLength: 16)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(secondary ? .secondary : .primary)
        }
        .font(.system(size: 12))
    }

    private func modelRow(name: String, spend: String) -> some View {
        HStack {
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(spend)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
    }

    private func shortName(_ s: String) -> String {
        s.split(separator: "/").last.map(String.init) ?? s
    }

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Budget")
                    .foregroundStyle(.secondary)
                if let dur = store.budgetDuration {
                    Text("rolling \(dur)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("\(formatSpend(store.budgetSpend)) / \(formatSpend(store.budgetMax ?? 0))")
                    .monospacedDigit()
            }
            .font(.system(size: 12))

            ProgressView(value: store.budgetFraction)
                .progressViewStyle(.linear)
                .tint(budgetTint(store.budgetFraction))

            HStack {
                Text("\(Int(store.budgetFraction * 100))% used")
                Spacer()
                if let days = store.budgetDaysUntilReset {
                    Text("resets in \(days)d")
                } else if let _ = store.budgetResetsAt {
                    Text("resets soon")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
    }

    private func formatSpend(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }

    private func budgetTint(_ fraction: Double) -> Color {
        if fraction >= 0.9 { return .red }
        if fraction >= 0.7 { return .orange }
        return .green
    }

    private var telemetrySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Telemetry (last 24h)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !store.telemetry.latencyByModel.isEmpty {
                Text("Latency (p50 / p95)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach(store.telemetry.latencyByModel) { m in
                    HStack {
                        Text(shortName(m.model))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text("\(formatMs(m.p50)) / \(formatMs(m.p95))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                }
            }

            HStack {
                Text("Errors").foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(errorText)
                    .monospacedDigit()
                    .foregroundStyle(errorColor)
            }
            .font(.caption2)

            if let top = store.telemetry.topFailingModel {
                HStack {
                    Text("Top failing").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(shortName(top.name)) (\(top.count))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
            }

            if store.telemetry.cacheTokensSaved > 0 {
                HStack {
                    Text("Cache hit").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(Int(store.telemetry.cacheHitRate * 100))% (\(formatTokens(store.telemetry.cacheTokensSaved)) tok)")
                        .monospacedDigit()
                        .foregroundStyle(.green)
                }
                .font(.caption2)
            }

            if store.telemetry.inputTokens > 0 {
                HStack {
                    Text("Token eff.").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("1 : \(String(format: "%.1f", store.telemetry.tokenEfficiency))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("  (out:in)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
            }
        }
    }

    private var errorText: String {
        let t = store.telemetry
        if t.totalRequests == 0 { return "—" }
        let pct = Int(t.errorRate * 100)
        let suffix = t.errorRate == 0 ? "0%" : String(format: "%d%% (%d of %d)", pct, t.errorCount, t.totalRequests)
        if pct == 0 { return "0 errors" }
        return suffix
    }

    private var errorColor: Color {
        let r = store.telemetry.errorRate
        if r >= 0.05 { return .red }
        if r >= 0.02 { return .orange }
        return .secondary
    }

    private func formatMs(_ ms: Double) -> String {
        if ms < 1000 { return String(format: "%.0fms", ms) }
        return String(format: "%.1fs", ms / 1000)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

struct CustomRangeView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Custom date range", systemImage: "calendar")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Start (DD/MM/YY)").font(.caption2).foregroundStyle(.secondary)
                TextField("05/10/26", text: $store.customStartText)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("End (DD/MM/YY)").font(.caption2).foregroundStyle(.secondary)
                TextField("12/10/26", text: $store.customEndText)
                    .textFieldStyle(.roundedBorder)
            }

            if let err = store.lastError {
                Text("⚠︎ \(err)").font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { store.showCustomRange = false; store.lastError = nil }
                Spacer()
                Button("Apply") { store.applyCustomRange() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}
