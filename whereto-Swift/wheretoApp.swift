//
//  whereto_SwiftApp.swift
//  whereto-Swift
//
//  Created by Ramael Cerqueira on 2025/10/8.
//

import SwiftUI
import SwiftData

@main
struct whereto_SwiftApp: App {
    // Use the ModelContainer defined in Model.swift (ensures DB prep runs)
    let sharedModelContainer: ModelContainer = {
        print("[App] Initializing sharedModelContainer using Model.swift container…")
        return container
    }()

    init() {
        print("[App] whereto_SwiftApp init")
        // Force database preparation in case globals are optimized differently in some contexts
        _ = databaseURL
    }

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.hiddenTitleBar)
        .modelContainer(sharedModelContainer)
    }
}
