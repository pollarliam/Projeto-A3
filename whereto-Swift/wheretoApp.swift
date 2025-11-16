//
//  whereto_SwiftApp.swift
//  whereto-Swift
//
//  Created by Ramael Cerqueira on 2025/10/8.
//

import SwiftUI
import SwiftData

/// The main application entry point.
///
/// This type bootstraps the app, creates/owns the shared SwiftData `ModelContainer`,
/// and injects it into the SwiftUI scene so that views can access a `ModelContext`
/// via the environment.
///
/// MVVM overview in this project:
/// - Model: The `Flights` SwiftData model (see Model.swift) plus database setup/import helpers.
/// - ViewModel: `FlightsViewModel` (see FlightsViewModel.swift) that loads data, filters, sorts,
///   and paginates results for display.
/// - View: SwiftUI views (`MainView` and friends in ContentView.swift) that observe the view model
///   and render UI. Views do not query the database directly; they ask the view model for data.
@main
struct whereto_SwiftApp: App {
    /// The single shared SwiftData container used by the app.
    ///
    /// This container is created by `Database.container` (see Model.swift), which configures
    /// the persistent store location and, in Debug builds, performs a one-time import of
    /// legacy data from the bundled SQLite database.
    let sharedModelContainer: ModelContainer = Database.container

    /// Creates the main window scene and injects the shared model container into the environment.
    ///
    /// The root view is `MainView`, which reads a `ModelContext` from the environment and
    /// constructs the `FlightsViewModel` for the UI layer.
    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.hiddenTitleBar)
        .modelContainer(sharedModelContainer)

        Window("Run History", id: "RunHistory") {
            RunHistoryView()
        }
        .modelContainer(sharedModelContainer)

        .commands {
            DetailsCommands()
        }
    }
}
