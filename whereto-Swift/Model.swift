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

//Preparando banco de dados — esta função procura o banco no bundle e então cria uma pasta em ApplicationSupport e copia o banco para lá. Caso não exista um banco no bundle ela joga um erro.

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

#if DEBUG
private func legacyDBPath() -> String {
    return prepareDatabaseURL().path
}

private func userDefaultsImportKey() -> String { "LegacyImportCompleted" }

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

        if imported % 500 == 0 { // save in batches to reduce memory
            do { try context.save() } catch { dbLog("Save failed at batch:", imported, error.localizedDescription) }
        }
    }

    do { try context.save() } catch { dbLog("Final save failed:", error.localizedDescription) }

    dbLog("Import completed. Imported rows:", imported)
    defaults.set(true, forKey: userDefaultsImportKey())
}
#endif

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

struct Database {
    static let url: URL = prepareDatabaseURL()

    static let container: ModelContainer = {
        let container = try! ModelContainer(
            for: Flights.self,
            configurations: ModelConfiguration(url: url)
        )
        #if DEBUG
        // Perform one-time import from legacy DB if needed
        importLegacyIfNeeded(into: container)
        #endif
        return container
    }()
}

#if DEBUG
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
