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


extension FocusedValues {
    var assignmentCommandActions: AssignmentCommandActions? {
        get { self[AssignmentCommandActionsKey.self] }
        set { self[AssignmentCommandActionsKey.self] = newValue }
    }
}


@main
@MainActor
struct AssignmentApp2App: App {
    @StateObject private var viewModel = AssignmentViewModel()
    @AppStorage(AssignmentPreferenceKeys.theme)
    private var themeValue = AppTheme.system.rawValue

    var body: some Scene {
        WindowGroup("Assignments") {
            rootView
        }
        .commands {
            AssignmentCommands()
        }
    }

    private var rootView: some View {
        ContentView()
            .environmentObject(viewModel)
            .preferredColorScheme(theme.preferredColorScheme)
            .modifier(UITestDynamicTypeModifier())
    }

    private var theme: AppTheme {
        AppTheme(rawValue: themeValue) ?? .system
    }
}


private struct UITestDynamicTypeModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "-assignmentApp.uiTestDynamicTypeAccessibility5"
        ) {
            content.dynamicTypeSize(.accessibility5)
        } else {
            content
        }
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
