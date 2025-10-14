import Foundation
import SwiftData
import Combine

@MainActor
final class FlightsViewModel: ObservableObject {
    @Published var flights: [Flights] = []
    @Published var searchText: String = "" {
        didSet { applySearch() }
    }

    private var allFlights: [Flights] = []
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func load() {
        do {
            let descriptor = FetchDescriptor<Flights>(
                sortBy: [
                    .init(\.depdate, order: .forward),
                    .init(\.origin, order: .forward)
                ]
            )
            print("[VM] Fetching Flights with descriptor…")
            allFlights = try context.fetch(descriptor)
            print("[VM] Fetch succeeded. total:", allFlights.count)
            if let first = allFlights.first {
                print("[VM] First sample:", first.origin, "->", first.destination, "airline:", first.airline)
            }
            applySearch()
        } catch {
            print("[VM] ❌ Failed to fetch flights:", error)
            allFlights = []
            flights = []
        }
        print("[VM] Loaded flights count:", allFlights.count)
    }

    private func applySearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            flights = allFlights
            return
        }
        let lower = trimmed.lowercased()
        flights = allFlights.filter { flight in
            flight.origin.lowercased().contains(lower) ||
            flight.destination.lowercased().contains(lower) ||
            flight.airline.lowercased().contains(lower)
        }
    }

    // DEBUG: Call this once to seed minimal data if the store is empty.
    // Remember to remove or guard behind #if DEBUG in production.
    /*
    func debugSeedIfEmpty() {
        do {
            let count = try context.fetchCount(FetchDescriptor<Flights>())
            print("[VM] Current count:", count)
            guard count == 0 else { return }
            let sample = Flights(id: 1, csv_id: 1, depdate: "2025-10-14", origin: "JFK", destination: "CDG", duration: 7.0, price_eco: 500, price_exec: 1200, price_premium: 800, demand: "On Time", early: 0, population: 0, airline: "DL")
            context.insert(sample)
            try context.save()
            print("[VM] Seeded 1 sample flight")
        } catch {
            print("[VM] ❌ Seeding failed:", error)
        }
    }
    */
}
