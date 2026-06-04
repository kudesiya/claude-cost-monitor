import SwiftUI
import AppKit
import Combine

@main
struct CCUsageStatusApp: App {
    @StateObject private var model = CCUsageModel()

    var body: some Scene {
        MenuBarExtra(model.menuTitle) {
            Text(model.todayText)
            Text(model.totalText)
            Text(model.tokensText)
            Text(model.projectionText)
            Text(model.trendText)

            Divider()

            Text("Models")
            Text(model.modelsText)

            Divider()

            Text(model.updatedText)

            Divider()

            Toggle("Auto Refresh (5 min)", isOn: $model.autoRefresh)
                .onChange(of: model.autoRefresh) { enabled in
                    enabled ? model.startTimer() : model.stopTimer()
                }

            Button("Refresh Now") {
                model.refresh()
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

final class CCUsageModel: ObservableObject {
    @Published var menuTitle = "Loading..."
    @Published var todayText = "Today: Loading..."
    @Published var totalText = "Total: Loading..."
    @Published var tokensText = "Tokens: Loading..."
    @Published var projectionText = "Projected Month: Loading..."
    @Published var trendText = "Trend: Loading..."
    @Published var modelsText = "Models: Loading..."
    @Published var updatedText = "Last Refresh: Loading..."
    @Published var autoRefresh = true

    private var refreshTimer: Timer?

    init() {
        refresh()
        startTimer()
    }

    func startTimer() {
        stopTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            self.refresh()
        }
    }

    func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        let jsonOutput = runCommand("npx ccusage --json")

        guard let data = jsonOutput.data(using: .utf8) else {
            setError("No data")
            return
        }

        do {
            let usage = try JSONDecoder().decode(CCUsageResponse.self, from: data)
            updateDisplay(from: usage)
        } catch {
            setError("Parse error")
        }
    }

    func updateDisplay(from usage: CCUsageResponse) {
        guard let latest = usage.daily.last else {
            setError("No usage")
            return
        }

        let todayCost = latest.totalCost
        let todayTokens = latest.totalTokens
        let totalCost = usage.totals.totalCost

        let indicator: String
        if todayCost < 100 {
            indicator = "🟢"
        } else if todayCost < 200 {
            indicator = "🟡"
        } else {
            indicator = "🔴"
        }

        let yesterdayCost = usage.daily.count >= 2 ? usage.daily[usage.daily.count - 2].totalCost : 0
        let diff = todayCost - yesterdayCost
        let trendPct = yesterdayCost > 0 ? (diff / yesterdayCost) * 100 : 0

        let projectedMonth = calculateProjectedMonth(daily: usage.daily, latestPeriod: latest.period)

        let modelBreakdown = latest.modelBreakdowns
            .map { item in
                "\(shortModelName(item.modelName)) $\(String(format: "%.2f", item.cost))"
            }
            .joined(separator: " • ")

        let refreshTime = Self.timeFormatter.string(from: Date())

        DispatchQueue.main.async {
            self.menuTitle = "\(indicator) CC $\(String(format: "%.2f", todayCost))"
            self.todayText = "Today $\(String(format: "%.2f", todayCost))"
            self.totalText = "Total $\(String(format: "%.2f", totalCost))"
            self.tokensText = "Tokens \(self.formatTokens(todayTokens))"
            self.projectionText = "Projected Month $\(String(format: "%.0f", projectedMonth))"
            self.trendText = "Yesterday $\(String(format: "%.2f", yesterdayCost)) • Δ $\(String(format: "%.2f", diff)) (\(String(format: "%+.0f", trendPct))%)"
            self.modelsText = modelBreakdown.isEmpty ? "Models N/A" : modelBreakdown
            self.updatedText = "Last Refresh \(refreshTime)"
        }
    }

    func calculateProjectedMonth(daily: [DailyUsage], latestPeriod: String) -> Double {
        let monthPrefix = String(latestPeriod.prefix(7))
        let monthRows = daily.filter { $0.period.hasPrefix(monthPrefix) }
        let monthCost = monthRows.reduce(0) { $0 + $1.totalCost }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        guard let latestDate = formatter.date(from: latestPeriod),
              let range = Calendar.current.range(of: .day, in: .month, for: latestDate)
        else {
            return monthCost
        }

        let day = Calendar.current.component(.day, from: latestDate)
        let daysInMonth = range.count

        return (monthCost / Double(day)) * Double(daysInMonth)
    }

    func shortModelName(_ name: String) -> String {
        if name.contains("opus") { return "Opus" }
        if name.contains("sonnet") { return "Sonnet" }
        if name.contains("haiku") { return "Haiku" }
        return name
    }

    func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }

    func setError(_ message: String) {
        DispatchQueue.main.async {
            self.menuTitle = "CC Err"
            self.todayText = message
            self.totalText = ""
            self.tokensText = ""
            self.projectionText = ""
            self.trendText = ""
            self.modelsText = ""
            self.updatedText = ""
        }
    }

    func runCommand(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}

struct CCUsageResponse: Codable {
    let daily: [DailyUsage]
    let totals: TotalsUsage
}

struct DailyUsage: Codable {
    let period: String
    let totalCost: Double
    let totalTokens: Int
    let modelBreakdowns: [ModelBreakdown]
}

struct ModelBreakdown: Codable {
    let modelName: String
    let cost: Double
}

struct TotalsUsage: Codable {
    let totalCost: Double
    let totalTokens: Int
}
