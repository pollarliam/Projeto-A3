import Foundation
import SwiftData
import Combine

@MainActor
final class FlightsViewModel: ObservableObject {
    @Published var flights: [Flights] = []
    @Published var searchText: String = "" {
        didSet { applySearch() }
    }
    @Published var isLoading: Bool = false

    private var allFlights: [Flights] = []
    private let context: ModelContext
    private let batchSize: Int = 500
    private var nextOffset: Int = 0
    private var hasMore: Bool = true
    private var isBackgroundLoading: Bool = false

    init(context: ModelContext) {
        self.context = context
    }

    func load() {
        // Load just the first page synchronously for fast UI
        isLoading = true
        nextOffset = 0
        hasMore = true
        allFlights.removeAll()
        flights.removeAll()
        loadNextPage(initial: true)
    }

    private func loadNextPage(initial: Bool = false) {
        guard hasMore, !isBackgroundLoading else { return }
        isBackgroundLoading = true
        let limit = batchSize
        let offset = nextOffset
        do {
            var descriptor = FetchDescriptor<Flights>(
                sortBy: [
                    .init(\.depdate, order: .forward),
                    .init(\.origin, order: .forward)
                ]
            )
            descriptor.fetchLimit = limit
            descriptor.fetchOffset = offset
            let page = try context.fetch(descriptor)
            if page.isEmpty { hasMore = false }
            allFlights.append(contentsOf: page)
            nextOffset += page.count
            applySearch()
        } catch {
            print("[VM] ❌ Paged fetch failed:", error)
            hasMore = false
        }
        isBackgroundLoading = false
        if initial { isLoading = false }
    }

    private func applySearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            flights = allFlights
        } else {
            let lower = trimmed.lowercased()
            flights = allFlights.filter { flight in
                flight.origin.lowercased().contains(lower) ||
                flight.destination.lowercased().contains(lower) ||
                flight.airline.lowercased().contains(lower)
            }
        }
        // If we're showing many fewer than we have, continue background loading
        maybePrefetchMore()
    }

    func loadMoreIfNeeded(currentItem item: Flights?) {
        guard let item = item else {
            loadNextPage()
            return
        }
        let thresholdIndex = flights.index(flights.endIndex, offsetBy: -50, limitedBy: flights.startIndex) ?? flights.startIndex
        if let idx = flights.firstIndex(where: { $0.id == item.id }), idx >= thresholdIndex {
            loadNextPage()
        }
    }

    private func maybePrefetchMore() {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if hasMore && allFlights.count < 1000 {
            loadNextPage()
        }
    }
}
