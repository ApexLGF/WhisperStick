import SwiftUI

/// Floating banner shown when exclusive-mode injection can't land on the
/// selected session. Callers push a `FallbackReason`; the center picks a
/// color/icon from `shouldClearSelection` and auto-dismisses after 2.5s.
///
/// Wired from `QuickVibeHostApp` via `InputRouter.toast`; rendered as a
/// `.overlay(alignment: .top)` on `ContentView`.
@MainActor
final class FallbackToastCenter: ObservableObject {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isTerminal: Bool
        let systemImage: String
        let iconTint: Color
    }

    @Published var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(reason: FallbackReason) {
        let toast = Toast(
            message: reason.toastMessage,
            isTerminal: reason.shouldClearSelection,
            systemImage: reason.shouldClearSelection ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
            iconTint: reason.shouldClearSelection ? .red.opacity(0.86) : .orange.opacity(0.82)
        )
        show(toast)
    }

    func show(message: String) {
        show(Toast(
            message: message,
            isTerminal: false,
            systemImage: "checkmark.circle.fill",
            iconTint: .mint.opacity(0.82)
        ))
    }

    private func show(_ toast: Toast) {
        current = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self else { return }
            if self.current?.id == toast.id {
                self.current = nil
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

struct FallbackToastView: View {
    let toast: FallbackToastCenter.Toast
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(toast.iconTint)
                .font(.body)
            Text(toast.message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(toast.iconTint.opacity(0.24), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
    }
}
