import SwiftUI
import Combine

#if canImport(UIKit)
import UIKit
#endif


enum SidebarDisplayStyle: String, CaseIterable, Identifiable {
    case expanded
    case compact

    var id: String { rawValue }

    var columnWidth: CGFloat {
        switch self {
        case .expanded:
            return 230
        case .compact:
            return 72
        }
    }

    /// Resolved through `L10n` rather than left as a plain literal: this text
    /// is handed to `Text`, `.help`, and `.accessibilityLabel` as a `String`
    /// variable, and only string *literals* go through SwiftUI's automatic
    /// localization. As a variable it would stay English forever.
    var toggleTitle: String {
        switch self {
        case .expanded:
            return L10n.tr("Use Icon-Only Sidebar")
        case .compact:
            return L10n.tr("Show Sidebar Labels")
        }
    }

    var toggleSystemImage: String {
        switch self {
        case .expanded:
            return "chevron.left"
        case .compact:
            return "chevron.right"
        }
    }

    mutating func toggle() {
        self = self == .expanded ? .compact : .expanded
    }
}


enum SearchEvent: Equatable {
    case present
    case clearAndClose
    case dismissPreservingQuery
}


enum SearchPresentationState: Equatable {
    case closed
    case expanded(focusRequestToken: UInt)

    var isExpanded: Bool {
        if case .expanded = self {
            return true
        }
        return false
    }

    var focusRequestToken: UInt? {
        guard case .expanded(let token) = self else { return nil }
        return token
    }

    mutating func handle(_ event: SearchEvent, query: inout String) {
        switch event {
        case .present:
            switch self {
            case .closed:
                self = .expanded(focusRequestToken: 0)
            case .expanded(let token):
                self = .expanded(focusRequestToken: token &+ 1)
            }

        case .clearAndClose:
            query = ""
            self = .closed

        case .dismissPreservingQuery:
            self = .closed
        }
    }
}


struct NavigationChromeAccessibilityPolicy: Equatable {
    let animatesSelection: Bool
    let usesTranslucentMaterial: Bool
    let emphasizesEdges: Bool

    init(
        reduceMotion: Bool,
        reduceTransparency: Bool,
        increasedContrast: Bool
    ) {
#if DEBUG
        let options = Set(ProcessInfo.processInfo.arguments +
                          (Bundle.main.object(forInfoDictionaryKey: "AssignmentVisualTestOptions") as? [String] ?? []))
        let reduceMotion = reduceMotion || options.contains("visual-reduce-motion")
        let reduceTransparency = reduceTransparency || options.contains("visual-reduce-transparency")
        let increasedContrast = increasedContrast || options.contains("visual-increase-contrast")
#endif
        animatesSelection = !reduceMotion
        usesTranslucentMaterial = !reduceTransparency && !increasedContrast
        emphasizesEdges = reduceTransparency || increasedContrast
    }

    var selectionStrokeWidth: CGFloat {
        emphasizesEdges ? 1.5 : 0.5
    }
}


struct AssignmentSidebar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @Binding var selection: AssignmentView
    @Binding var displayStyle: SidebarDisplayStyle

    @ScaledMetric(relativeTo: .body) private var navigationIconPointSize: CGFloat = 17
    @ScaledMetric(relativeTo: .subheadline) private var toggleIconPointSize: CGFloat = 14

    @Namespace private var selectionNamespace
    @Namespace private var glassNamespace

    private let taskViews = AssignmentView.allCases.filter {
        !$0.isLearningScene && $0 != .settings
    }

    private let learningViews = AssignmentView.allCases.filter(\.isLearningScene)

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    navigationItems.frame(minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
            }

            Divider()
                .padding(.horizontal, displayStyle == .expanded ? 10 : 6)
                .padding(.top, 8)

            styleToggle
                .padding(.top, 8)
        }
        .padding(.horizontal, displayStyle == .expanded ? 12 : 8)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .navigationTitle(displayStyle == .expanded ? L10n.tr("Assignments") : "")
    }

    @ViewBuilder
    private var navigationItems: some View {
        if #available(iOS 26.0, macCatalyst 26.0, *),
           accessibilityPolicy.usesTranslucentMaterial {
            GlassEffectContainer(spacing: 12) {
                navigationStack
            }
        } else {
            navigationStack
        }
    }

    private var navigationStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Tasks")

            ForEach(taskViews) { view in
                sidebarButton(for: view)
            }

            if !learningViews.isEmpty {
                sectionHeader("Learning")
                    .padding(.top, 10)

                ForEach(learningViews) { view in
                    sidebarButton(for: view)
                }
            }

            Spacer(minLength: 20)

            sidebarButton(for: .settings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        if displayStyle == .expanded {
            Text(L10n.tr(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func sidebarButton(for view: AssignmentView) -> some View {
        Button {
            // Keyboard, Switch Control, and VoiceOver activation stay
            // immediate. The direct-manipulation gesture below owns motion.
            select(view, animated: false)
        } label: {
            sidebarLabel(for: view)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
                .contentShape(Capsule())
        }
        .buttonStyle(SidebarPressButtonStyle())
        .highPriorityGesture(
            TapGesture().onEnded {
                select(view, animated: true)
            }
        )
        .help(view.localizedTitle)
        .accessibilityLabel(view.localizedTitle)
        .accessibilityHint(
            L10n.tr("Shows %@ without hiding the sidebar.", view.localizedTitle)
        )
        .accessibilityAddTraits(selection == view ? .isSelected : [])
        .accessibilityIdentifier("sidebar-\(view.rawValue)")
    }

    @ViewBuilder
    private func sidebarLabel(for view: AssignmentView) -> some View {
        if #available(iOS 26.0, macCatalyst 26.0, *),
           accessibilityPolicy.usesTranslucentMaterial,
           selection == view {
            sidebarLabelContent(for: view)
                .transaction(disableContentAnimation)
                .glassEffect(
                    .regular.tint(Color.accentColor.opacity(0.12)).interactive(),
                    in: Capsule()
                )
                .glassEffectID("sidebar-selection", in: glassNamespace)
                .glassEffectTransition(.matchedGeometry)
        } else {
            sidebarLabelContent(for: view)
                .transaction(disableContentAnimation)
                .background {
                    if selection == view {
                        SidebarFallbackSelectionIndicator(
                            policy: accessibilityPolicy,
                            namespace: selectionNamespace
                        )
                    }
                }
        }
    }

    private func sidebarLabelContent(for view: AssignmentView) -> some View {
        HStack(spacing: 12) {
            Image(systemName: view.systemImage)
                .font(.system(size: constrainedNavigationIconSize, weight: .semibold))
                .frame(
                    width: max(24, constrainedNavigationIconSize),
                    height: max(24, constrainedNavigationIconSize)
                )
                .accessibilityHidden(true)

            if displayStyle == .expanded {
                Text(view.localizedTitle)
                    .font(.body.weight(selection == view ? .semibold : .regular))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, displayStyle == .expanded ? 14 : 0)
        .frame(
            maxWidth: displayStyle == .expanded ? .infinity : 52,
            minHeight: 48,
            alignment: displayStyle == .expanded ? .leading : .center
        )
        .foregroundStyle(
            selection == view && !accessibilityPolicy.emphasizesEdges
                ? Color.accentColor
                : Color.primary
        )
    }

    private var styleToggle: some View {
        Button {
            displayStyle.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: displayStyle.toggleSystemImage)
                    .font(.system(size: constrainedToggleIconSize, weight: .semibold))
                    .frame(
                        width: max(24, constrainedToggleIconSize),
                        height: max(24, constrainedToggleIconSize)
                    )
                    .accessibilityHidden(true)

                if displayStyle == .expanded {
                    Text("Compact Sidebar")
                        .font(.subheadline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, displayStyle == .expanded ? 14 : 0)
            .frame(
                maxWidth: displayStyle == .expanded ? .infinity : 52,
                minHeight: 44,
                alignment: displayStyle == .expanded ? .leading : .center
            )
            .contentShape(Capsule())
        }
        .buttonStyle(SidebarPressButtonStyle())
        .foregroundStyle(.primary)
        .help(displayStyle.toggleTitle)
        .accessibilityLabel(displayStyle.toggleTitle)
        .accessibilityHint("Changes the sidebar width without hiding it.")
        .accessibilityIdentifier("sidebar-style-toggle")
    }

    private var accessibilityPolicy: NavigationChromeAccessibilityPolicy {
        NavigationChromeAccessibilityPolicy(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    private var constrainedNavigationIconSize: CGFloat {
        min(navigationIconPointSize, displayStyle == .compact ? 28 : 36)
    }

    private var constrainedToggleIconSize: CGFloat {
        min(toggleIconPointSize, 24)
    }

    private func disableContentAnimation(_ transaction: inout Transaction) {
        // Text and symbols update immediately. Only the selection surface
        // carries direct-manipulation motion.
        transaction.animation = nil
    }

    private func select(_ view: AssignmentView, animated: Bool) {
        guard selection != view else { return }

        if animated, accessibilityPolicy.animatesSelection {
            withAnimation(
                .timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
            ) {
                selection = view
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selection = view
            }
        }
    }
}


private struct SidebarFallbackSelectionIndicator: View {
    let policy: NavigationChromeAccessibilityPolicy
    let namespace: Namespace.ID

    var body: some View {
        Group {
            if policy.usesTranslucentMaterial {
                Capsule()
                    .fill(.regularMaterial)
            } else {
                Capsule()
                    .fill(Color(uiColor: .secondarySystemBackground))
            }
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    policy.emphasizesEdges
                        ? Color.accentColor
                        : Color.primary.opacity(0.08),
                    lineWidth: policy.selectionStrokeWidth
                )
        }
        .matchedGeometryEffect(
            id: "sidebar-selection",
            in: namespace
        )
    }
}


private struct SidebarPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed && !reduceMotion ? 0.98 : 1
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}


struct SearchToolbar: View {
    @Binding var query: String
    @Binding var presentation: SearchPresentationState

    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if presentation.isExpanded {
                expandedSearch
            } else {
                Button("Search", systemImage: "magnifyingglass") {
                    send(.present)
                }
                .help("Search tasks")
                .accessibilityIdentifier("search-toggle")
            }
        }
        .transaction { transaction in
            // Search is a high-frequency, keyboard-driven action. It should
            // respond immediately instead of animating toolbar layout.
            transaction.animation = nil
        }
        .onChange(of: presentation.isExpanded) { _, isExpanded in
            if !isExpanded {
                isFocused = false
            }
        }
        .onChange(of: presentation.focusRequestToken) { _, token in
            if token != nil {
                isFocused = true
            }
        }
    }

    private var expandedSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search tasks", text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .submitLabel(.search)
                .lineLimit(1)
                .accessibilityLabel("Search tasks")
                .accessibilityHint("Searches title, course, and description.")
                .accessibilityIdentifier("search-field")
                .onSubmit {
                    isFocused = false
                }
                .onKeyPress(.escape) {
                    send(.dismissPreservingQuery)
                    return .handled
                }

            Button("Clear and Close Search", systemImage: "xmark.circle.fill") {
                send(.clearAndClose)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .help("Clear and close search")
            .accessibilityHint("Clears the query and restores the page title.")
            .accessibilityIdentifier("search-close")
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 120, idealWidth: 270, maxWidth: 340, minHeight: 44)
        .modifier(SearchFieldChrome())
        .onKeyPress(.escape) {
            send(.dismissPreservingQuery)
            return .handled
        }
    }

    private func send(_ event: SearchEvent) {
        if event != .present {
            isFocused = false
        }
        var updatedQuery = query
        presentation.handle(event, query: &updatedQuery)
        query = updatedQuery
    }
}


private struct SearchFieldChrome: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macCatalyst 26.0, *),
           !reduceTransparency,
           colorSchemeContrast != .increased {
            // The native toolbar is already a Liquid Glass surface on the new
            // SDK. Avoid stacking a second translucent capsule inside it.
            content
        } else if reduceTransparency || colorSchemeContrast == .increased {
            content
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary, lineWidth: 1.5)
                }
        } else {
            content
                .background(.thinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(
                            Color.primary.opacity(0.1),
                            lineWidth: 0.5
                        )
                }
        }
    }
}

/// Uses the existing selection and sidebar preference in both presentations.
/// Only transient presentation belongs to this shell; destinations keep their
/// own state and the native split view remains in charge at regular widths.
struct AssignmentNavigationShell<Detail: View>: View {
    @Binding var selection: AssignmentView
    @Binding var displayStyle: SidebarDisplayStyle
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @ViewBuilder let detail: () -> Detail
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @StateObject private var drawer = SidebarPresentationMotion()
    @State private var dragOrigin: CGFloat?
    @AccessibilityFocusState private var closeIsFocused: Bool

    private var policy: NavigationChromeAccessibilityPolicy {
        .init(reduceMotion: reduceMotion, reduceTransparency: reduceTransparency,
              increasedContrast: contrast == .increased)
    }

    var body: some View {
        GeometryReader { geometry in
            if usesOverlay(width: geometry.size.width) {
                compactNavigation(width: geometry.size.width)
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar.navigationSplitViewColumnWidth(
                        min: displayStyle == .expanded ? 190 : 64,
                        ideal: displayStyle.columnWidth,
                        max: displayStyle == .expanded ? 300 : 76)
                } detail: {
                    NavigationStack { detail() }
                }
                .navigationSplitViewStyle(.balanced)
                .onAppear { drawer.finish(at: 0) }
            }
        }
        .focusedSceneValue(\.dismissAssignmentSidebar, drawer.target > 0 ? { settle(open: false) } : nil)
        .onDisappear { drawer.stop() }
        .onChange(of: reduceMotion) { _, value in
            if value { drawer.finish(at: drawer.target) }
        }
    }

    private func usesOverlay(width: CGFloat) -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-assignmentApp.uiTestCompactNavigation") { return true }
#endif
        return sizeClass == .compact || width < 700
    }

    private var sidebar: some View {
        AssignmentSidebar(selection: $selection, displayStyle: $displayStyle)
    }

    private func compactNavigation(width: CGFloat) -> some View {
        let panelWidth = min(displayStyle == .expanded ? 288.0 : 88.0, max(0, width - 56))
        let visible = drawer.position != 0 || drawer.target > 0
        return ZStack(alignment: .leading) {
            NavigationStack {
                detail()
                    .accessibilityHidden(visible)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                settle(open: drawer.target == 0)
                            } label: { Image(systemName: "sidebar.left") }
                            .help("Show Sidebar").accessibilityLabel("Show Sidebar")
                            .accessibilityIdentifier("compact-sidebar-open")
                        }
                    }
            }

            if visible {
                // Only the background feathers. Navigation text is never masked.
                LinearGradient(colors: [.black.opacity(0.16), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .opacity(drawer.position / max(panelWidth, 1))
                    .ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { settle(open: false) }
                    .accessibilityElement().accessibilityLabel("Close Sidebar")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("compact-sidebar-dismiss")
                    .accessibilityAction { settle(open: false) }
                    .gesture(drag(width: panelWidth), including: policy.animatesSelection ? .all : .none)
            }

            if visible {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack {
                            if displayStyle == .expanded {
                                Text("Assignments").font(.headline)
                                Spacer(minLength: 8)
                            }
                            Button { settle(open: false) } label: {
                                Image(systemName: "xmark").font(.body.weight(.semibold))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain).help("Close Sidebar")
                            .accessibilityLabel("Close Sidebar")
                            .accessibilityIdentifier("compact-sidebar-close")
                            .accessibilityFocused($closeIsFocused)
                            .keyboardShortcut(.cancelAction)
                        }
                        .padding(.horizontal, 16).padding(.top, 8)
                        sidebar
                    }
                    .frame(width: panelWidth)
                    .background {
                        if policy.usesTranslucentMaterial {
                            Rectangle().fill(.regularMaterial).ignoresSafeArea()
                        } else {
                            Color(uiColor: .systemBackground).ignoresSafeArea()
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if policy.emphasizesEdges {
                            Rectangle().fill(Color.primary.opacity(0.4)).frame(width: 1)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("compact-sidebar-panel")
                    // Simultaneous recognition leaves vertical sidebar scrolling native.
                    .simultaneousGesture(drag(width: panelWidth), including: policy.animatesSelection ? .all : .none)

                    if policy.usesTranslucentMaterial {
                        Rectangle().fill(.regularMaterial)
                            .mask(LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing))
                            .frame(width: 48).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .offset(x: drawer.position - panelWidth)

            }

            if !visible {
                Color.clear.frame(width: 20).contentShape(Rectangle())
                    .gesture(drag(width: panelWidth), including: policy.animatesSelection ? .all : .none).accessibilityHidden(true)
            }
        }
        .onAppear { drawer.openWidth = panelWidth }
        .onChange(of: panelWidth) { _, new in
            drawer.openWidth = new
            drawer.finish(at: drawer.target > 0 ? new : 0)
            dragOrigin = nil
        }
    }

    private func settle(open: Bool) {
        // Current rendered position is retained when reversing a running spring.
        drawer.settle(to: open ? drawer.openWidth : 0, animated: policy.animatesSelection)
        closeIsFocused = open
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) || dragOrigin != nil else { return }
                drawer.openWidth = width
                if dragOrigin == nil {
                    drawer.stop()
                    dragOrigin = drawer.position
                }
                drawer.position = min(width, max(0, (dragOrigin ?? 0) + value.translation.width))
            }
            .onEnded { value in
                guard let origin = dragOrigin else { return }
                dragOrigin = nil
                let projected = origin + value.predictedEndTranslation.width
                drawer.settle(to: projected > width / 2 ? width : 0, animated: policy.animatesSelection)
            }
    }
}

/// Finite, display-synchronised spring. Unlike a target-only offset, position is
/// the rendered value: taking over mid-flight cannot jump to the previous goal.
/// No display link runs while idle, offscreen, or with Reduce Motion enabled.
@MainActor
private final class SidebarPresentationMotion: NSObject, ObservableObject {
    @Published var position: CGFloat = 0
    @Published private(set) var target: CGFloat = 0
    var openWidth: CGFloat = 288
    private var velocity: CGFloat = 0
    private var lastTime: CFTimeInterval = 0
    private var displayLink: CADisplayLink?

    func settle(to value: CGFloat, animated: Bool) {
        target = value
        guard animated else { finish(at: value); return }
        guard displayLink == nil else { return }
        lastTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate(); displayLink = nil
        velocity = 0
    }

    func finish(at value: CGFloat) {
        stop(); target = value; position = value
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt = min(link.timestamp - lastTime, 1.0 / 30)
        lastTime = link.timestamp
        guard dt > 0 else { return }
        // Exact damped oscillator integration, response 0.3 / damping 0.78.
        let omega = 2 * CGFloat.pi / 0.3
        let damping: CGFloat = 0.78
        let decay = damping * omega
        let frequency = omega * sqrt(1 - damping * damping)
        let delta = position - target
        let sine = sin(frequency * dt), cosine = cos(frequency * dt)
        let envelope = exp(-decay * dt)
        let coefficient = (velocity + decay * delta) / frequency
        position = target + envelope * (delta * cosine + coefficient * sine)
        velocity = envelope * ((coefficient * frequency - decay * delta) * cosine
                              - (delta * frequency + decay * coefficient) * sine)
        if abs(position - target) < 0.1 && abs(velocity) < 0.5 { finish(at: target) }
    }
}
