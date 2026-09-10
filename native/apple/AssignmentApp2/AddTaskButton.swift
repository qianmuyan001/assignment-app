import SwiftUI
#if DEBUG
import UIKit
#endif

/// Owns both the usable viewport and action clearance. GeometryReader stays inside
/// the system safe area, including the keyboard and iPad home indicator.
struct TaskActionViewport<Content: View>: View {
    let isEnabled: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    static var inset: CGFloat { 24 }

    var body: some View {
        GeometryReader { geometry in
            content()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: 56 + Self.inset * 2)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    AddTaskButton(isEnabled: isEnabled,
                                  showsLabel: geometry.size.width >= 500, action: action)
                        .padding([.trailing, .bottom], Self.inset)
                }
#if DEBUG
                .background {
                    if ProcessInfo.processInfo.arguments.contains("-assignmentApp.uiTestMeasureChrome") {
                        ActionSafeAreaProbe()
                    }
                }
#endif
        }
    }
}

/// A small public surface; glass availability and accessibility belong here.
struct AddTaskButton: View {
    let isEnabled: Bool
    var showsLabel = true
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var policy: NavigationChromeAccessibilityPolicy {
        .init(reduceMotion: reduceMotion, reduceTransparency: reduceTransparency,
              increasedContrast: contrast == .increased)
    }

    var body: some View {
        styledButton
            .disabled(!isEnabled).help("Add Task")
            .accessibilityLabel("Add Task").accessibilityIdentifier("add-task")
    }

    @ViewBuilder private var styledButton: some View {
        if #available(iOS 26.0, macCatalyst 26.0, *),
           policy.usesTranslucentMaterial, policy.animatesSelection {
            // The system owns the touch highlight, glass lens and elastic lift.
            // Do not counteract its press with a second scale/opacity animation.
            button.buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            button.buttonStyle(FloatingActionStyle(policy: policy))
        }
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.title3.weight(.semibold))
                    .accessibilityHidden(true)
                if showsLabel { Text("Add Task").font(.headline) }
            }
            .padding(.horizontal, showsLabel ? 24 : 0)
            .frame(minWidth: 56, minHeight: 56)
            .foregroundStyle(policy.emphasizesEdges ? Color.primary : Color.accentColor)
            .contentShape(Capsule())
        }
    }
}

private struct FloatingActionStyle: ButtonStyle {
    let policy: NavigationChromeAccessibilityPolicy

    func makeBody(configuration: Configuration) -> some View {
        surface(configuration.label)
            .overlay {
                Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0))
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed && policy.animatesSelection ? 1.06 : 1)
            .animation(policy.animatesSelection
                       ? .spring(response: 0.3, dampingFraction: 0.68)
                       : .linear(duration: 0.1), value: configuration.isPressed)
    }

    @ViewBuilder private func surface(_ label: Configuration.Label) -> some View {
        if #available(iOS 26.0, macCatalyst 26.0, *), policy.usesTranslucentMaterial {
            label.glassEffect(.regular.tint(Color.accentColor.opacity(0.12)), in: .capsule)
        } else {
            label.background {
                if policy.usesTranslucentMaterial {
                    Capsule().fill(.regularMaterial)
                        .overlay { Capsule().fill(Color.accentColor.opacity(0.06)) }
                } else {
                    Capsule().fill(Color(uiColor: .secondarySystemBackground))
                }
            }
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(policy.emphasizesEdges ? 0.5 : 0.12),
                                       lineWidth: policy.selectionStrokeWidth)
            }
        }
    }
}

#if DEBUG
/// Test-only UIKit leaf exposes the measured safe viewport, not expected insets.
/// It never intercepts a click or contributes a product accessibility element.
private struct ActionSafeAreaProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> MeasurementView {
        let view = MeasurementView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "task-action-safe-area"
        view.accessibilityLabel = "Task action safe area"
        return view
    }
    func updateUIView(_ uiView: MeasurementView, context: Context) {}

    final class MeasurementView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            // Catalyst reports desktop coordinates to XCTest. Bounds supply
            // the actual logical scale, rather than assuming a 0.77 ratio.
            accessibilityValue = String(Double(bounds.width))
        }
    }
}
#endif
