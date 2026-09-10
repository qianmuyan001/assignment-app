import Foundation
import SwiftUI


struct AssignmentCommandActions {
    let availability: AssignmentCommandAvailability
    let newTask: () -> Void
    let find: () -> Void
    let closeSearch: () -> Void
    let reload: () -> Void
}


struct AssignmentCommandAvailability: Equatable {
    let canCreateTask: Bool
    let canFindTasks: Bool
    let canCloseSearch: Bool
    let canReload: Bool

    init(
        isWriteEnabled: Bool,
        isTaskDestination: Bool,
        isSearchExpanded: Bool,
        isModalPresented: Bool
    ) {
        canCreateTask = isWriteEnabled && !isModalPresented
        canFindTasks = isTaskDestination && !isModalPresented
        canCloseSearch = isTaskDestination && isSearchExpanded && !isModalPresented
        canReload = !isModalPresented
    }
}


private struct AssignmentCommandActionsKey: FocusedValueKey {
    typealias Value = AssignmentCommandActions
}


private struct DismissAssignmentSidebarKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var dismissAssignmentSidebar: (() -> Void)? {
        get { self[DismissAssignmentSidebarKey.self] }
        set { self[DismissAssignmentSidebarKey.self] = newValue }
    }

    var assignmentCommandActions: AssignmentCommandActions? {
        get { self[AssignmentCommandActionsKey.self] }
        set { self[AssignmentCommandActionsKey.self] = newValue }
    }
}


@main
@MainActor
struct AssignmentApp2App: App {
    @UIApplicationDelegateAdaptor(AssignmentNotificationAppDelegate.self) private var appDelegate
    @StateObject private var languagePreference = LanguagePreference.shared
    @AppStorage(AssignmentPreferenceKeys.theme)
    private var themeValue = AppTheme.system.rawValue
    /// Bumped whenever the database has been replaced underneath the running
    /// app. Changing it rebuilds the whole data stack, which is what makes a
    /// restore visible without asking the user to relaunch by hand.
    @State private var dataGeneration = 0

    var body: some Scene {
        WindowGroup("Assignments") {
            rootView
        }
        .commands {
            AssignmentCommands()
        }
    }

    private var rootView: some View {
        AssignmentRootView()
            .id(dataGeneration)
            .environmentObject(languagePreference)
            // SwiftUI reads `LocalizedStringKey` from the environment, so
            // setting the locale here refreshes every plain view the moment the
            // language changes.
            .environment(\.locale, languagePreference.language.resolvedLocale)
            .preferredColorScheme(theme.preferredColorScheme)
            .modifier(UITestDynamicTypeModifier())
            .onReceive(
                NotificationCenter.default.publisher(for: .assignmentDataDidRestore)
            ) { _ in
                dataGeneration += 1
            }
    }

    private var theme: AppTheme {
        AppTheme(rawValue: themeValue) ?? .system
    }
}


/// Owns the data stack for one "generation" of the app.
///
/// Everything that holds an open SQLite connection lives below this view, so
/// replacing it (through `.id`) releases those connections and lets a fresh
/// view model open the database that is now on disk.
private struct AssignmentRootView: View {
    @StateObject private var viewModel = AssignmentViewModel()

    var body: some View {
        ContentView()
            .environmentObject(viewModel)
    }
}


private struct UITestDynamicTypeModifier: ViewModifier {
    func body(content: Content) -> some View {
#if DEBUG
        content.modifier(VisualPolishTestEnvironment())
#else
        content
#endif
    }
}

private struct AssignmentCommands: Commands {
    @FocusedValue(\.assignmentCommandActions)
    private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") {
                actions?.newTask()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(actions?.availability.canCreateTask != true)
        }

        CommandMenu("Assignments") {
            Button("Find Tasks") {
                actions?.find()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(actions?.availability.canFindTasks != true)

            Button("Close Search") {
                actions?.closeSearch()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(actions?.availability.canCloseSearch != true)

            Divider()

            Button("Reload Tasks") {
                actions?.reload()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(actions?.availability.canReload != true)
        }
    }
}
