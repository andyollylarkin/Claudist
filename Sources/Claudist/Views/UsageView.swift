import ClaudistCore
import GRDB
import SwiftUI

/// Subscription limits: the latest report from runs, or from a manual check.
@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var limits: UsageLimits?
    @Published private(set) var checking = false
    @Published private(set) var error: String?
    private var fromRuns: UsageLimits?
    private var fromProbe: UsageLimits?
    private var cancellable: AnyDatabaseCancellable?

    init(db: AppDatabase) {
        // The default account's limits: the one the assistant and most agents use.
        cancellable = ValueObservation.tracking { try UsageLimits.latest($0, accountId: ClaudeAccounts.defaultId) }
            .removeDuplicates()
            .start(in: db.writer, scheduling: .immediate, onError: { _ in }) { [weak self] value in
                self?.fromRuns = value
                self?.merge()
            }
    }

    /// Asks Claude Code with a tiny Haiku call (it reports the limits with every answer).
    func check() {
        guard !checking else { return }
        checking = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try UsageLimits.probe(environment: ClaudeAccounts.defaultAccountEnvironment()) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.checking = false
                switch result {
                case .success(let limits?): self.fromProbe = limits
                case .success(nil): self.error = "Claude Code didn't report the limits"
                case .failure(let e): self.error = (e as? LocalizedError)?.errorDescription ?? "\(e)"
                }
                self.merge()
            }
        }
    }

    private func merge() {
        limits = [fromRuns, fromProbe].compactMap { $0 }.max { $0.observedAt < $1.observedAt }
    }
}

enum UsageStyle {
    static func color(_ w: UsageLimits.Window) -> Color {
        if w.limited || w.utilization >= 0.9 { return Theme.red }
        if w.status == "allowed_warning" || w.utilization >= 0.7 { return .orange }
        return Theme.green
    }

    static func percent(_ u: Double) -> String { "\(Int((u * 100).rounded()))%" }

    static func resets(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return "reset" }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        let day = DateFormatter()
        day.dateFormat = seconds >= 86_400 ? "EEE d MMM, HH:mm" : "HH:mm"
        return "resets in \(f.string(from: seconds) ?? "") · \(day.string(from: date))"
    }
}

/// Compact usage line at the bottom of the sidebar; click for details.
struct UsageIndicator: View {
    @EnvironmentObject var usage: UsageMonitor
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                if let limits = usage.limits, !limits.windows.isEmpty {
                    ForEach(limits.windows.prefix(2)) { w in
                        HStack(spacing: 4) {
                            Text(w.short).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                            Bar(value: w.utilization, color: UsageStyle.color(w)).frame(width: 34, height: 4)
                            Text(UsageStyle.percent(w.utilization)).font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(w.utilization >= 0.7 || w.limited ? UsageStyle.color(w) : Theme.secondary)
                        }
                    }
                } else {
                    Text("Usage limits").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Claude subscription limits")
        .popover(isPresented: $open, arrowEdge: .trailing) { UsageDetails().environmentObject(usage) }
    }
}

private struct Bar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.divider)
                Capsule().fill(color).frame(width: max(2, geo.size.width * min(1, max(0, value))))
            }
        }
    }
}

struct UsageDetails: View {
    @EnvironmentObject var usage: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claude usage limits").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
            if let limits = usage.limits {
                ForEach(limits.windows) { w in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(w.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                            Spacer()
                            Text(UsageStyle.percent(w.utilization) + " used").font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(UsageStyle.color(w))
                        }
                        Bar(value: w.utilization, color: UsageStyle.color(w)).frame(height: 6)
                        HStack {
                            if w.limited {
                                Text("Limit reached — agents can't run until it resets").font(.system(size: 11)).foregroundStyle(Theme.red)
                            } else if w.status == "allowed_warning" {
                                Text("Close to the limit").font(.system(size: 11)).foregroundStyle(.orange)
                            }
                            Spacer()
                            Text(UsageStyle.resets(w.resetsAt)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        }
                    }
                }
                if limits.isUsingOverage {
                    Text("Using extra usage beyond the plan").font(.system(size: 11)).foregroundStyle(.orange)
                } else if limits.overageStatus == "rejected" {
                    Text("Extra usage is off: at a limit, runs stop until it resets").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                Text("As of \(RunHistoryView.when(limits.observedAt)) — updated with every agent run")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            } else {
                Text("No data yet: limits arrive with the next agent run, or check now.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            if let error = usage.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.red).lineLimit(3).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button { usage.check() } label: {
                    HStack(spacing: 6) {
                        if usage.checking { ProgressView().controlSize(.mini) }
                        Text(usage.checking ? "Checking…" : "Check now")
                    }
                }
                .buttonStyle(AccentButtonStyle(prominent: false))
                .disabled(usage.checking)
                .help("A tiny Haiku request; Claude Code reports the limits with it")
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}
