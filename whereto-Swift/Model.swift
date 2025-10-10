import SwiftData
import Foundation

//Preparando banco de dados — esta função procura o banco no bundle e então cria uma pasta em ApplicationSupport e copia o banco para lá. Caso não exista um banco no bundle ela joga um erro.

func prepareDatabaseURL() -> URL {
  
    let fm = FileManager.default
    let appSupport = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let bundleID = Bundle.main.bundleIdentifier ?? "com.liam.whereto"
    let dir = appSupport.appendingPathComponent(bundleID, isDirectory: true)
    
    do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        print("✅ Created directory at:", dir.path)
    } catch {
        print("❌ Failed to create directory:", error)
    }
    
    let destination = dir.appendingPathComponent("wheretoData.db", isDirectory: false)
    
    if !fm.fileExists(atPath: destination.path) {
        guard let bundledURL = Bundle.main.url(forResource: "wheretoData", withExtension: "db") else {
            fatalError("Database not found in bundle resources")
        }
        do {
            try fm.copyItem(at: bundledURL, to: destination)
        } catch {
            fatalError("Failed to copy preloaded database: \(error)")
        }
    }
    
    print("App Support directory:", appSupport.path)
    print("App-specific directory:", dir.path)
    print("Database destination:", destination.path)
    
    return destination
}

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


let databaseURL = prepareDatabaseURL()
let container = try! ModelContainer(
    for: Flights.self,
    configurations: ModelConfiguration(url: databaseURL)
)
