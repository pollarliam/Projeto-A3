import SwiftUI
import MapKit
import SwiftData
import FoundationModels


/// Root SwiftUI view that reads the `ModelContext` from the environment and passes it to
/// `MainContentView`, where the `FlightsViewModel` is created.
struct MainView: View {
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        MainContentView(context: modelContext)
    }
}

/// The primary content view for the app.
///
/// Responsibilities:
/// - Owns a `FlightsViewModel` (`@StateObject`) for MVVM separation.
/// - Hosts a `NavigationSplitView` with a sidebar list of flights and a 3D globe map.
/// - Triggers initial data load in a `.task` once previews are not running.
///
/// Notes on MVVM:
/// - The view does not fetch data directly. It binds to `viewModel` state (`flights`, `isLoading`,
///   `searchText`, filters and sorting) and renders accordingly.
private struct MainContentView: View {
    @StateObject private var viewModel: FlightsViewModel
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 100, longitudeDelta: 100)
        )
    )
    @State private var selectedFlight: Flights?
    @State private var resolvedPins: [FoundAirport] = []
    @State private var showBenchmarkSheet: Bool = false
    @State private var routeCoordinates: [CLLocationCoordinate2D] = []

    @State private var destinationPin: FoundAirport? = nil
    @State private var destinationSummary: String? = nil
    @State private var isSummarizingDestination: Bool = false

    @State private var initialFilters: FiltersSnapshot? = nil
    @State private var lastFailedQuery: String? = nil
    @State private var lastErrorDescription: String? = nil
    @State private var errorBanner: String? = nil

    private struct FoundAirport: Identifiable {
        let id = UUID()
        let code: String
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    private actor AirportSearchService {
        static let shared = AirportSearchService()
        private var cache: [String: FoundAirport] = [:]

        /// Resolves an IATA code to a known airport from our bundled JSON.
        /// Ignores `biasRegion` (kept for call-site compatibility).
        func resolve(code rawCode: String, biasRegion: MKCoordinateRegion? = nil) async -> FoundAirport? {
            let code = rawCode.uppercased()
            if let cached = cache[code] { return cached }

            if let a = AirportDirectory.shared.airport(forCode: code) {
                let name = a.name ?? a.city
                let result = FoundAirport(code: code, name: name, coordinate: a.coordinate)
                cache[code] = result
                return result
            }
            return nil
        }
    }

    private struct FiltersSnapshot {
        var searchText: String
        var origin: String
        var destination: String
        var minPrice: Double?
        var maxPrice: Double?
        var dateStart: Date?
        var dateEnd: Date?
        var sortKey: FlightsViewModel.SortKey
        var sortOrder: FlightsViewModel.SortOrder
    }
    
    private func codesForInput(_ input: String) -> [String] {
        let dir = AirportDirectory.shared
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let upper = trimmed.uppercased()
        if upper.count == 3, dir.airport(forCode: upper) != nil {
            return [upper]
        }
        // Exact city match first
        let cityMatches = dir.airports(inCity: trimmed)
        if !cityMatches.isEmpty { return cityMatches.map { $0.code } }
        // Fallback: fuzzy search across name/city/code
        let results = dir.searchAirports(matching: trimmed, limit: 5)
        if !results.isEmpty { return results.map { $0.code } }
        return []
    }

    init(context: ModelContext) {
        let vm = FlightsViewModel(context: context)
        _viewModel = StateObject(wrappedValue: vm)
        FlightsViewModelRegistry.shared.current = vm
    }
    
    ///sidebar com mapa
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebarList //sidebar
        } detail: {
            globeView // mapa
        }
    }

    /// Sidebar list showing flights with search, sorting, and filter controls.
    private var sidebarList: some View {
        List {
            Section {
                ForEach(viewModel.flights, id: \.persistentModelID) { flight in
                    let code: String = "\(flight.airline) \(flight.id)"
                    let route: String = "\(flight.origin) → \(flight.destination)"
                    let price: Double = flight.price_eco
                    let dep: String = flight.depdate
                    
                    FlightCardView(
                        code: code,
                        route: route,
                        price: price,
                        dep: dep
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedFlight = flight
                        Task {
                            await resolvePinsForSelectedFlight()
                            await summarizeForSelectedFlight()
                        }
                    }
                    .onAppear {
                        viewModel.loadMoreIfNeeded(currentItem: flight)
                    }
                }
            }
            .listSectionSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .transaction { $0.animation = nil }
        .frame(minWidth: 280)
        .toolbar {
            Menu {
                Section("Sort by") {
                    Picker("Key", selection: $viewModel.sortKey) {
                        Text("Price").tag(FlightsViewModel.SortKey.price)
                        Text("Date").tag(FlightsViewModel.SortKey.date)
                        Text("Duration").tag(FlightsViewModel.SortKey.duration)
                    }
                    Picker("Order", selection: $viewModel.sortOrder) {
                        Text("Ascending").tag(FlightsViewModel.SortOrder.ascending)
                        Text("Descending").tag(FlightsViewModel.SortOrder.descending)
                    }
                }
                
                    Picker("Algorithm", selection: $viewModel.sortAlgorithm) {
                        Text("Selection").tag(FlightsViewModel.SortAlgorithm.selection)
                        Text("Insertion").tag(FlightsViewModel.SortAlgorithm.insertion)
                        Text("Quick").tag(FlightsViewModel.SortAlgorithm.quick)
                        Text("Merge").tag(FlightsViewModel.SortAlgorithm.merge)
                    }
                    .pickerStyle(.inline)
                
                Section("Filters") {
                    Button("Under $100") { viewModel.maxPrice = 100 }
                    Button("$100 – $300") { viewModel.minPrice = 100; viewModel.maxPrice = 300 }
                    Button("$300 – $600") { viewModel.minPrice = 300; viewModel.maxPrice = 600 }
                    Button("$600+") { viewModel.minPrice = 600; viewModel.maxPrice = nil }
                    Divider()
                    Button("Reset filters") {
                        viewModel.minPrice = nil
                        viewModel.maxPrice = nil
                        viewModel.originFilter = ""
                        viewModel.destinationFilter = ""
                        viewModel.dateStart = nil
                        viewModel.dateEnd = nil
                    }
                    Divider()
                    Button("Algorithmic Search…") {
                        showBenchmarkSheet = true
                    }
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease",)
            }
        }
        .searchable(text: $viewModel.searchText, placement: .sidebar)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading flights…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.opacity)
                }
                if let progress = viewModel.bulkLoadProgress {
                    HStack(spacing: 6) {
                        ProgressView(value: progress)
                            .controlSize(.small)
                        Text("Loading all… \(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.opacity)
                }
                if let message = errorBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text(message).font(.caption)
                        Spacer(minLength: 8)
                        if initialFilters != nil {
                            Button("Restore") {
                                if let snap = initialFilters { restoreFilters(snap) }
                                errorBanner = nil
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        Button("Report") {
                            Task { await reportGuardrailFeedback() }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        Button("Dismiss") { errorBanner = nil }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.quaternary, lineWidth: 1)
                    )
                    .transition(.opacity)
                }
            }
            .padding([.top, .leading], 8)
        }
        .task {
                viewModel.load()
                if initialFilters == nil {
                    initialFilters = snapshotCurrentFilters()
                }
        }
        .sheet(isPresented: $showBenchmarkSheet) {
            AlgorithmicSearchView(viewModel: viewModel)
        }
    }

    /// The right-hand detail view: a globe-like map styled with imagery and elevation.
    private var globeView: some View {
        ZStack {
            Map(position: $cameraPosition) {
                ForEach(resolvedPins) { pin in
                    Marker(pin.name, coordinate: pin.coordinate)
                }
                if let dest = destinationPin, let flight = selectedFlight {
                    Annotation("", coordinate: dest.coordinate, anchor: UnitPoint(x: 0.5, y: 1.0)) {
                        DestinationPopoverCard(
                            title: "About \(flight.destination)",
                            summary: destinationSummary,
                            isLoading: isSummarizingDestination,
                            airline: flight.airline,
                            origin: flight.origin,
                            destination: flight.destination,
                            depdate: flight.depdate,
                            durationMinutes: Int(flight.duration),
                            price: flight.price_eco
                        )
                    }
                }
                if routeCoordinates.count >= 2 {
                    MapPolyline(coordinates: routeCoordinates)
                        .stroke(.blue, lineWidth: 3)
                        .strokeStyle(style: .init(lineCap: .round, lineJoin: .round))

                }
            }
            .mapStyle(.imagery(elevation: .realistic))
            .ignoresSafeArea()

            VStack {
                HStack {
                    if viewModel.isLoading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Loading…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .background(.thinMaterial, in: Capsule())
                        .padding([.top, .leading], 8)
                    }
                    Spacer()
                }
                Spacer()
            }
            .allowsHitTesting(false)
        }
    }

    private func resolvePinsForSelectedFlight() async {
        guard let flight = selectedFlight else {
            await MainActor.run {
                resolvedPins = []
                routeCoordinates = []
            }
            return
        }
        let biasRegion: MKCoordinateRegion?
        switch cameraPosition {
        default:
            biasRegion = nil
        }
        async let origin = AirportSearchService.shared.resolve(code: flight.origin, biasRegion: biasRegion)
        async let dest = AirportSearchService.shared.resolve(code: flight.destination, biasRegion: biasRegion)
        let results = await [origin, dest].compactMap { $0 }
        await MainActor.run {
            resolvedPins = results
            if results.count == 2 {
                // Maintain route line
                updateRoutePolyline(from: results[0].coordinate, to: results[1].coordinate)
            } else {
                routeCoordinates = []
            }
            // Identify destination pin using the selected flight's destination code
            if let flight = selectedFlight {
                destinationPin = results.first(where: { $0.code.caseInsensitiveCompare(flight.destination) == .orderedSame })
            } else {
                destinationPin = results.last
            }
            // Center camera on destination pin if available; otherwise fit to whatever we have
            if let dest = destinationPin {
                centerCamera(on: dest.coordinate)
            } else {
                fitCamera(to: results.map { $0.coordinate })
            }
        }
    }
    
    private func updateRoutePolyline(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) {
        // Use MKGeodesicPolyline to sample a great-circle path that hugs the globe
        let geodesic = MKGeodesicPolyline(coordinates: [origin, destination], count: 2)
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: geodesic.pointCount)
        geodesic.getCoordinates(&coords, range: NSRange(location: 0, length: geodesic.pointCount))
        // Downsample to a reasonable number of points for SwiftUI Map rendering
        var sampled: [CLLocationCoordinate2D] = []
        let step = max(1, geodesic.pointCount / 128)
        for i in stride(from: 0, to: geodesic.pointCount, by: step) {
            sampled.append(coords[i])
        }
        if let last = coords.last {
            if let sampledLast = sampled.last {
                let eps = 1e-9
                let isSame = abs(sampledLast.latitude - last.latitude) < eps && abs(sampledLast.longitude - last.longitude) < eps
                if !isSame {
                    sampled.append(last)
                }
            } else {
                sampled.append(last)
            }
        }
        routeCoordinates = sampled
    }

    private func fitCamera(to coords: [CLLocationCoordinate2D]) {
        guard !coords.isEmpty else { return }
        if coords.count == 1 {
            cameraPosition = .region(MKCoordinateRegion(center: coords[0],
                                                        span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)))
            return
        }
        var minLat = coords.map(\.latitude).min()!
        var maxLat = coords.map(\.latitude).max()!
        var minLon = coords.map(\.longitude).min()!
        var maxLon = coords.map(\.longitude).max()!
        let latPad = max(2.0, (maxLat - minLat) * 0.3)
        let lonPad = max(2.0, (maxLon - minLon) * 0.3)
        minLat -= latPad; maxLat += latPad
        minLon -= lonPad; maxLon += lonPad
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2.0,
                                            longitude: (minLon + maxLon) / 2.0)
        let region = MKCoordinateRegion(center: center,
                                        span: MKCoordinateSpan(latitudeDelta: max(1.0, (maxLat - minLat)),
                                                               longitudeDelta: max(1.0, (maxLon - minLon))))
        cameraPosition = .region(region)
    }

    private func centerCamera(on coord: CLLocationCoordinate2D) {
        let region = MKCoordinateRegion(center: coord,
                                        span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 6))
        cameraPosition = .region(region)
    }

    private func summarizeForSelectedFlight() async {
        guard let flight = selectedFlight else {
            await MainActor.run { destinationSummary = nil }
            return
        }
        // Check model availability first; if unavailable, clear and return silently
        switch SystemLanguageModel.default.availability {
        case .available: break
        default:
            await MainActor.run { destinationSummary = nil }
            return
        }
        await MainActor.run { isSummarizingDestination = true }
        defer { Task { await MainActor.run { isSummarizingDestination = false } } }
        do {
            let summary = try await DestinationSummaryAgent.shared.summarize(
                destinationCode: flight.destination,
                originCode: flight.origin,
                airline: flight.airline,
                depdate: flight.depdate,
                durationMinutes: Int(flight.duration)
            )
            await MainActor.run { destinationSummary = summary }
        } catch {
            // Leave previous summary if any; optionally log
            print("[Summary] failed:", error.localizedDescription)
        }
    }

    private func snapshotCurrentFilters() -> FiltersSnapshot {
        return FiltersSnapshot(
            searchText: viewModel.searchText,
            origin: viewModel.originFilter,
            destination: viewModel.destinationFilter,
            minPrice: viewModel.minPrice,
            maxPrice: viewModel.maxPrice,
            dateStart: viewModel.dateStart,
            dateEnd: viewModel.dateEnd,
            sortKey: viewModel.sortKey,
            sortOrder: viewModel.sortOrder
        )
    }

    private func restoreFilters(_ snap: FiltersSnapshot) {
        viewModel.searchText = snap.searchText
        viewModel.originFilter = snap.origin
        viewModel.destinationFilter = snap.destination
        viewModel.minPrice = snap.minPrice
        viewModel.maxPrice = snap.maxPrice
        viewModel.dateStart = snap.dateStart
        viewModel.dateEnd = snap.dateEnd
        viewModel.sortKey = snap.sortKey
        viewModel.sortOrder = snap.sortOrder
    }

    private func clearFieldFiltersPreservingSort() {
        viewModel.originFilter = ""
        viewModel.destinationFilter = ""
        viewModel.minPrice = nil
        viewModel.maxPrice = nil
        viewModel.dateStart = nil
        viewModel.dateEnd = nil
    }

    private func reportGuardrailFeedback() async {
        let q = lastFailedQuery ?? viewModel.searchText
        let desc = lastErrorDescription
        await NaturalFlightSearch.shared.logGuardrailFeedback(query: q, errorDescription: desc)
        await MainActor.run {
            errorBanner = "Feedback attachment logged. Please file via Feedback Assistant."
        }
    }
}

private struct FlightCardView: View {
    let code: String
    let route: String
    let price: Double
    let dep: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(code)
                    .font(.headline)
                Spacer()
                Text(price, format: .currency(code: "R$"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(route)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Image(systemName: "airplane.departure")
                    Text(dep)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.primary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        
    }
}

private struct AlgorithmicSearchView: View {
    @ObservedObject var viewModel: FlightsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Algorithmic Search Benchmarks")
                .font(.headline)

            TextField("Benchmark query", text: $viewModel.benchmarkQuery)
                .textFieldStyle(.roundedBorder)

            Picker("Key", selection: $viewModel.searchKey) {
                Text("ID").tag(FlightsViewModel.SearchKey.id)
                Text("Origin").tag(FlightsViewModel.SearchKey.origin)
                Text("Destination").tag(FlightsViewModel.SearchKey.destination)
                Text("Airline").tag(FlightsViewModel.SearchKey.airline)
                Text("Price").tag(FlightsViewModel.SearchKey.price)
            }

            Picker("Algorithm", selection: $viewModel.searchAlgorithm) {
                Text("Linear").tag(FlightsViewModel.SearchAlgorithm.linear)
                Text("Binary").tag(FlightsViewModel.SearchAlgorithm.binary)
                Text("Hash").tag(FlightsViewModel.SearchAlgorithm.hash)
            }

            HStack {
                Button("Run Selected") {
                    viewModel.executeSearch(query: viewModel.benchmarkQuery)
                }
                Button("Run All") {
                    viewModel.runSearchBenchmarks()
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            Divider()
            if viewModel.benchmarkResults.isEmpty {
                Text("No results yet. Run a search to see matches.")
                    .foregroundStyle(.secondary)
            } else {
                List(viewModel.benchmarkResults, id: \.persistentModelID) { flight in
                    let code: String = "\(flight.airline) \(flight.id)"
                    let route: String = "\(flight.origin) → \(flight.destination)"
                    let price: Double = flight.price_eco
                    let dep: String = flight.depdate
                    FlightCardView(code: code, route: route, price: price, dep: dep)
                }
                .frame(minHeight: 200)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}

private struct BubbleWithPointer: Shape {
    var cornerRadius: CGFloat = 16
    var pointerSize: CGSize = CGSize(width: 20, height: 10)
    func path(in rect: CGRect) -> Path {
        var r = rect
        r.size.height -= pointerSize.height
        var p = Path(roundedRect: r, cornerRadius: cornerRadius)
        // Pointer centered at bottom
        let midX = r.midX
        p.move(to: CGPoint(x: midX - pointerSize.width/2, y: r.maxY))
        p.addLine(to: CGPoint(x: midX, y: r.maxY + pointerSize.height))
        p.addLine(to: CGPoint(x: midX + pointerSize.width/2, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct DestinationPopoverCard: View {
    let title: String
    let summary: String?
    let isLoading: Bool
    let airline: String
    let origin: String
    let destination: String
    let depdate: String
    let durationMinutes: Int
    let price: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Group {
                if isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Getting a quick overview…")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                } else if let summary {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(15)
                        .multilineTextAlignment(.leading)
                } else {
                    Text("No summary available.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                Text(airline).font(.footnote).bold()
                Text("\(origin) -> \(destination)")
                    .font(.subheadline).bold()
                Text(depdate).font(.footnote).foregroundStyle(.secondary)
                Text("\(durationMinutes) min").font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button {
                    // Hook for purchase
                } label: {
                    Text("Buy $\(String(format: "%.0f", price))")
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.green, in: Capsule())
                        .foregroundColor(.white)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(
            BubbleWithPointer()
                .fill(.ultraThickMaterial)
        )
        .overlay(
            BubbleWithPointer()
                .stroke(.quaternary, lineWidth: 1)
        )
        .shadow(radius: 12)
    }
}

#Preview {
    MainView()
        .modelContainer(Database.container)
}
