import SwiftUI

struct DetailsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Detalhes") {
            Button("Mostrar Histórico de Execuções") {
                openWindow(id: "RunHistory")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}
