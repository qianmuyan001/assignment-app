import SwiftUI

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

    var toggleTitle: String {
        switch self {
        case .expanded:
            return "Use Icon-Only Sidebar"
        case .compact:
            return "Show Sidebar Labels"
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
            navigationItems
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .padding(.horizontal, displayStyle == .expanded ? 10 : 6)
                .padding(.top, 8)

            styleToggle
                .padding(.top, 8)
        }
        .padding(.horizontal, displayStyle == .expanded ? 12 : 8)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .navigationTitle(displayStyle == .expanded ? "Assignments" : "")
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
            Text(title)
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
        .frame(minWidth: 190, idealWidth: 270, maxWidth: 340, minHeight: 44)
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
