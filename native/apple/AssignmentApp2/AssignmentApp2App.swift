import SwiftUI


@main
@MainActor
struct AssignmentApp2App: App {
    @StateObject private var viewModel = AssignmentViewModel()
    @AppStorage(AssignmentPreferenceKeys.theme)
    private var themeValue = AppTheme.system.rawValue

    #if targetEnvironment(macCatalyst)
    var body: some Scene {
        WindowGroup("Assignments") {
            rootView
        }
        .commands {
            AssignmentCommands()
        }
    }
    #else
    var body: some Scene {
        WindowGroup("Assignments") {
            rootView
        }
    }
    #endif

    private var rootView: some View {
        ContentView()
            .environmentObject(viewModel)
            .preferredColorScheme(theme.preferredColorScheme)
    }

    private var theme: AppTheme {
        AppTheme(rawValue: themeValue) ?? .system
    }
}


#if targetEnvironment(macCatalyst)
private struct AssignmentCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") {
                NotificationCenter.default.post(
                    name: .assignmentNewTaskRequested,
                    object: nil
                )
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Assignments") {
            Button("Find Tasks") {
                NotificationCenter.default.post(
                    name: .assignmentFindRequested,
                    object: nil
                )
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            Button("Reload Tasks") {
                NotificationCenter.default.post(
                    name: .assignmentReloadRequested,
                    object: nil
                )
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
#endif
