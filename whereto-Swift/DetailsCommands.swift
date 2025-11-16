import SwiftUI

struct DetailsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Details") {
            Button("Show Run History") {
                openWindow(id: "RunHistory")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}
