import SwiftUI


@main
struct AssignmentNativeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 650)
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
    }
}

