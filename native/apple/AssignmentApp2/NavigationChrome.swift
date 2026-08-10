import SwiftUI


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


enum SearchPresentationState: Equatable {
    case closed
    case expanded

    var isExpanded: Bool { self == .expanded }

    mutating func present() {
        self = .expanded
    }

    mutating func dismiss(query: inout String, clearingQuery: Bool) {
        if clearingQuery {
            query = ""
        }
        self = .closed
    }
}


struct AssignmentSidebar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var selection: AssignmentView
    @Binding var displayStyle: SidebarDisplayStyle

    @Namespace private var selectionNamespace
    @Namespace private var glassNamespace

    private let taskViews = AssignmentView.allCases.filter { $0 != .settings }

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
        .background(.regularMaterial)
        .navigationTitle(displayStyle == .expanded ? "Assignments" : "")
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.22),
            value: selection
        )
    }

    @ViewBuilder
    private var navigationItems: some View {
        if #available(iOS 26.0, macCatalyst 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                navigationStack
            }
        } else {
            navigationStack
        }
    }

    private var navigationStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            if displayStyle == .expanded {
                Text("Tasks")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
            }

            ForEach(taskViews) { view in
                sidebarButton(for: view)
            }

            Spacer(minLength: 20)

            sidebarButton(for: .settings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func sidebarButton(for view: AssignmentView) -> some View {
        Button {
            selection = view
        } label: {
            sidebarLabel(for: view)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(view.title)
        .accessibilityLabel(view.title)
        .accessibilityAddTraits(selection == view ? .isSelected : [])
        .accessibilityIdentifier("sidebar-\(view.rawValue)")
    }

    @ViewBuilder
    private func sidebarLabel(for view: AssignmentView) -> some View {
        if #available(iOS 26.0, macCatalyst 26.0, *), selection == view {
            sidebarLabelContent(for: view)
                .glassEffect(
                    .regular.tint(Color.accentColor.opacity(0.12)).interactive(),
                    in: Capsule()
                )
                .glassEffectID("sidebar-selection", in: glassNamespace)
                .glassEffectTransition(.matchedGeometry)
        } else {
            sidebarLabelContent(for: view)
                .background {
                    if selection == view {
                        LegacySidebarSelection(namespace: selectionNamespace)
                    }
                }
        }
    }

    private func sidebarLabelContent(for view: AssignmentView) -> some View {
        HStack(spacing: 12) {
            Image(systemName: view.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            if displayStyle == .expanded {
                Text(view.title)
                    .font(.body.weight(selection == view ? .semibold : .regular))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, displayStyle == .expanded ? 14 : 0)
        .frame(
            maxWidth: displayStyle == .expanded ? .infinity : 52,
            minHeight: 48,
            alignment: displayStyle == .expanded ? .leading : .center
        )
        .foregroundStyle(selection == view ? Color.accentColor : Color.primary)
    }

    private var styleToggle: some View {
        Button {
            displayStyle.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: displayStyle.toggleSystemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                if displayStyle == .expanded {
                    Text("Compact Sidebar")
                        .font(.subheadline)
                        .lineLimit(1)

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
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(displayStyle.toggleTitle)
        .accessibilityLabel(displayStyle.toggleTitle)
        .accessibilityIdentifier("sidebar-style-toggle")
    }
}


private struct LegacySidebarSelection: View {
    let namespace: Namespace.ID

    var body: some View {
        Capsule()
            .fill(.regularMaterial)
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .matchedGeometryEffect(
                id: "sidebar-selection",
                in: namespace
            )
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
                    .transition(.opacity)
            } else {
                Button("Search", systemImage: "magnifyingglass") {
                    presentation.present()
                }
                .help("Search tasks")
                .accessibilityIdentifier("search-toggle")
            }
        }
        .onChange(of: presentation.isExpanded) { _, isExpanded in
            if !isExpanded {
                isFocused = false
            }
        }
    }

    private var expandedSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search title, course, or description", text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .accessibilityLabel("Search title, course, or description")
                .accessibilityIdentifier("search-field")
                .onSubmit {
                    isFocused = false
                }
                .onKeyPress(.escape) {
                    dismiss(clearingQuery: false)
                    return .handled
                }

            Button("Clear and Close Search", systemImage: "xmark.circle.fill") {
                dismiss(clearingQuery: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Clear and close search")
            .accessibilityIdentifier("search-close")
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 190, idealWidth: 270, maxWidth: 320, minHeight: 38)
        .modifier(SearchFieldChrome())
        .onAppear {
            isFocused = true
        }
        .onKeyPress(.escape) {
            dismiss(clearingQuery: false)
            return .handled
        }
    }

    private func dismiss(clearingQuery: Bool) {
        isFocused = false
        var updatedQuery = query
        presentation.dismiss(
            query: &updatedQuery,
            clearingQuery: clearingQuery
        )
        query = updatedQuery
    }
}


private struct SearchFieldChrome: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macCatalyst 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.thinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                }
        }
    }
}
