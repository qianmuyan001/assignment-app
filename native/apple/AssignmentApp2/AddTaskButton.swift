import SwiftUI

/// Occupies a safe-area inset, so even the final row can scroll above the action.
struct AddTaskButton: View {
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        GeometryReader { geometry in
            HStack {
                Spacer(minLength: 0)
                Button(action: action) {
                    if geometry.size.width >= 500 {
                        Label("Add Task", systemImage: "plus").font(.headline)
                            .padding(.horizontal, 8).frame(minHeight: 44)
                    } else {
                        Image(systemName: "plus").font(.title2.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .disabled(!isEnabled).help("Add task")
                .accessibilityLabel("Add Task").accessibilityIdentifier("add-task")
                .hoverEffect(.highlight)
            }
        }
        .frame(height: 52)
        .background {
            if reduceTransparency { Color(uiColor: .systemBackground) }
        }
    }
}
