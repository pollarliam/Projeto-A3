import SwiftUI
import MapKit
import SwiftData

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

    private struct FoundAirport: Identifiable {
        let id = UUID()
        let code: String
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    private actor AirportSearchService {
        static let shared = AirportSearchService()
        private var cache: [String: FoundAirport] = [:]

        func resolve(code rawCode: String, biasRegion: MKCoordinateRegion? = nil) async -> FoundAirport? {
            let code = rawCode.uppercased()
            if let cached = cache[code] { return cached }

            if let result = await search(query: "\(code) airport", biasRegion: biasRegion, code: code) {
                cache[code] = result
                return result
            }
            if let result = await search(query: code, biasRegion: biasRegion, code: code) {
                cache[code] = result
                return result
            }
            return nil
        }

        private func search(query: String, biasRegion: MKCoordinateRegion?, code: String) async -> FoundAirport? {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            if let biasRegion { request.region = biasRegion }
            let search = MKLocalSearch(request: request)
            do {
                let response = try await search.start()
                let items = response.mapItems
                if let airportItem = items.first(where: { $0.pointOfInterestCategory == .airport }) {
                    return FoundAirport(code: code, name: airportItem.name ?? code, coordinate: airportItem.placemark.coordinate)
                }
                if let nameMatch = items.first(where: { ($0.name ?? "").localizedCaseInsensitiveContains(code) || ($0.name ?? "").localizedCaseInsensitiveContains("airport") }) {
                    return FoundAirport(code: code, name: nameMatch.name ?? code, coordinate: nameMatch.placemark.coordinate)
                }
                if let first = items.first {
                    return FoundAirport(code: code, name: first.name ?? code, coordinate: first.placemark.coordinate)
                }
            } catch {
                // ignore and return nil
            }
            return nil
        }
    }

    init(context: ModelContext) {
        let vm = FlightsViewModel(context: context)
        _viewModel = StateObject(wrappedValue: vm)
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
                        Task { await resolvePinsForSelectedFlight() }
                    }
                    .onAppear {
                        viewModel.loadMoreIfNeeded(currentItem: flight)
                    }
                }
            }
            .listSectionSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .searchable(text: $viewModel.searchText, placement: .sidebar, prompt: "Where to?")
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
                        Text("Bubble").tag(FlightsViewModel.SortAlgorithm.bubble)
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
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease",)
            }
        }
        .overlay(alignment: .topLeading) {
            if viewModel.isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.leading, 8)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .task {
            #if DEBUG
            let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            if !isPreview {
                viewModel.load()
            }
            #else
            viewModel.load()
            #endif
        }
    }

    /// The right-hand detail view: a globe-like map styled with imagery and elevation.
    private var globeView: some View {
        ZStack {
            Map(position: $cameraPosition) {
                ForEach(resolvedPins) { pin in
                    Marker(pin.name, coordinate: pin.coordinate)
                }
            }
            .mapStyle(.imagery(elevation: .realistic))
            .ignoresSafeArea()

            VStack {
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.mini)
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
            await MainActor.run { resolvedPins = [] }
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
            fitCamera(to: results.map { $0.coordinate })
        }
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
                Text(price, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
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
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }
}

private struct SearchBarView: View {
    @Binding var searchText: String
    
    init(searchText: Binding<String>) {
        self._searchText = searchText
    }
    
    var body: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Where to?", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding()
            .background(.primary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.clear)
    }
}

#Preview {
    MainView()
        .modelContainer(Database.container)
}

