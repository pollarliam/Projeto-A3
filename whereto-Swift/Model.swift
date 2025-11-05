/// Data layer and model definitions for the app.
///
/// Responsibilities:
/// - Prepare the persistent store location in Application Support.
/// - (Debug) Import legacy data from a bundled SQLite database into SwiftData.
/// - Define the `Flights` model schema used by SwiftData.
/// - Provide a shared `ModelContainer` via `Database.container` for the app to use.
///
/// MVVM mapping:
/// - Model: Everything in this file represents the Model layer (data and persistence schema).
/// - ViewModel: Consumes this model via a `ModelContext` to fetch/filter/sort (see FlightsViewModel).
/// - View: Displays data exposed by the ViewModel.
import SwiftData
import Foundation
import SQLite3

#if DEBUG
private let DEBUG_DB = true
#else
private let DEBUG_DB = false
#endif

@inline(__always)
private func dbLog(_ items: Any...) {
    guard DEBUG_DB else { return }
    print("[DB]", items.map { "\($0)" }.joined(separator: " "))
}

/// Prepares and returns the file URL for the SwiftData persistent store.
///
/// This function creates an app-specific directory under Application Support, then ensures
/// a preloaded database (wheretoData.db) is present at the destination. If the destination
/// file does not exist, it copies the bundled DB there. The returned URL is used by
/// `ModelConfiguration(url:)` to tell SwiftData where to store its data.
/// - Returns: The URL of the persistent store location.
func prepareDatabaseURL() -> URL {
  
    let fm = FileManager.default
    let appSupport = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let bundleID = Bundle.main.bundleIdentifier ?? "com.liam.whereto"
    let dir = appSupport.appendingPathComponent(bundleID, isDirectory: true)
    
    do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        dbLog("Created directory at:", dir.path)
    } catch {
        dbLog("Failed to create directory:", error.localizedDescription)
    }
    
    let destination = dir.appendingPathComponent("wheretoData.db", isDirectory: false)
    dbLog("Planned destination:", destination.path)
    
    if !fm.fileExists(atPath: destination.path) {
        dbLog("Destination not found, attempting to copy from bundle…")
        guard let bundledURL = Bundle.main.url(forResource: "wheretoData", withExtension: "db") else {
            fatalError("Database not found in bundle resources")
        }
        dbLog("Found bundled DB at:", bundledURL.path)
        do {
            try fm.copyItem(at: bundledURL, to: destination)
            dbLog("Copied preloaded database to:", destination.path)
        } catch {
            dbLog("Failed to copy preloaded database:", error.localizedDescription)
            fatalError("Failed to copy preloaded database: \(error)")
        }
    }
    
    let exists = fm.fileExists(atPath: destination.path)
    dbLog("Destination exists after prepare?", exists)
    
    if let attrs = try? fm.attributesOfItem(atPath: destination.path), let size = attrs[.size] as? NSNumber {
        dbLog("Database size:", size.intValue, "bytes")
    }
    dbLog("App Support directory:", appSupport.path)
    dbLog("App-specific directory:", dir.path)
    dbLog("Database destination:", destination.path)
    
    return destination
}


private func legacyDBPath() -> String {
    return prepareDatabaseURL().path
}

private func userDefaultsImportKey() -> String { "LegacyImportCompleted" }

/// Imports legacy flight rows from the bundled SQLite database into SwiftData.
///
/// The import runs once per app installation, controlled by a `UserDefaults` flag. It opens the
/// old SQLite database, iterates each row in the `flights` table, and creates a corresponding
/// `Flights` model instance inserted into the provided container's context. Saves occur in batches
/// to manage memory usage.
/// - Parameter container: The `ModelContainer` that will receive imported `Flights` records.
/// - Important: This is intended as a one-time migration utility for development/testing.
func importLegacyIfNeeded(into container: ModelContainer) {
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: userDefaultsImportKey()) {
        dbLog("Import already completed — skipping.")
        return
    }

    let path = legacyDBPath()
    dbLog("Attempting legacy import from:", path)

    var db: OpaquePointer? = nil
    if sqlite3_open(path, &db) != SQLITE_OK {
        dbLog("sqlite3_open failed:", String(cString: sqlite3_errmsg(db)))
        sqlite3_close(db)
        return 
    }
    defer { sqlite3_close(db) }

    let query = "SELECT id, csv_id, depdate, origin, destination, duration, price_eco, price_exec, price_premium, demand, early, population, airline FROM flights"

    var stmt: OpaquePointer? = nil
    if sqlite3_prepare_v2(db, query, -1, &stmt, nil) != SQLITE_OK {
        dbLog("sqlite3_prepare_v2 failed:", String(cString: sqlite3_errmsg(db)))
        sqlite3_finalize(stmt)
        return
    }
    defer { sqlite3_finalize(stmt) }

    let context = ModelContext(container)
    var imported = 0

    while sqlite3_step(stmt) == SQLITE_ROW {
        let id = Int(sqlite3_column_int64(stmt, 0))
        let csv_id = Int(sqlite3_column_int64(stmt, 1))
        let depdate = String(cString: sqlite3_column_text(stmt, 2))
        let origin = String(cString: sqlite3_column_text(stmt, 3))
        let destination = String(cString: sqlite3_column_text(stmt, 4))
        let duration = sqlite3_column_double(stmt, 5)
        let price_eco = Double(sqlite3_column_double(stmt, 6))
        let price_exec = sqlite3_column_double(stmt, 7)
        let price_premium = sqlite3_column_double(stmt, 8)
        let demand = String(cString: sqlite3_column_text(stmt, 9))
        let early = Int(sqlite3_column_int64(stmt, 10))
        let population = Int(sqlite3_column_int64(stmt, 11))
        let airline = String(cString: sqlite3_column_text(stmt, 12))

        let flight = Flights(
            id: id,
            csv_id: csv_id,
            depdate: depdate,
            origin: origin,
            destination: destination,
            duration: duration,
            price_eco: price_eco,
            price_exec: price_exec,
            price_premium: price_premium,
            demand: demand,
            early: early,
            population: population,
            airline: airline
        )
        context.insert(flight)
        imported += 1

        if imported % 500 == 0 {
            do { try context.save() } catch { dbLog("Save failed at batch:", imported, error.localizedDescription) }
        }
    }

    do { try context.save() } catch { dbLog("Final save failed:", error.localizedDescription) }

    dbLog("Import completed. Imported rows:", imported)
    defaults.set(true, forKey: userDefaultsImportKey())
}


/// A SwiftData model representing a single flight record.
///
/// This is the core persisted entity for the app. Each instance corresponds to a row. Properties are stored by SwiftData and can be
/// fetched via a `ModelContext`.
///
/// Properties:
/// - `id`: Unique flight identifier (marked `@Attribute(.unique)` to prevent duplicates).
/// - `csv_id`: Source identifier from the unique id in the original CSV files. Each CSV had a unique id for each of the 10.000 entries.
/// - `depdate`: Departure date as a string (multiple formats are supported downstream).
/// - `origin` / `destination`: Airport codes.
/// - `duration`: Flight duration (in minutes or hours depending on your dataset).
/// - `price_eco` / `price_exec` / `price_premium`: Prices for different fare classes.
/// - `demand`: Qualitative indicator of demand.
/// - `early`: Days early? Unsure of what it meant in the CSV. Unused data
/// - `population`: Quantitative indicator of demand. Unused data
/// - `airline`: Airline name.
@Model
final class Flights {
    @Attribute(.unique)
    var id: Int
    var csv_id: Int
    var depdate: String
    var origin: String
    var destination: String
    var duration: Double
    var price_eco: Double
    var price_exec: Double
    var price_premium: Double
    var demand: String
    var early: Int
    var population: Int
    var airline: String
    
    init(id: Int, csv_id: Int, depdate: String, origin: String, destination: String, duration: Double,
         price_eco: Double, price_exec: Double, price_premium: Double,
         demand: String, early: Int, population: Int, airline: String) {
        self.id = id
        self.csv_id = csv_id
        self.depdate = depdate
        self.origin = origin
        self.destination = destination
        self.duration = duration
        self.price_eco = price_eco
        self.price_exec = price_exec
        self.price_premium = price_premium
        self.demand = demand
        self.early = early
        self.population = population
        self.airline = airline
    }
}

/// Namespace for the app's persistent store configuration.
///
/// - `url`: The resolved persistent store URL created by `prepareDatabaseURL()`.
/// - `container`: A lazily-initialized `ModelContainer` configured for the `Flights` model.
struct Database {
    static let url: URL = prepareDatabaseURL()
    static let container: ModelContainer = {
        let container = try! ModelContainer(
            for: Flights.self,
            configurations: ModelConfiguration(url: url)
        )
        
        // Perform one-time import from legacy DB if needed
        importLegacyIfNeeded(into: container)
        return container
    }()
    
#if DEBUG
    /// An in-memory SwiftData container seeded with sample flights for SwiftUI previews.
    static var previewContainer: ModelContainer = {
        let schema = Schema([Flights.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        
        // Seed a few sample flights for previews
        let samples: [Flights] = [
            Flights(
                id: 101,
                csv_id: 1001,
                depdate: "2025-12-01",
                origin: "YYZ",
                destination: "LAX",
                duration: 310,
                price_eco: 199,
                price_exec: 549,
                price_premium: 349,
                demand: "medium",
                early: 14,
                population: 5000000,
                airline: "Air Canada"
            ),
            Flights(
                id: 202,
                csv_id: 2002,
                depdate: "2025-12-05",
                origin: "JFK",
                destination: "SFO",
                duration: 360,
                price_eco: 279,
                price_exec: 699,
                price_premium: 429,
                demand: "high",
                early: 21,
                population: 8000000,
                airline: "Delta"
            ),
            Flights(
                id: 303,
                csv_id: 3003,
                depdate: "2025-12-10",
                origin: "ORD",
                destination: "SEA",
                duration: 255,
                price_eco: 159,
                price_exec: 499,
                price_premium: 329,
                demand: "low",
                early: 7,
                population: 2700000,
                airline: "United"
            )
        ]
        
        samples.forEach { context.insert($0) }
        do { try context.save() } catch { dbLog("Preview seed save failed:", error.localizedDescription) }
        
        return container
    }()
#endif
    
}

#if DEBUG
/// Utility to validate that the SwiftData container is reachable and populated (Debug only).
///
/// Fetches and logs a count of `Flights` and prints a sample row if available.
func debugValidateContainer() {
    let context = ModelContext(Database.container)
    let count = (try? context.fetchCount(FetchDescriptor<Flights>())) ?? -1
    dbLog("SwiftData store fetchCount(Flights):", count)
    if let first = try? context.fetch(FetchDescriptor<Flights>()).first {
        dbLog("Sample flight:", first.origin, "->", first.destination, "airline:", first.airline)
    } else {
        dbLog("No sample flight available (empty store or fetch failed)")
    }
}
#endif

