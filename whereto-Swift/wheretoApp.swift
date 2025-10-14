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
    // Use the single shared container defined in Model.swift
    let sharedModelContainer: ModelContainer = Database.container

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.hiddenTitleBar)
        .modelContainer(sharedModelContainer)
    }
}
