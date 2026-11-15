import SwiftUI

struct HistoryTab: View {
    @EnvironmentObject var historyManager: RecognitionHistoryManager
    @EnvironmentObject var voiceManager: VoiceInputManager
    @State private var retryingIds: Set<UUID> = []
    @State private var copiedIds: Set<UUID> = []
    @State private var copyFailedIds: Set<UUID> = []
    @State private var copyHoverIds: Set<UUID> = []
    @State private var confirmingClear = false
    @State private var isClearHovering = false
    @AppStorage("collapsedHistoryDateGroups") private var collapsedDateGroupsData = "[]"
    @State private var collapsedDateGroups: Set<String> = []

    private var filteredRecords: [RecognitionRecord] {
        historyManager.records
    }

    private var groupedRecords: [(String, [RecognitionRecord])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        var groups: [(String, [RecognitionRecord])] = []
        var currentLabel: String?
        var currentRecords: [RecognitionRecord] = []

        for record in filteredRecords {
            let day = calendar.startOfDay(for: record.timestamp)
            let label: String
            if day == today {
                label = AppL10n.tr("今天")
            } else if day == yesterday {
                label = AppL10n.tr("昨天")
            } else {
                label = Self.dateFormatter.string(from: record.timestamp)
            }

            if currentLabel == label {
                currentRecords.append(record)
            } else {
                if let currentLabel {
                    groups.append((currentLabel, currentRecords))
                }
                currentLabel = label
                currentRecords = [record]
            }
        }
        if let currentLabel { groups.append((currentLabel, currentRecords)) }
        return groups
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = AppL10n.tr("yyyy年M月d日")
        return formatter
    }()

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if historyManager.records.isEmpty {
                    emptyState(AppL10n.tr("暂无识别记录"))
                } else {
                    header

                    if filteredRecords.isEmpty {
                        emptyState(AppL10n.tr("暂无记录"))
                    } else {
                        ForEach(groupedRecords, id: \.0) { dateLabel, records in
                            historyDateGroup(dateLabel, records: records)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        .onAppear(perform: syncCollapsedDateGroups)
        .onChange(of: groupedRecords.map(\.0)) { _, labels in
            syncCollapsedDateGroups(labels: labels)
        }
        .confirmationDialog(
            AppL10n.tr("清除所有识别历史？"),
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button(AppL10n.tr("清除"), role: .destructive) { clearHistory() }
            Button(AppL10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(AppL10n.tr("会同时删除可重试记录保存的音频数据。"))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(AppL10n.tr("识别历史"))
                    .font(.headline)
                Spacer()
                Button {
                    confirmingClear = true
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isClearHovering ? Color.red : Color.secondary.opacity(0.55))
                .onHover { isClearHovering = $0 }
                .help(AppL10n.tr("清除历史"))
            }
        }
    }

    private func historyDateGroup(_ dateLabel: String, records: [RecognitionRecord]) -> some View {
        let isCollapsed = collapsedDateGroups.contains(dateLabel)

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                toggleCollapsedDateGroup(dateLabel)
            } label: {
                HStack(spacing: 6) {
                    Text(dateLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(records.count)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)

                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(0.75))
                        .frame(width: 22, height: 22)
                }
                .padding(.vertical, 2)
                .padding(.leading, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? AppL10n.tr("展开") : AppL10n.tr("折叠"))

            if !isCollapsed {
                LazyVStack(spacing: 6) {
                    ForEach(records) { record in
                        recordRow(record)
                    }
                }
            }
        }
        .historyPanel()
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 40)
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
        .historyPanel()
    }

    @ViewBuilder
    private func recordRow(_ record: RecognitionRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sourceBadge(for: record)
                    .frame(width: 14, alignment: .leading)
                    mainText(for: record)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Text(timeFormatter.string(from: record.timestamp))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 34, alignment: .trailing)
                    action(for: record)
                        .frame(width: 22, height: 22)
            }

            HStack(spacing: 5) {
                Image(systemName: record.source.iconName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(sourceDisplayName(for: record))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if !record.asrMethod.isEmpty {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(record.asrMethod)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Processing phase indicator
                if record.phase != .completed && record.phase != .failed {
                    HStack(spacing: 3) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(record.phase.displayName)
                            .font(.caption2)
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.1), in: Capsule())
                }
            }
            .padding(.leading, 14)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.035))
        )
    }

    @ViewBuilder
    private func mainText(for record: RecognitionRecord) -> some View {
        if record.phase == .completed && record.isSuccess {
            if !record.text.isEmpty {
                Text(record.text)
                    .font(.subheadline)
                    .lineLimit(4)
            } else {
                Text(AppL10n.tr("（空结果）"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if record.phase == .failed || !record.isSuccess {
            Text(record.errorMessage ?? AppL10n.tr("处理失败"))
                .font(.subheadline)
                .foregroundStyle(.red)
        } else if !record.text.isEmpty {
            Text(record.text)
                .font(.subheadline)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private func action(for record: RecognitionRecord) -> some View {
        if record.phase == .completed && record.isSuccess && !record.text.isEmpty {
            Button {
                copyFailedIds.remove(record.id)
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setString(record.text, forType: .string) {
                    copiedIds.insert(record.id)
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        copiedIds.remove(record.id)
                    }
                } else {
                    copyFailedIds.insert(record.id)
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        copyFailedIds.remove(record.id)
                    }
                }
            } label: {
                Image(systemName: copyIcon(for: record))
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(copyColor(for: record))
            .onHover { hovering in
                if hovering {
                    copyHoverIds.insert(record.id)
                } else {
                    copyHoverIds.remove(record.id)
                }
            }
            .help(copyFailedIds.contains(record.id) ? AppL10n.tr("复制失败") : AppL10n.tr("复制到剪贴板"))
        } else if (record.phase == .failed || !record.isSuccess) && record.hasWavData {
            if retryingIds.contains(record.id) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    retryingIds.insert(record.id)
                    voiceManager.retryRecord(record)
                    Task {
                        try? await Task.sleep(for: .seconds(16))
                        retryingIds.remove(record.id)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help(AppL10n.tr("重试识别"))
            }
        } else {
            Color.clear
        }
    }

    private func copyIcon(for record: RecognitionRecord) -> String {
        if copiedIds.contains(record.id) { return "checkmark" }
        if copyFailedIds.contains(record.id) { return "exclamationmark.triangle" }
        return "doc.on.doc"
    }

    private func copyColor(for record: RecognitionRecord) -> Color {
        if copiedIds.contains(record.id) { return .green }
        if copyFailedIds.contains(record.id) { return .red }
        if copyHoverIds.contains(record.id) { return .secondary }
        return Color.secondary.opacity(0.55)
    }

    @ViewBuilder
    private func sourceBadge(for record: RecognitionRecord) -> some View {
        let isInProgress = record.phase != .completed && record.phase != .failed
        Circle()
            .fill(isInProgress ? .orange : (record.isSuccess ? .green : .red))
            .frame(width: 6, height: 6)
    }

    private func sourceDisplayName(for record: RecognitionRecord) -> String {
        if let name = record.sourceName, !name.isEmpty { return name }
        return record.source.displayName
    }

    private func toggleCollapsedDateGroup(_ dateLabel: String) {
        if collapsedDateGroups.contains(dateLabel) {
            collapsedDateGroups.remove(dateLabel)
        } else {
            collapsedDateGroups.insert(dateLabel)
        }
        saveCollapsedDateGroups()
    }

    private func syncCollapsedDateGroups() {
        syncCollapsedDateGroups(labels: groupedRecords.map(\.0))
    }

    private func syncCollapsedDateGroups(labels: [String]) {
        collapsedDateGroups = HistoryCollapsedDateGroups.pruned(
            HistoryCollapsedDateGroups.decode(collapsedDateGroupsData),
            keeping: Set(labels)
        )
        saveCollapsedDateGroups()
    }

    private func saveCollapsedDateGroups() {
        collapsedDateGroupsData = HistoryCollapsedDateGroups.encode(collapsedDateGroups)
    }

    private func clearHistory() {
        historyManager.clearAll()
        collapsedDateGroups.removeAll()
        saveCollapsedDateGroups()
    }
}

enum HistoryCollapsedDateGroups {
    static func decode(_ data: String) -> Set<String> {
        guard let bytes = data.data(using: .utf8),
              let labels = try? JSONDecoder().decode([String].self, from: bytes) else {
            return []
        }
        return Set(labels)
    }

    static func encode(_ labels: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(labels.sorted()),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    static func pruned(_ labels: Set<String>, keeping visibleLabels: Set<String>) -> Set<String> {
        labels.intersection(visibleLabels)
    }
}

private extension View {
    func historyPanel() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}
