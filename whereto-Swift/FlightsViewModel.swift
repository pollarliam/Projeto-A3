/// FlightsViewModel — the ViewModel in MVVM for flight browsing.
///
/// Responsibilities:
/// - Load pages of `Flights` from SwiftData using a `ModelContext`.
/// - Maintain UI state (loading, search text, filters, sorting selection).
/// - Provide derived `flights` array for the View to render.
/// - Implement multiple sorting algorithms (educational) and apply them to current results.
/// - Paginate and prefetch data for smooth scrolling.
/// - Model: `Flights` entities (SwiftData) and persistence setup (Model.swift).
/// - ViewModel: This type orchestrates fetching, filtering, sorting, and paging.
/// - View: SwiftUI views observe `@Published` properties and render UI accordingly.
import Foundation
import SwiftData
import Combine
import FoundationModels

// Background fetcher that performs SwiftData fetches off the main actor
private actor BackgroundFlightsFetcher {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    /// Fetches a page of flight IDs in a stable order using a background ModelContext.
    func fetchPageIDs(offset: Int, limit: Int) throws -> [Int] {
        let ctx = ModelContext(container)
        var descriptor = FetchDescriptor<Flights>(
            sortBy: [
                .init(\.depdate, order: .forward),
                .init(\.origin, order: .forward)
            ]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        let page = try ctx.fetch(descriptor)
        return page.map { $0.id }
    }
    
    /// Returns the total number of Flights rows.
    func fetchCount() throws -> Int {
        let ctx = ModelContext(container)
        return try ctx.fetchCount(FetchDescriptor<Flights>())
    }
}

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
    
    /// The field used when searching.
    enum SearchKey: String, CaseIterable {
        case id
        case origin
        case destination
        case airline
        case price
    }

    /// The algorithm used to search results.
    enum SearchAlgorithm: String, CaseIterable {
        case linear
        case binary
        case hash
    }
    
    // Async pipeline control
    private var computeTask: Task<Void, Never>? = nil
    private var searchDebounceTask: Task<Void, Never>? = nil

    /// The array of flights currently visible in the UI after applying search, filters, and sorting.
    @Published var flights: [Flights] = []
    /// Free‑text search applied to origin, destination, and airline fields.
    /// Triggers the filter pipeline on change.
    @Published var searchText: String = "" {
        didSet { scheduleDebouncedRecompute() }
    }
    /// True while the initial page is loading. Background prefetching is tracked separately.
    @Published var isLoading: Bool = false

    /// Sorting configuration selected by the user. Any change re-computes the derived list.
    @Published var sortKey: SortKey = .price { didSet { applyFiltersAndSorting() } }
    @Published var sortOrder: SortOrder = .ascending { didSet { applyFiltersAndSorting() } }
    @Published var sortAlgorithm: SortAlgorithm = .merge { didSet { applyFiltersAndSorting() } }
    
    @Published var searchAlgorithm: SearchAlgorithm = .linear
    @Published var searchKey: SearchKey = .origin
    
    /// Hidden project input: algorithmic search query (does not affect normal UI search)
    @Published var benchmarkQuery: String = ""
    /// Progress for bulk load (0.0...1.0). Nil when not bulk loading.
    @Published var bulkLoadProgress: Double? = nil

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
    private let batchSize: Int = 50
    private var nextOffset: Int = 0
    private var hasMore: Bool = true
    private var isBackgroundLoading: Bool = false

    private let backgroundFetcher = BackgroundFlightsFetcher(container: Database.container)

    // Performance run tracking
    struct RunRecord: Identifiable {
        let id: Int
        let sortKey: SortKey
        let sortOrder: SortOrder
        let algorithm: SortAlgorithm
        let durationSeconds: Double
    }
    @Published private(set) var runHistory: [RunRecord] = []
    private var runCounter: Int = 0

    struct SearchRunRecord: Identifiable {
        let id: Int
        let query: String
        let key: SearchKey
        let algorithm: SearchAlgorithm
        let matches: Int
        let durationSeconds: Double
    }
    @Published private(set) var searchRunHistory: [SearchRunRecord] = []
    @Published private(set) var benchmarkResults: [Flights] = []

    private var searchRunCounter: Int = 0

    /// Creates a view model bound to the given `ModelContext`.
    init(context: ModelContext) {
        self.context = context
    }

    /// Debounce search changes to avoid recomputing on every keystroke.
    private func scheduleDebouncedRecompute() {
        // Cancel any pending debounce
        searchDebounceTask?.cancel()
        let expected = searchText
        searchDebounceTask = Task { [weak self] in
            // ~250ms debounce window
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            // Only recompute if the text hasn't changed during the debounce
            if expected == self.searchText {
                self.applyFiltersAndSorting()
            }
        }
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

    /// Fetches the next page of results off the main actor and rehydrates them on the main actor.
    /// - Parameter initial: If true, will also clear `isLoading` when the first page finishes.
    private func loadNextPage(initial: Bool = false) {
        guard hasMore, !isBackgroundLoading else { return }
        isBackgroundLoading = true
        let limit = batchSize
        let offset = nextOffset
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                // Perform the heavy fetch off the main actor
                let ids = try await self.backgroundFetcher.fetchPageIDs(offset: offset, limit: limit)
                
                await MainActor.run {
                    if ids.isEmpty { self.hasMore = false }
                }
                guard !ids.isEmpty else {
                    await MainActor.run {
                        self.isBackgroundLoading = false
                        if initial { self.isLoading = false }
                    }
                    return
                }
                
                // Rehydrate the fetched IDs on the main actor using the main context
                await MainActor.run {
                    do {
                        var desc = FetchDescriptor<Flights>()
                        // Fetch only the items we just loaded by ID (order will be restored after fetch)
                        desc.predicate = #Predicate<Flights> { f in ids.contains(f.id) }
                        let fetched = try self.context.fetch(desc)
                        
                        // Preserve the order that came from the background fetch
                        let indexByID: [Int: Int] = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
                        let ordered = fetched.sorted { (a, b) in
                            (indexByID[a.id] ?? Int.max) < (indexByID[b.id] ?? Int.max)
                        }
                        
                        self.allFlights.append(contentsOf: ordered)
                        self.nextOffset += ids.count
                        self.applyFiltersAndSorting()
                    } catch {
                        print("[VM] Rehydrate fetch failed:", error)
                        self.hasMore = false
                    }
                    self.isBackgroundLoading = false
                    if initial { self.isLoading = false }
                }
            } catch {
                await MainActor.run {
                    print("[VM] Background fetch failed:", error)
                    self.hasMore = false
                    self.isBackgroundLoading = false
                    if initial { self.isLoading = false }
                }
            }
        }
    }
    
    
    /// Loads every flight entry into memory in the background and publishes the full list at once.
    /// This keeps I/O off the main actor and avoids repeated re-sorts while streaming pages.
    func loadAllFlightsInBackground() {
        guard !isBackgroundLoading else { return }
        isLoading = true
        nextOffset = 0
        hasMore = true
        allFlights.removeAll()
        flights.removeAll()
        isBackgroundLoading = true
        bulkLoadProgress = 0.0

        let pageSize = max(1000, batchSize)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var offset = 0
            var allIDs: [Int] = []
            
            // Pre-size arrays to reduce reallocations
            let totalCount = await (try? self.backgroundFetcher.fetchCount()) ?? 0
            if totalCount > 0 {
                allIDs.reserveCapacity(totalCount)
                await MainActor.run { self.allFlights.reserveCapacity(totalCount) }
            }

            do {
                // Fetch all page IDs off the main actor
                while true {
                    let ids = try await self.backgroundFetcher.fetchPageIDs(offset: offset, limit: pageSize)
                    if ids.isEmpty { break }
                    allIDs.append(contentsOf: ids)
                    offset += ids.count
                }

                // Nothing to load
                if allIDs.isEmpty {
                    await MainActor.run {
                        self.hasMore = false
                        self.isBackgroundLoading = false
                        self.isLoading = false
                        self.bulkLoadProgress = nil
                    }
                    return
                }

                // Rehydrate on the main actor in chunks, then publish once at the end
                let chunkSize = max(1000, min(5000, pageSize * 5))
                var currentIndex = 0
                while currentIndex < allIDs.count {
                    let end = min(currentIndex + chunkSize, allIDs.count)
                    let chunk = Array(allIDs[currentIndex..<end])
                    await MainActor.run {
                        do {
                            var desc = FetchDescriptor<Flights>()
                            desc.predicate = #Predicate<Flights> { f in chunk.contains(f.id) }
                            let fetched = try self.context.fetch(desc)
                            let indexByID: [Int: Int] = Dictionary(uniqueKeysWithValues: chunk.enumerated().map { ($0.element, $0.offset) })
                            let ordered = fetched.sorted { (a, b) in
                                (indexByID[a.id] ?? Int.max) < (indexByID[b.id] ?? Int.max)
                            }
                            self.allFlights.append(contentsOf: ordered)
                            self.bulkLoadProgress = Double(end) / Double(allIDs.count)
                        } catch {
                            print("[VM] Rehydrate chunk failed:", error)
                        }
                    }
                    currentIndex = end
                }

                await MainActor.run {
                    self.nextOffset = allIDs.count
                    self.hasMore = false
                    self.applyFiltersAndSorting() // single publish after full load
                    self.isBackgroundLoading = false
                    self.isLoading = false
                    self.bulkLoadProgress = nil
                }
            } catch {
                await MainActor.run {
                    print("[VM] Load all failed:", error)
                    self.hasMore = false
                    self.isBackgroundLoading = false
                    self.isLoading = false
                    self.bulkLoadProgress = nil
                }
            }
        }
    }

    /// Backward-compatibility shim — delegates to the unified filter/sort pipeline.
    private func applySearch() {
        // Backward compatibility: delegate to the unified pipeline
        applyFiltersAndSorting()
    }

    /// Executes a search over the loaded dataset using the selected `searchAlgorithm` and `searchKey`.
    /// It records timing and prints the run to the console. This does not mutate `flights`.
    func executeSearch(query: String) {
        let snapshotAll = allFlights
        let algo = searchAlgorithm
        let key = searchKey
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            func accessor(_ f: Flights) -> String {
                switch key {
                case .id: return String(f.id)
                case .origin: return f.origin
                case .destination: return f.destination
                case .airline: return f.airline
                case .price: return String(format: "%.2f", f.price_eco)
                }
            }

            var matches: [Flights] = []
            let clock = ContinuousClock()
            let start = clock.now
            switch algo {
            case .linear:
                let lower = q.lowercased()
                matches = snapshotAll.filter { accessor($0).lowercased().contains(lower) }
            case .binary:
                // Binary search requires sorted data by the chosen key; prepare a sorted copy of keys with indices
                let pairs = snapshotAll.enumerated().map { (idx, f) in (idx, accessor(f)) }
                let sorted = pairs.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
                // Find the first match using binary search on the key string, then expand neighbors with the same prefix/substring
                let keyToFind = q.lowercased()
                var lo = 0, hi = sorted.count - 1
                var foundIndex: Int? = nil
                while lo <= hi {
                    let mid = (lo + hi) / 2
                    let val = sorted[mid].1.lowercased()
                    if val == keyToFind || val.contains(keyToFind) {
                        foundIndex = mid; break
                    } else if val < keyToFind {
                        lo = mid + 1
                    } else {
                        hi = mid - 1
                    }
                }
                if let fi = foundIndex {
                    // expand left and right collecting matches that contain the query
                    var i = fi
                    while i >= 0 {
                        let val = sorted[i].1.lowercased()
                        if val.contains(keyToFind) { matches.append(snapshotAll[sorted[i].0]); i -= 1 } else { break }
                    }
                    i = fi + 1
                    while i < sorted.count {
                        let val = sorted[i].1.lowercased()
                        if val.contains(keyToFind) { matches.append(snapshotAll[sorted[i].0]); i += 1 } else { break }
                    }
                }
            case .hash:
                // Build a hash map depending on the field
                switch key {
                case .id:
                    let dict = Dictionary(grouping: snapshotAll, by: { String($0.id) })
                    matches = dict[q] ?? []
                case .origin:
                    let dict = Dictionary(grouping: snapshotAll, by: { $0.origin.lowercased() })
                    matches = dict[q.lowercased()] ?? []
                case .destination:
                    let dict = Dictionary(grouping: snapshotAll, by: { $0.destination.lowercased() })
                    matches = dict[q.lowercased()] ?? []
                case .airline:
                    let dict = Dictionary(grouping: snapshotAll, by: { $0.airline.lowercased() })
                    matches = dict[q.lowercased()] ?? []
                case .price:
                    let dict = Dictionary(grouping: snapshotAll, by: { String(format: "%.2f", $0.price_eco) })
                    matches = dict[String(format: "%.2f", Double(q) ?? -1)] ?? []
                }
            }
            let duration = start.duration(to: clock.now)
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000.0

            await MainActor.run {
                self.benchmarkResults = matches
                self.searchRunCounter += 1
                let record = SearchRunRecord(id: self.searchRunCounter,
                                             query: q,
                                             key: key,
                                             algorithm: algo,
                                             matches: matches.count,
                                             durationSeconds: seconds)
                self.searchRunHistory.append(record)
                let timeStr = String(format: "%.5f", record.durationSeconds)
                print("[SearchMetrics] run\(record.id): key=\(key.rawValue), algo=\(algo.rawValue), query=\(q), matches=\(record.matches), time=\(timeStr)s")
            }
        }
    }
    
    /// Runs all search algorithms for the current `searchKey` using `benchmarkQuery`.
    /// This is used to benchmark algorithms without affecting the main UI search.
    func runSearchBenchmarks() {
        let q = benchmarkQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let dataset = allFlights
        let key = searchKey

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            func accessor(_ f: Flights) -> String {
                switch key {
                case .id: return String(f.id)
                case .origin: return f.origin
                case .destination: return f.destination
                case .airline: return f.airline
                case .price: return String(format: "%.2f", f.price_eco)
                }
            }

            for algo in SearchAlgorithm.allCases {
                var matches: [Flights] = []
                let clock = ContinuousClock()
                let start = clock.now
                switch algo {
                case .linear:
                    let lower = q.lowercased()
                    matches = dataset.filter { accessor($0).lowercased().contains(lower) }
                case .binary:
                    let pairs = dataset.enumerated().map { (idx, f) in (idx, accessor(f)) }
                    let sorted = pairs.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
                    let keyToFind = q.lowercased()
                    if !sorted.isEmpty {
                        var lo = 0, hi = sorted.count - 1
                        var foundIndex: Int? = nil
                        while lo <= hi {
                            let mid = (lo + hi) / 2
                            let val = sorted[mid].1.lowercased()
                            if val == keyToFind || val.contains(keyToFind) { foundIndex = mid; break }
                            else if val < keyToFind { lo = mid + 1 }
                            else { hi = mid - 1 }
                        }
                        if let fi = foundIndex {
                            var i = fi
                            while i >= 0 {
                                let val = sorted[i].1.lowercased()
                                if val.contains(keyToFind) { matches.append(dataset[sorted[i].0]); i -= 1 } else { break }
                            }
                            i = fi + 1
                            while i < sorted.count {
                                let val = sorted[i].1.lowercased()
                                if val.contains(keyToFind) { matches.append(dataset[sorted[i].0]); i += 1 } else { break }
                            }
                        }
                    }
                case .hash:
                    switch key {
                    case .id:
                        let dict = Dictionary(grouping: dataset, by: { String($0.id) })
                        matches = dict[q] ?? []
                    case .origin:
                        let dict = Dictionary(grouping: dataset, by: { $0.origin.lowercased() })
                        matches = dict[q.lowercased()] ?? []
                    case .destination:
                        let dict = Dictionary(grouping: dataset, by: { $0.destination.lowercased() })
                        matches = dict[q.lowercased()] ?? []
                    case .airline:
                        let dict = Dictionary(grouping: dataset, by: { $0.airline.lowercased() })
                        matches = dict[q.lowercased()] ?? []
                    case .price:
                        let dict = Dictionary(grouping: dataset, by: { String(format: "%.2f", $0.price_eco) })
                        matches = dict[String(format: "%.2f", Double(q) ?? -1)] ?? []
                    }
                }
                let duration = start.duration(to: ContinuousClock().now)
                let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000.0

                await MainActor.run {
                    self.searchRunCounter += 1
                    let record = SearchRunRecord(id: self.searchRunCounter,
                                                 query: q,
                                                 key: key,
                                                 algorithm: algo,
                                                 matches: matches.count,
                                                 durationSeconds: seconds)
                    self.searchRunHistory.append(record)
                    let timeStr = String(format: "%.5f", record.durationSeconds)
                    print("[SearchMetrics] run\(record.id): key=\(key.rawValue), algo=\(algo.rawValue), query=\(q), matches=\(record.matches), time=\(timeStr)s")
                }
            }
        }
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
        // Cancel any in-flight computation; only the latest state should win
        computeTask?.cancel()

        // Snapshot current state to use off the main actor
        let snapshotAll = allFlights
        let snapshotSearch = searchText
        let snapshotMin = minPrice
        let snapshotMax = maxPrice
        let snapshotOrigin = originFilter
        let snapshotDest = destinationFilter
        let snapshotStart = dateStart
        let snapshotEnd = dateEnd
        let snapshotKey = sortKey
        let snapshotOrder = sortOrder
        let snapshotAlgo = sortAlgorithm

        // Fast path: if no search/filters and the UI sort matches the store fetch order
        // (depdate ascending), publish directly without recomputing.
        let noSearch = snapshotSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let noFilters = snapshotMin == nil && snapshotMax == nil &&
                        snapshotOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        snapshotDest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        snapshotStart == nil && snapshotEnd == nil
        let matchesStoreOrder = (snapshotKey == .date && snapshotOrder == .ascending)
        if noSearch && noFilters && matchesStoreOrder {
            self.flights = snapshotAll
            self.maybePrefetchMore()
            return
        }

        computeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let dateFormats = [
                "yyyy-MM-dd",
                "yyyy/MM/dd",
                "dd/MM/yyyy",
                "MM/dd/yyyy",
                "dd-MM-yyyy",
                "MM-dd-yyyy",
                "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd HH:mm:ss"
            ]
            let dateFormatters: [DateFormatter] = {
                var arr: [DateFormatter] = []
                arr.reserveCapacity(dateFormats.count)
                for f in dateFormats {
                    let df = DateFormatter()
                    df.locale = Locale(identifier: "en_US_POSIX")
                    df.dateFormat = f
                    arr.append(df)
                }
                return arr
            }()
            func parseDate(_ string: String) -> Date? {
                for df in dateFormatters {
                    if let d = df.date(from: string) { return d }
                }
                return nil
            }
            
            // Local date cache to avoid reparsing the same strings repeatedly during this run
            var localDateCache: [String: Date] = [:]
            func cachedDate(_ string: String) -> Date? {
                if let d = localDateCache[string] { return d }
                if let d = parseDate(string) { localDateCache[string] = d; return d }
                return nil
            }

            func parseCodes(_ s: String) -> Set<String> {
                let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                let codes = parts.filter { $0.count == 3 }.map { $0.uppercased() }
                return Set(codes)
            }

            // Build filtered list
            var result = snapshotAll

            let trimmed = snapshotSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let lower = trimmed.lowercased()
                result = result.filter { flight in
                    flight.origin.lowercased().contains(lower) ||
                    flight.destination.lowercased().contains(lower) ||
                    flight.airline.lowercased().contains(lower)
                }
            }

            if let min = snapshotMin {
                result = result.filter { $0.price_eco >= min }
            }
            if let max = snapshotMax {
                result = result.filter { $0.price_eco <= max }
            }
            if !snapshotOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let codes = parseCodes(snapshotOrigin)
                if !codes.isEmpty {
                    result = result.filter { codes.contains($0.origin.uppercased()) }
                } else {
                    let lower = snapshotOrigin.lowercased()
                    result = result.filter { $0.origin.lowercased().contains(lower) }
                }
            }
            if !snapshotDest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let codes = parseCodes(snapshotDest)
                if !codes.isEmpty {
                    result = result.filter { codes.contains($0.destination.uppercased()) }
                } else {
                    let lower = snapshotDest.lowercased()
                    result = result.filter { $0.destination.lowercased().contains(lower) }
                }
            }
            if snapshotStart != nil || snapshotEnd != nil {
                result = result.filter { flight in
                    guard let date = cachedDate(flight.depdate) else { return false }
                    if let start = snapshotStart, date < start { return false }
                    if let end = snapshotEnd, date > end { return false }
                    return true
                }
            }

            // Precompute dates once for the current result set to avoid repeated lookups during comparisons
            let precomputedDatesByID: [Int: Date] = Dictionary(uniqueKeysWithValues: result.compactMap { f in
                if let d = cachedDate(f.depdate) { return (f.id, d) }
                return nil
            })

            // Build comparator
            let comparator: (Flights, Flights) -> Bool = { a, b in
                let ascending = (snapshotOrder == .ascending)
                switch snapshotKey {
                case .price:
                    return ascending ? (a.price_eco < b.price_eco) : (a.price_eco > b.price_eco)
                case .date:
                    let da = precomputedDatesByID[a.id]
                    let db = precomputedDatesByID[b.id]
                    switch (da, db) {
                    case let (l?, r?):
                        return ascending ? (l < r) : (l > r)
                    case (nil, nil):
                        return false
                    case (nil, _):
                        return !ascending
                    case (_, nil):
                        return ascending
                    }
                case .duration:
                    return ascending ? (a.duration < b.duration) : (a.duration > b.duration)
                }
            }

            // Apply chosen algorithm with timing
            let clock = ContinuousClock()
            let start = clock.now
            switch snapshotAlgo {
            case .bubble:
                result = await bubbleSort(result, by: comparator)
            case .selection:
                result = await selectionSort(result, by: comparator)
            case .insertion:
                result = await insertionSort(result, by: comparator)
            case .quick:
                result = await quickSort(result, by: comparator)
            case .merge:
                result = await mergeSort(result, by: comparator)
            }
            let duration = start.duration(to: clock.now)
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000.0

            let runSeconds = seconds
            let runKey = snapshotKey
            let runOrder = snapshotOrder
            let runAlgo = snapshotAlgo

            // Publish back on the main actor (if not cancelled)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.flights = result
                self.maybePrefetchMore(currentResultCount: result.count)

                // Record and print performance run
                self.runCounter += 1
                let record = RunRecord(
                    id: self.runCounter,
                    sortKey: runKey,
                    sortOrder: runOrder,
                    algorithm: runAlgo,
                    durationSeconds: runSeconds
                )
                self.runHistory.append(record)
                let keyStr = record.sortKey.rawValue
                let orderStr = record.sortOrder.rawValue
                let algoStr = record.algorithm.rawValue
                let timeStr = String(format: "%.5f", record.durationSeconds)
                print("[SortMetrics] run\(record.id): key=\(keyStr), order=\(orderStr), algo=\(algoStr), time=\(timeStr)s")
            }
        }
    }

    /// Triggers loading of the next page when the UI approaches the end of the current list.
    /// - Parameter item: The item that just appeared in the UI (or nil to force a load).
    func loadMoreIfNeeded(currentItem item: Flights?) {
        guard let item = item else {
            loadNextPage()
            return
        }
        let thresholdIndex = flights.index(flights.endIndex, offsetBy: -200, limitedBy: flights.startIndex) ?? flights.startIndex
        if let idx = flights.firstIndex(where: { $0.id == item.id }), idx >= thresholdIndex {
            loadNextPage()
        }
    }

    /// Opportunistically prefetches more pages while idle and also drives loading when searches/filters yield no results yet.
    private func maybePrefetchMore(currentResultCount: Int? = nil) {
        // If we have active criteria (search or filters) and no results yet, keep loading more pages.
        if let count = currentResultCount, count == 0, hasMore, !isBackgroundLoading {
            loadNextPage()
            return
        }
        // Opportunistic prefetch when idle (only when not searching)
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if hasMore && allFlights.count < 1000 && !isBackgroundLoading {
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

    ///Bubble sort (O(n^2)).
    private func bubbleSort(_ array: [Flights], by areInIncreasingOrder: (Flights, Flights) -> Bool) async -> [Flights] {
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
                if i % 1024 == 0 { await Task.yield() }
            }
            await Task.yield()
        } while swapped
        return a
    }

    /// Selection sort (O(n^2))
    private func selectionSort(_ array: [Flights], by areInIncreasingOrder: (Flights, Flights) -> Bool) async -> [Flights] {
        var a = array
        for i in 0..<a.count {
            var minIndex = i
            for j in (i + 1)..<a.count {
                if areInIncreasingOrder(a[j], a[minIndex]) {
                    minIndex = j
                }
                if (j - i) % 2048 == 0 { await Task.yield() }
            }
            if i != minIndex { a.swapAt(i, minIndex) }
            if i % 256 == 0 { await Task.yield() }
        }
        return a
    }

    ///Insertion sort (O(n^2))
    private func insertionSort(_ array: [Flights], by areInIncreasingOrder: (Flights, Flights) -> Bool) async -> [Flights] {
        var a = array
        for i in 1..<a.count {
            var j = i
            let key = a[j]
            while j > 0 && areInIncreasingOrder(key, a[j - 1]) == true {
                a[j] = a[j - 1]
                j -= 1
                if j % 2048 == 0 { await Task.yield() }
            }
            a[j] = key
            if i % 256 == 0 { await Task.yield() }
        }
        return a
    }

    /// Quick sort (average O(n log n)).
    private func quickSort(_ array: [Flights], by areInIncreasingOrder: (Flights, Flights) -> Bool) async -> [Flights] {
        var a = array
        func qs(_ low: Int, _ high: Int) async {
            if low >= high { return }
            if (high - low) > 2048 { await Task.yield() }
            let p = partition(&a, low, high)
            await qs(low, p - 1)
            await qs(p + 1, high)
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
        if a.count > 1 { await qs(0, a.count - 1) }
        return a
    }

    ///Merge sort (O(n log n)). uses extra memory.
    private func mergeSort(_ array: [Flights], by areInIncreasingOrder: (Flights, Flights) -> Bool) async -> [Flights] {
        func ms(_ a: [Flights]) async -> [Flights] {
            guard a.count > 1 else { return a }
            let mid = a.count / 2
            let left = await ms(Array(a[..<mid]))
            let right = await ms(Array(a[mid...]))
            return await merge(left, right)
        }
        func merge(_ left: [Flights], _ right: [Flights]) async -> [Flights] {
            var i = 0, j = 0
            var out: [Flights] = []
            out.reserveCapacity(left.count + right.count)
            while i < left.count && j < right.count {
                if areInIncreasingOrder(left[i], right[j]) {
                    out.append(left[i]); i += 1
                } else {
                    out.append(right[j]); j += 1
                }
                if (i + j) % 4096 == 0 { await Task.yield() }
            }
            if i < left.count { out.append(contentsOf: left[i...]) }
            if j < right.count { out.append(contentsOf: right[j...]) }
            return out
        }
        return await ms(array)
    }
    
    
    
    
}

