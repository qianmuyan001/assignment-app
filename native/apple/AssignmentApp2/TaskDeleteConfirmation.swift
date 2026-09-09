import SwiftUI
import Combine

@MainActor final class TaskDeletionState: ObservableObject {
    enum Anchor: Equatable { case row, editor }
    @Published private(set) var targetID: Int64?
    @Published private(set) var anchor: Anchor = .row
    @Published private(set) var errorMessage: String?
    @Published private(set) var isDeleting = false

    func request(id: Int64, anchor: Anchor) {
        guard !isDeleting else { return }
        targetID = id; self.anchor = anchor; errorMessage = nil
    }
    func cancel() {
        guard !isDeleting else { return }
        targetID = nil; errorMessage = nil
    }
    @discardableResult
    func confirm(using delete: (Int64) -> String?) -> Bool {
        guard let id = targetID, !isDeleting else { return false }
        isDeleting = true
        let error = delete(id)
        isDeleting = false
        if let error { errorMessage = error; return false }
        cancel()
        return true
    }
}

private struct TaskDeletePopover: ViewModifier {
    @ObservedObject var state: TaskDeletionState
    let assignment: Assignment
    let anchor: TaskDeletionState.Anchor
    let onDelete: (Int64) -> String?
    var onSuccess: () -> Void
    @FocusState private var anchorFocused: Bool
    @AccessibilityFocusState private var accessibleAnchorFocused: Bool

    private var isPresented: Binding<Bool> {
        Binding(get: { state.targetID == assignment.id && state.anchor == anchor },
                set: { if !$0 { state.cancel(); anchorFocused = true; accessibleAnchorFocused = true } })
    }
    func body(content: Content) -> some View {
        content
            .focused($anchorFocused)
            .accessibilityFocused($accessibleAnchorFocused)
            .popover(isPresented: isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Delete this task?").font(.headline)
                    Text(assignment.title).fixedSize(horizontal: false, vertical: true)
                    if let message = state.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Cancel", role: .cancel) {
                            isPresented.wrappedValue = false
                        }.keyboardShortcut(.cancelAction)
                        Spacer(minLength: 16)
                        Button("Delete", role: .destructive) {
                            if state.confirm(using: onDelete) { onSuccess() }
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .accessibilityIdentifier("confirm-delete-task")
                        .disabled(state.isDeleting)
                    }
                }
                .padding(20).frame(idealWidth: 300, maxWidth: 360)
                .presentationCompactAdaptation(.popover)
            }
    }
}

extension View {
    func taskDeletePopover(state: TaskDeletionState, assignment: Assignment,
                           anchor: TaskDeletionState.Anchor,
                           onDelete: @escaping (Int64) -> String?,
                           onSuccess: @escaping () -> Void = {}) -> some View {
        modifier(TaskDeletePopover(state: state, assignment: assignment, anchor: anchor,
                                   onDelete: onDelete, onSuccess: onSuccess))
    }
}
