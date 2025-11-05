/// FlightsViewModel — the ViewModel in MVVM for flight browsing.
///
/// Responsibilities:
/// - Load pages of `Flights` from SwiftData using a `ModelContext`.
/// - Maintain UI state (loading, search text, filters, sorting selection).
/// - Provide derived `flights` array for the View to render.
/// - Implement multiple sorting algorithms (educational) and apply them to current results.
/// - Paginate and prefetch data for smooth scrolling.
///
/// MVVM mapping:
/// - Model: `Flights` entities (SwiftData) and persistence setup (Model.swift).
/// - ViewModel: This type orchestrates fetching, filtering, sorting, and paging.
/// - View: SwiftUI views observe `@Published` properties and render UI accordingly.
import Foundation
import SwiftData
import Combine

/// An observable view model that exposes flight data and UI state to SwiftUI views.
///
/// Create an instance with a `ModelContext` (usually from the environment). Call `load()` to
/// synchronously fetch the first page, and the view model will prefetch additional pages in the
/// background. Views bind to `flights`, `searchText`, filter/sort selections, and `isLoading`.
@MainActor
final class FlightsViewModel: ObservableObject {
    /// The field used when ordering results.
    enum SortKey: String, CaseIterable {
        case price
        case date
        case duration
    }

    /// The direction of sorting.
    enum SortOrder: String, CaseIterable {
        case ascending
        case descending
    }

    /// The algorithm used to order results (educational; performance varies by dataset size).
    enum SortAlgorithm: String, CaseIterable {
        case bubble
        case selection
        case insertion
        case quick
        case merge
    }

    /// The array of flights currently visible in the UI after applying search, filters, and sorting.
    @Published var flights: [Flights] = []
    /// Free‑text search applied to origin, destination, and airline fields.
    /// Triggers the filter pipeline on change.
    @Published var searchText: String = "" {
        didSet { applyFiltersAndSorting() }
    }
    /// True while the initial page is loading. Background prefetching is tracked separately.
    @Published var isLoading: Bool = false

    /// Sorting configuration selected by the user. Any change re-computes the derived list.
    @Published var sortKey: SortKey = .price { didSet { applyFiltersAndSorting() } }
    @Published var sortOrder: SortOrder = .ascending { didSet { applyFiltersAndSorting() } }
    @Published var sortAlgorithm: SortAlgorithm = .merge { didSet { applyFiltersAndSorting() } }

    /// Additional filters applied to the full dataset before sorting.
    @Published var minPrice: Double? { didSet { applyFiltersAndSorting() } }
    @Published var maxPrice: Double? { didSet { applyFiltersAndSorting() } }

    @Published var originFilter: String = "" { didSet { applyFiltersAndSorting() } }
    @Published var destinationFilter: String = "" { didSet { applyFiltersAndSorting() } }

    @Published var dateStart: Date? { didSet { applyFiltersAndSorting() } }
    @Published var dateEnd: Date? { didSet { applyFiltersAndSorting() } }

    // Internal state used for paging and prefetch control.
    private var allFlights: [Flights] = []
    private let context: ModelContext
    private let batchSize: Int = 500
    private var nextOffset: Int = 0
    private var hasMore: Bool = true
    private var isBackgroundLoading: Bool = false

    /// Creates a view model bound to the given `ModelContext`.
    init(context: ModelContext) {
        self.context = context
    }

    /// Loads the first page synchronously for a fast initial UI and resets pagination state.
    func load() {
        // Load just the first page synchronously for fast UI
        isLoading = true
        nextOffset = 0
        hasMore = true
        allFlights.removeAll()
        flights.removeAll()
        loadNextPage(initial: true)
    }

    /// Fetches the next page of results from SwiftData using a `FetchDescriptor`.
    /// - Parameter initial: If true, will also clear `isLoading` when the first page finishes.
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
            applyFiltersAndSorting()
        } catch {
            print("[VM] ❌ Paged fetch failed:", error)
            hasMore = false
        }
        isBackgroundLoading = false
        if initial { isLoading = false }
    }

    /// Backward-compatibility shim — delegates to the unified filter/sort pipeline.
    private func applySearch() {
        // Backward compatibility: delegate to the unified pipeline
        applyFiltersAndSorting()
    }

    /// Recomputes the visible `flights` by applying search, field filters, and selected sorting.
    ///
    /// Steps:
    /// 1. Start from `allFlights` (the union of pages fetched so far).
    /// 2. Apply free‑text search across origin/destination/airline.
    /// 3. Apply field filters (price range, origin/destination substrings, optional date range).
    /// 4. Build a comparator based on `sortKey` and `sortOrder`.
    /// 5. Sort using the chosen `sortAlgorithm`.
    /// 6. Publish the result to `flights` and trigger background prefetch if appropriate.
    private func applyFiltersAndSorting() {
        // Start from all flights
        var result = allFlights

        // Text search (origin, destination, airline)
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let lower = trimmed.lowercased()
            result = result.filter { flight in
                flight.origin.lowercased().contains(lower) ||
                flight.destination.lowercased().contains(lower) ||
                flight.airline.lowercased().contains(lower)
            }
        }

        // Additional field filters
        if let min = minPrice {
            result = result.filter { $0.price_eco >= min }
        }
        if let max = maxPrice {
            result = result.filter { $0.price_eco <= max }
        }
        if !originFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lower = originFilter.lowercased()
            result = result.filter { $0.origin.lowercased().contains(lower) }
        }
        if !destinationFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lower = destinationFilter.lowercased()
            result = result.filter { $0.destination.lowercased().contains(lower) }
        }
        if dateStart != nil || dateEnd != nil {
            result = result.filter { flight in
                guard let date = parseDate(flight.depdate) else { return false }
                if let start = dateStart, date < start { return false }
                if let end = dateEnd, date > end { return false }
                return true
            }
        }

        // Sorting using selected algorithm and order
        let comparator: (Flights, Flights) -> Bool = { a, b in
            let ascending = (self.sortOrder == .ascending)
            switch self.sortKey {
            case .price:
                return ascending ? (a.price_eco < b.price_eco) : (a.price_eco > b.price_eco)
            case .date:
                let da = self.parseDate(a.depdate)
                let db = self.parseDate(b.depdate)
                switch (da, db) {
                case let (l?, r?):
                    return ascending ? (l < r) : (l > r)
                case (nil, nil):
                    return false
                case (nil, _):
                    return !ascending // nils last for ascending
                case (_, nil):
                    return ascending
                }
            case .duration:
                return ascending ? (a.duration < b.duration) : (a.duration > b.duration)
            }
        }

        // Apply chosen algorithm
        switch sortAlgorithm {
        case .bubble:
            result = bubbleSort(result, by: comparator)
        case .selection:
            result = selectionSort(result, by: comparator)
        case .insertion:
            result = insertionSort(result, by: comparator)
        case .quick:
            result = quickSort(result, by: comparator)
        case .merge:
            result = mergeSort(result, by: comparator)
        }

        flights = result

        // Continue background prefetch if applicable
        maybePrefetchMore()
    }

    /// Triggers loading of the next page when the UI approaches the end of the current list.
    /// - Parameter item: The item that just appeared in the UI (or nil to force a load).
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

    /// Opportunistically prefetches more pages while idle (only when not searching and under a soft limit).
    private func maybePrefetchMore() {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if hasMore && allFlights.count < 1000 {
            loadNextPage()
        }
    }

    /// Attempts to parse `depdate` strings using several common formats.
    private func parseDate(_ string: String) -> Date? {
        // Try multiple common formats
        let fmts = [
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "dd/MM/yyyy",
            "MM/dd/yyyy",
            "dd-MM-yyyy",
            "MM-dd-yyyy",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for f in fmts {
            df.dateFormat = f
            if let d = df.date(from: string) { return d }
        }
        return nil
    }

    /// Educational bubble sort (O(n^2)); simple but slow for large lists.
    private func bubbleSort(_ array: [Flights], by areInIncreasingOrder: (Flights, Flights) -> Bool) -> [Flights] {
        var a = array
        guard a.count > 1 else { return a }
        var swapped: Bool
        repeat {
            swapped = false
            for i in 1..<a.count {
                if !areInIncreasingOrder(a[i - 1], a[i]) {
                    a.swapAt(i - 1, i)
                    swapped = true
                }
            }
        } while swapped
        return a
    }

    /// Educational selection sort (O(n^2)); minimal swaps but still quadratic.
    private func selectionSort(_ array: [Flights], by areInIncreasingOrder: (Flights, Flights) -> Bool) -> [Flights] {
        var a = array
        for i in 0..<a.count {
            var minIndex = i
            for j in (i + 1)..<a.count {
                if areInIncreasingOrder(a[j], a[minIndex]) {
                    minIndex = j
                }
            }
            if i != minIndex { a.swapAt(i, minIndex) }
        }
        return a
    }

    /// Educational insertion sort (O(n^2)); efficient for nearly-sorted input.
    private func insertionSort(_ array: [Flights], by areInIncreasingOrder: (Flights, Flights) -> Bool) -> [Flights] {
        var a = array
        for i in 1..<a.count {
            var j = i
            let key = a[j]
            while j > 0 && areInIncreasingOrder(key, a[j - 1]) == true {
                a[j] = a[j - 1]
                j -= 1
            }
            a[j] = key
        }
        return a
    }

    /// Educational quick sort (average O(n log n)); in-place; worst-case quadratic.
    private func quickSort(_ array: [Flights], by areInIncreasingOrder: (Flights, Flights) -> Bool) -> [Flights] {
        var a = array
        func qs(_ low: Int, _ high: Int) {
            if low >= high { return }
            let p = partition(&a, low, high)
            qs(low, p - 1)
            qs(p + 1, high)
        }
        func partition(_ a: inout [Flights], _ low: Int, _ high: Int) -> Int {
            let pivot = a[high]
            var i = low
            for j in low..<high {
                if areInIncreasingOrder(a[j], pivot) {
                    a.swapAt(i, j)
                    i += 1
                }
            }
            a.swapAt(i, high)
            return i
        }
        if a.count > 1 { qs(0, a.count - 1) }
        return a
    }

    /// Educational merge sort (O(n log n)); stable; uses extra memory during merges.
    private func mergeSort(_ array: [Flights], by areInIncreasingOrder: (Flights, Flights) -> Bool) -> [Flights] {
        func ms(_ a: [Flights]) -> [Flights] {
            guard a.count > 1 else { return a }
            let mid = a.count / 2
            let left = ms(Array(a[..<mid]))
            let right = ms(Array(a[mid...]))
            return merge(left, right)
        }
        func merge(_ left: [Flights], _ right: [Flights]) -> [Flights] {
            var i = 0, j = 0
            var out: [Flights] = []
            out.reserveCapacity(left.count + right.count)
            while i < left.count && j < right.count {
                if areInIncreasingOrder(left[i], right[j]) {
                    out.append(left[i]); i += 1
                } else {
                    out.append(right[j]); j += 1
                }
            }
            if i < left.count { out.append(contentsOf: left[i...]) }
            if j < right.count { out.append(contentsOf: right[j...]) }
            return out
        }
        return ms(array)
    }
}
