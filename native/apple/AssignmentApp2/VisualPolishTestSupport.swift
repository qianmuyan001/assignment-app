#if DEBUG
import SwiftUI
import UIKit

/// Explicit DEBUG-only environment variants. They exercise the same production
/// accessibility policy without modifying the user's system preferences.
struct VisualPolishTestEnvironment: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    private var options: Set<String> {
        Set(ProcessInfo.processInfo.arguments +
            (Bundle.main.object(forInfoDictionaryKey: "AssignmentVisualTestOptions") as? [String] ?? []))
    }

    @ViewBuilder private func themed(_ content: Content) -> some View {
        if options.contains("visual-dark") { content.preferredColorScheme(.dark) }
        else if options.contains("visual-light") { content.preferredColorScheme(.light) }
        else { content }
    }

    func body(content: Content) -> some View {
        themed(content)
            .dynamicTypeSize(options.contains("-assignmentApp.uiTestDynamicTypeAccessibility5") ? .accessibility5 : typeSize)
            .background {
#if targetEnvironment(macCatalyst)
                if options.contains("visual-narrow-window") {
                    VisualTestWindowSize(size: CGSize(width: 520, height: 800))
                } else if options.contains("visual-wide-window") {
                    VisualTestWindowSize(size: CGSize(width: 1024, height: 800))
                }
#endif
            }
    }
}

#if targetEnvironment(macCatalyst)
private struct VisualTestWindowSize: UIViewRepresentable {
    let size: CGSize
    func makeUIView(context: Context) -> WindowProbe { WindowProbe(size: size) }
    func updateUIView(_ uiView: WindowProbe, context: Context) {}

    final class WindowProbe: UIView {
        let size: CGSize
        private var applied = false
        init(size: CGSize) { self.size = size; super.init(frame: .zero); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard !applied, let scene = window?.windowScene else { return }
            applied = true
            // Real system window request, no raster mock or content scale override.
            DispatchQueue.main.async {
                scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: CGPoint(x: 48, y: 48), size: self.size))) { error in
                    print("assignment_visual_window_error=\(error)")
                }
            }
        }
    }
}
#endif
#endif
