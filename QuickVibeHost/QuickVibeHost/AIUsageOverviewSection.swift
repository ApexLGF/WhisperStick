import SwiftUI

// Visual concepts are adapted from TokenRemain (Apache-2.0), using only
// QuickVibeHost-owned icons and styling. See ThirdParty/TOKENREMAIN_NOTICE.

struct AIQuotaWindowPresentation: Identifiable {
    let id: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date?

    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
}

struct AIAPIUsagePeriodPresentation {
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheCreationTokens: Int64
    let cacheReadTokens: Int64
    let estimatedCost: Double?
    let unpricedModels: [String]
}

struct AIAPIUsagePresentation {
    let today: AIAPIUsagePeriodPresentation
    let yesterday: AIAPIUsagePeriodPresentation
    let thirtyDays: AIAPIUsagePeriodPresentation
    let updatedAt: Date
}

struct AICreditUsagePresentation {
    let today: Double?
    let historical: Double
    let updatedAt: Date?
}

struct AIProviderCardPresentation: Identifiable {
    let id: String
    let displayName: String
    let iconAssetName: String
    let usesSystemIcon: Bool
    let badge: (text: String, isPlan: Bool)?
    let badgeHelp: String?
    let activeSessionCount: Int
    let totalSessionCount: Int
    let billingMode: AgentBillingMode
    let windows: [AIQuotaWindowPresentation]
    let apiUsage: AIAPIUsagePresentation?
    let creditUsage: AICreditUsagePresentation?
    let sevenDayPeaks: [Double?]?
    let lastUpdated: Date?
    let exclusiveName: String?
    let awaitingFirstData: Bool
}

struct AIUsageOverviewSection: View {
    let providers: [AIProviderCardPresentation]
    @ObservedObject var localUsage: LocalAIUsageManager
    var onRefreshProviders: () -> Void = {}
    @AppStorage("statusAIUsageExpanded") private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                        Text(AppL10n.tr("AI 用量"))
                            .font(.headline)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? AppL10n.tr("收起详情") : AppL10n.tr("展开详情"))
                Spacer()
                if isExpanded {
                    Button {
                        onRefreshProviders()
                        Task { await localUsage.refresh(force: true) }
                    } label: {
                        if localUsage.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(AppL10n.tr("刷新本地用量"))
                    .disabled(localUsage.isRefreshing)
                }
            }

            if isExpanded {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 350), spacing: 16, alignment: .top)],
                    spacing: 16
                ) {
                    ForEach(providers) { provider in
                        AIProviderQuotaCard(model: provider)
                    }
                    LocalAIUsageCard(manager: localUsage)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .task(id: isExpanded) {
            guard isExpanded else { return }
            onRefreshProviders()
            await localUsage.refresh()
        }
    }
}

private struct AIProviderQuotaCard: View {
    let model: AIProviderCardPresentation
    @State private var isExpanded = false

    private var accent: Color {
        switch model.id.lowercased() {
        case "cc", "claude": Color(red: 0.75, green: 0.52, blue: 0.44)
        case "codex": Color(red: 0.40, green: 0.53, blue: 0.77)
        case "workbuddy": Color(red: 0.42, green: 0.39, blue: 0.92)
        default: .accentColor
        }
    }

    private var hasExpandableDetails: Bool {
        !model.windows.isEmpty || model.apiUsage != nil || model.exclusiveName != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header

            Divider().opacity(0.5)

            if let creditUsage = model.creditUsage {
                creditUsageContent(creditUsage)
            } else {
                switch model.billingMode {
                case .api:
                    apiUsageContent
                case .subscription:
                    quotaContent
                case .unknown:
                    Text(AppL10n.tr("认证方式待确认"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .animation(.snappy, value: isExpanded)
    }

    private func creditUsageContent(_ usage: AICreditUsagePresentation) -> some View {
        VStack(spacing: 9) {
            creditRow(label: AppL10n.tr("今日积分消耗"), value: usage.today)
            Divider().opacity(0.45)
            creditRow(label: AppL10n.tr("历史积分消耗"), value: usage.historical)
            HStack {
                Text(AppL10n.tr("仅统计本机已记录的 WorkBuddy 会话"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if let updatedAt = usage.updatedAt {
                    Text(AppL10n.format("更新 %@", Self.updatedFormatter.string(from: updatedAt)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func creditRow(label: String, value: Double?) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.map(Self.formatCredits) ?? "--")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private static func formatCredits(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded.rounded() == rounded
            ? String(format: "%.0f", rounded)
            : String(format: "%.2f", rounded)
    }

    private var header: some View {
        HStack(spacing: 7) {
            if model.usesSystemIcon {
                Image(systemName: model.iconAssetName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 20, height: 20)
            } else {
                Image(model.iconAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
            }

            Text(model.displayName)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)

            if let badge = model.badge {
                Text(badge.text)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(badge.isPlan ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            badge.isPlan
                                ? AnyShapeStyle(Color.orange.gradient)
                                : AnyShapeStyle(Color.primary.opacity(0.08))
                        )
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.badgeHelp ?? badge.text)
            }

            Spacer(minLength: 4)

            Text(AppL10n.format("会话 %@/%@", String(model.activeSessionCount), String(model.totalSessionCount)))
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)

            if hasExpandableDetails {
                Button { isExpanded.toggle() } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 18, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isExpanded ? AppL10n.tr("收起详情") : AppL10n.tr("展开详情"))
            }
        }
    }

    @ViewBuilder
    private var quotaContent: some View {
        if let primary = model.windows.first {
            quotaRow(primary)
            if isExpanded {
                ForEach(Array(model.windows.dropFirst())) { window in
                    Divider().opacity(0.45)
                    quotaRow(window)
                }
                expandedDetails
            }
        } else if model.awaitingFirstData {
            loadingRow
        } else {
            unavailableRow
        }
    }

    @ViewBuilder
    private var apiUsageContent: some View {
        if let usage = model.apiUsage {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(AppL10n.tr("今日 API 用量"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(AppL10n.format("更新 %@", Self.updatedFormatter.string(from: usage.updatedAt)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                apiPrimaryMetrics(usage.today)
                cacheSummary(usage.today)
                if isExpanded {
                    Divider().opacity(0.45)
                    apiPeriodRow(label: AppL10n.tr("昨日"), usage.yesterday)
                    apiPeriodRow(label: AppL10n.tr("近30天"), usage.thirtyDays)
                    if !usage.thirtyDays.unpricedModels.isEmpty {
                        Label(
                            AppL10n.format("以下模型价格不可用：%@", usage.thirtyDays.unpricedModels.joined(separator: ", ")),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(AppL10n.tr("费用按公开 API 单价估算，实际费用以服务商账单为准"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    expandedDetails
                }
            }
        } else if model.awaitingFirstData {
            loadingRow
        } else {
            unavailableRow
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(AppL10n.tr("等待首次用量数据"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var unavailableRow: some View {
        Text(AppL10n.tr("用量不可用"))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func apiPrimaryMetrics(_ period: AIAPIUsagePeriodPresentation) -> some View {
        HStack(spacing: 8) {
            apiMetric(label: AppL10n.tr("Input"), value: Self.compact(period.inputTokens))
            apiMetric(label: AppL10n.tr("Output"), value: Self.compact(period.outputTokens))
            apiMetric(
                label: AppL10n.tr("估算费用"),
                value: period.estimatedCost.map(Self.currency) ?? AppL10n.tr("价格不可用")
            )
        }
    }

    private func apiMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cacheSummary(_ period: AIAPIUsagePeriodPresentation) -> some View {
        if period.cacheCreationTokens > 0 || period.cacheReadTokens > 0 {
            Text(AppL10n.format("缓存写入 %@ · 缓存读取 %@",
                                Self.compact(period.cacheCreationTokens),
                                Self.compact(period.cacheReadTokens)))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func apiPeriodRow(label: String, _ period: AIAPIUsagePeriodPresentation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(AppL10n.format(
                    "Input %@ · Output %@ · %@",
                    Self.compact(period.inputTokens),
                    Self.compact(period.outputTokens),
                    period.estimatedCost.map(Self.currency) ?? AppL10n.tr("价格不可用")
                ))
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            cacheSummary(period)
        }
    }

    private func quotaRow(_ window: AIQuotaWindowPresentation) -> some View {
        let remaining = window.remainingPercent
        let isCritical = remaining < 10
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                if isCritical {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                Text(AppL10n.format("剩余 %@%%", String(Int(remaining.rounded()))))
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
            }

            UsageSegmentBar(
                value: remaining / 100,
                accent: isCritical ? .red : accent
            )

            if isExpanded, let reset = window.resetsAt {
                Text(AppL10n.format("%@ 重置", Self.resetFormatter.string(from: reset)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var expandedDetails: some View {
        if let peaks = model.sevenDayPeaks {
            Divider().opacity(0.45)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(AppL10n.tr("近7天额度峰值"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let updated = model.lastUpdated {
                        Text(AppL10n.format("更新 %@", Self.updatedFormatter.string(from: updated)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                SevenDayQuotaBars(peaks: peaks)
            }
        }

        if let exclusiveName = model.exclusiveName {
            Divider().opacity(0.45)
            HStack {
                Label(AppL10n.tr("直通"), systemImage: "target")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text(exclusiveName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    private static let updatedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    private static func compact(_ value: Int64) -> String {
        let magnitude = Double(value)
        if magnitude >= 1_000_000_000 { return String(format: "%.2fB", magnitude / 1_000_000_000) }
        if magnitude >= 1_000_000 { return String(format: "%.2fM", magnitude / 1_000_000) }
        if magnitude >= 1_000 { return String(format: "%.1fK", magnitude / 1_000) }
        return String(value)
    }

    private static func currency(_ value: Double) -> String {
        value >= 1_000 ? String(format: "$%.1fK", value / 1_000) : String(format: "$%.2f", value)
    }
}

private struct LocalAIUsageCard: View {
    @ObservedObject var manager: LocalAIUsageManager
    @State private var hoveredAgentID: String?

    private var today: LocalAIUsageSnapshot.Day? {
        manager.snapshot?.day(at: .now)
    }

    private var entries: [LocalAIUsageSnapshot.Agent] {
        (today?.agents ?? []).filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }
    }

    private var totalTokens: Int64 { entries.reduce(0) { $0 + $1.tokens } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppL10n.tr("今日本地统计"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if let cost = today?.estimatedCost {
                    Text(Self.currency(cost))
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .help(AppL10n.tr("按公开 API 单价估算，不代表订阅账单"))
                } else if !entries.isEmpty {
                    Text(AppL10n.tr("价格不可用"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            content

            if let snapshot = manager.snapshot {
                Divider().opacity(0.5)
                spendRows(snapshot)
                HStack(alignment: .bottom, spacing: 8) {
                    Text(AppL10n.tr("用量趋势"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    UsageMiniBarChart(values: snapshot.tokenTrend())
                        .frame(maxWidth: 170)
                        .frame(height: 24)
                }
            }

            if !unpricedModels.isEmpty {
                Label(
                    AppL10n.format("以下模型价格不可用：%@", unpricedModels.joined(separator: ", ")),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(AppL10n.tr("费用为本地日志按公开 API 单价计算的估算值"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        if !entries.isEmpty {
            HStack(alignment: .center, spacing: 14) {
                UsageRingChart(
                    segments: entries.map {
                        .init(id: $0.id, value: Double($0.tokens), color: Self.color(for: $0.id))
                    },
                    highlightedID: hoveredAgentID,
                    onHover: { hoveredAgentID = $0 }
                )
                .frame(width: 78, height: 78)

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entries) { entry in
                        providerRow(entry)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            switch manager.state {
            case .loading, .idle:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppL10n.tr("正在读取本地 AI 用量…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .empty, .available:
                Label(AppL10n.tr("今天还没有本地 AI 用量记录"), systemImage: "moon.zzz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func providerRow(_ entry: LocalAIUsageSnapshot.Agent) -> some View {
        let share = totalTokens > 0 ? Double(entry.tokens) / Double(totalTokens) * 100 : 0
        let highlighted = hoveredAgentID == entry.id
        return HStack(spacing: 7) {
            Circle()
                .fill(Self.color(for: entry.id))
                .frame(width: 7, height: 7)
            Text(Self.displayName(for: entry.id))
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(Self.compact(entry.tokens))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("\(Int(share.rounded()))%")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(highlighted ? Self.color(for: entry.id) : .primary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(
            highlighted ? Color.primary.opacity(0.07) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onHover { hoveredAgentID = $0 ? entry.id : nil }
    }

    private func spendRows(_ snapshot: LocalAIUsageSnapshot) -> some View {
        let todayTotal = snapshot.total(days: 1)
        let yesterdayDate = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let yesterday = snapshot.day(at: yesterdayDate)
        let month = snapshot.total(days: 30)
        return VStack(spacing: 5) {
            spendRow(label: AppL10n.tr("今日"), tokens: todayTotal.tokens, cost: todayTotal.cost)
            spendRow(
                label: AppL10n.tr("昨日"),
                tokens: yesterday?.totalTokens ?? 0,
                cost: yesterday == nil ? 0 : yesterday?.estimatedCost
            )
            spendRow(label: AppL10n.tr("近30天"), tokens: month.tokens, cost: month.cost)
        }
    }

    private func spendRow(label: String, tokens: Int64, cost: Double?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("\(cost.map(Self.currency) ?? AppL10n.tr("价格不可用")) · \(Self.compact(tokens)) tokens")
                .font(.caption.monospacedDigit())
                .lineLimit(1)
        }
    }

    private var unpricedModels: [String] {
        Array(Set(entries.flatMap(\.unpricedModels))).sorted()
    }

    private static func displayName(for id: String) -> String {
        switch id.lowercased() {
        case "claude": "Claude"
        case "codex": "Codex"
        default: id
        }
    }

    private static func color(for id: String) -> Color {
        switch id.lowercased() {
        case "claude": Color(red: 0.75, green: 0.52, blue: 0.44)
        case "codex": Color(red: 0.40, green: 0.53, blue: 0.77)
        default: .secondary
        }
    }

    fileprivate static func compact(_ value: Int64) -> String {
        let magnitude = Double(value)
        if magnitude >= 1_000_000_000 { return String(format: "%.2fB", magnitude / 1_000_000_000) }
        if magnitude >= 1_000_000 { return String(format: "%.2fM", magnitude / 1_000_000) }
        if magnitude >= 1_000 { return String(format: "%.1fK", magnitude / 1_000) }
        return String(value)
    }

    private static func currency(_ value: Double) -> String {
        value >= 1_000 ? String(format: "$%.1fK", value / 1_000) : String(format: "$%.2f", value)
    }
}

private struct UsageSegmentBar: View {
    let value: Double
    let accent: Color
    var segments = 14

    private var filledCount: Int {
        let clamped = min(1, max(0, value))
        if clamped > 0 && clamped * Double(segments) < 1 { return 1 }
        return min(segments, Int((clamped * Double(segments)).rounded()))
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index < filledCount ? accent : Color.primary.opacity(0.07))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}

private struct SevenDayQuotaBars: View {
    let peaks: [Double?]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(peaks.enumerated()), id: \.offset) { offset, peak in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.06))
                    if let peak {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(peak <= 50 ? Color.green : (peak <= 80 ? .yellow : .red))
                            .frame(height: max(3, 28 * min(100, peak) / 100))
                    }
                    Text(weekday(offset))
                        .font(.caption2)
                        .foregroundStyle(offset == peaks.count - 1 ? .primary : .secondary)
                        .padding(.bottom, 7)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
            }
        }
    }

    private func weekday(_ offset: Int) -> String {
        let delta = offset - peaks.count + 1
        let date = Calendar.current.date(byAdding: .day, value: delta, to: Date()) ?? Date()
        let index = Calendar.current.component(.weekday, from: date) - 1
        return Self.weekdayFormatter.veryShortWeekdaySymbols[index]
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        return formatter
    }()
}

private struct UsageRingChart: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    let highlightedID: String?
    let onHover: (String?) -> Void

    private var total: Double { max(0, segments.reduce(0) { $0 + $1.value }) }
    private var arcs: [(Segment, Double, Double)] {
        guard total > 0 else { return [] }
        var running = 0.0
        return segments.map { segment in
            let start = running / total
            running += segment.value
            return (segment, start, running / total)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 12)
                ForEach(arcs, id: \.0.id) { segment, start, end in
                    Circle()
                        .trim(from: start, to: end)
                        .stroke(
                            segment.color.opacity(highlightedID == nil || highlightedID == segment.id ? 1 : 0.3),
                            style: StrokeStyle(lineWidth: highlightedID == segment.id ? 14 : 12, lineCap: .butt)
                        )
                        .rotationEffect(.degrees(-90))
                }
                Text(LocalAIUsageCard.compact(Int64(total)))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .minimumScaleFactor(0.7)
            }
            .contentShape(Circle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): onHover(segment(at: point, size: proxy.size))
                case .ended: onHover(nil)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func segment(at point: CGPoint, size: CGSize) -> String? {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let distance = hypot(point.x - center.x, point.y - center.y)
        let outer = min(size.width, size.height) / 2 + 2
        guard distance >= outer - 18, distance <= outer else { return nil }
        var degrees = atan2(point.y - center.y, point.x - center.x) * 180 / .pi + 90
        if degrees < 0 { degrees += 360 }
        let fraction = degrees / 360
        return arcs.first { fraction >= $0.1 && fraction < $0.2 }?.0.id
    }
}

private struct UsageMiniBarChart: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let maximum = max(values.max() ?? 0, 0)
            let slot = size.width / CGFloat(values.count)
            for (index, value) in values.enumerated() {
                let ratio = maximum > 0 ? max(0.08, value / maximum) : 0
                let height = maximum > 0 && value > 0 ? size.height * ratio : min(2, size.height)
                let width = max(2, min(10, slot - 2))
                let rect = CGRect(
                    x: CGFloat(index) * slot + (slot - width) / 2,
                    y: size.height - height,
                    width: width,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(width, height) / 2),
                    with: .color(Color.secondary.opacity(index == values.count - 1 ? 1 : 0.5))
                )
            }
        }
        .accessibilityHidden(true)
    }
}
