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

    @State private var selectionTask: Task<Void, Never>? = nil
    @State private var selectionToken: UUID = UUID()

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
                        // Dismiss current popover and clear previous summary before selecting a new flight
                        destinationPin = nil
                        destinationSummary = nil
                        selectedFlight = flight
                        // Cancel any in-flight selection work and start a new token
                        selectionTask?.cancel()
                        let token = UUID()
                        selectionToken = token
                        selectionTask = Task {
                            await resolvePins(for: flight, token: token)
                            await summarize(for: flight, token: token)
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
                Section("Ordenar por") {
                    Picker("Critério", selection: $viewModel.sortKey) {
                        Text("Preço").tag(FlightsViewModel.SortKey.price)
                        Text("Data").tag(FlightsViewModel.SortKey.date)
                        Text("Duração").tag(FlightsViewModel.SortKey.duration)
                    }
                    Picker("Ordem", selection: $viewModel.sortOrder) {
                        Text("Crescente").tag(FlightsViewModel.SortOrder.ascending)
                        Text("Decrescente").tag(FlightsViewModel.SortOrder.descending)
                    }
                }
                
                    Picker("Algoritmo", selection: $viewModel.sortAlgorithm) {
                        Text("Seleção").tag(FlightsViewModel.SortAlgorithm.selection)
                        Text("Inserção").tag(FlightsViewModel.SortAlgorithm.insertion)
                        Text("Quicksort").tag(FlightsViewModel.SortAlgorithm.quick)
                        Text("Merge sort").tag(FlightsViewModel.SortAlgorithm.merge)
                    }
                    .pickerStyle(.inline)
                
                Section("Filtros") {
                    Button("Até R$ 100") { viewModel.maxPrice = 100 }
                    Button("R$ 100 – R$ 300") { viewModel.minPrice = 100; viewModel.maxPrice = 300 }
                    Button("R$ 300 – R$ 600") { viewModel.minPrice = 300; viewModel.maxPrice = 600 }
                    Button("Acima de R$ 600") { viewModel.minPrice = 600; viewModel.maxPrice = nil }
                    Divider()
                    Button("Limpar filtros") {
                        viewModel.minPrice = nil
                        viewModel.maxPrice = nil
                        viewModel.originFilter = ""
                        viewModel.destinationFilter = ""
                        viewModel.dateStart = nil
                        viewModel.dateEnd = nil
                    }
                    Divider()
                    Button("Busca Algorítmica…") {
                        showBenchmarkSheet = true
                    }
                }
            } label: {
                Label("Filtros", systemImage: "line.3.horizontal.decrease",)
            }
        }
        .searchable(text: $viewModel.searchText, placement: .sidebar)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Carregando voos…")
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
                        Text("Carregando tudo… \(Int(progress * 100))%")
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
                            Button("Restaurar") {
                                if let snap = initialFilters { restoreFilters(snap) }
                                errorBanner = nil
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        Button("Reportar") {
                            Task { await reportGuardrailFeedback() }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        Button("Fechar") { errorBanner = nil }
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
                            title: "Sobre \(flight.destination)",
                            summary: destinationSummary,
                            isLoading: isSummarizingDestination,
                            airline: flight.airline,
                            origin: flight.origin,
                            destination: flight.destination,
                            depdate: flight.depdate,
                            durationMinutes: Int(flight.duration),
                            price: flight.price_eco,
                            onClose: {
                                destinationPin = nil
                                destinationSummary = nil
                                selectedFlight = nil
                                // Invalidate any in-flight work for the previous selection
                                selectionTask?.cancel()
                                selectionToken = UUID()
                                isSummarizingDestination = false
                            }
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
                            Text("Carregando…")
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

    private func resolvePins(for flight: Flights, token: UUID) async {
        // Determine any bias region (currently unused but kept for compatibility)
        let biasRegion: MKCoordinateRegion?
        switch cameraPosition {
        default:
            biasRegion = nil
        }
        if Task.isCancelled { return }
        async let origin = AirportSearchService.shared.resolve(code: flight.origin, biasRegion: biasRegion)
        async let dest = AirportSearchService.shared.resolve(code: flight.destination, biasRegion: biasRegion)
        let results = await [origin, dest].compactMap { $0 }
        if Task.isCancelled { return }
        await MainActor.run {
            // Only apply if this is still the current selection
            guard selectionToken == token else { return }
            resolvedPins = results
            if results.count == 2 {
                // Maintain route line
                updateRoutePolyline(from: results[0].coordinate, to: results[1].coordinate)
            } else {
                routeCoordinates = []
            }
            // Identify destination pin using the selected flight's destination code
            destinationPin = results.first(where: { $0.code.caseInsensitiveCompare(flight.destination) == .orderedSame }) ?? results.last
            // Center camera on destination pin if available; otherwise fit to whatever we have
            if let dest = destinationPin {
                centerCamera(on: dest.coordinate)
            } else {
                fitCamera(to: results.map { $0.coordinate })
            }
        }
    }

    private func summarize(for flight: Flights, token: UUID) async {
        // Check model availability first; if unavailable, clear and return silently
        switch SystemLanguageModel.default.availability {
        case .available: break
        default:
            await MainActor.run {
                if selectionToken == token {
                    destinationSummary = nil
                    isSummarizingDestination = false
                }
            }
            return
        }
        await MainActor.run {
            if selectionToken == token {
                isSummarizingDestination = true
            }
        }
        defer {
            Task { await MainActor.run {
                if selectionToken == token {
                    isSummarizingDestination = false
                }
            } }
        }
        do {
            let summary = try await DestinationSummaryAgent.shared.summarize(
                destinationCode: flight.destination,
                originCode: flight.origin,
                airline: flight.airline,
                depdate: flight.depdate,
                durationMinutes: Int(flight.duration)
            )
            if Task.isCancelled { return }
            await MainActor.run {
                if selectionToken == token {
                    destinationSummary = summary
                }
            }
        } catch {
            // Leave previous summary if any; optionally log
            print("[Summary] failed:", error.localizedDescription)
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
            errorBanner = "Anexo de feedback registrado. Por favor envie pelo Feedback Assistant."
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
                Text(price, format: .currency(code: "BRL"))
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
            Text("Benchmark de Busca Algorítmica")
                .font(.headline)

            TextField("Consulta para benchmark", text: $viewModel.benchmarkQuery)
                .textFieldStyle(.roundedBorder)

            Picker("Campo", selection: $viewModel.searchKey) {
                Text("ID").tag(FlightsViewModel.SearchKey.id)
                Text("Origem").tag(FlightsViewModel.SearchKey.origin)
                Text("Destino").tag(FlightsViewModel.SearchKey.destination)
                Text("Companhia").tag(FlightsViewModel.SearchKey.airline)
                Text("Preço").tag(FlightsViewModel.SearchKey.price)
            }

            Picker("Algoritmo", selection: $viewModel.searchAlgorithm) {
                Text("Linear").tag(FlightsViewModel.SearchAlgorithm.linear)
                Text("Binária").tag(FlightsViewModel.SearchAlgorithm.binary)
                Text("Hash").tag(FlightsViewModel.SearchAlgorithm.hash)
            }

            HStack {
                Button("Executar selecionado") {
                    viewModel.executeSearch(query: viewModel.benchmarkQuery)
                }
                Button("Executar todos") {
                    viewModel.runSearchBenchmarks()
                }
                Spacer()
                Button("Fechar") { dismiss() }
            }
            Divider()
            if viewModel.benchmarkResults.isEmpty {
                Text("Ainda não há resultados. Execute uma busca para ver correspondências.")
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
    let onClose: (() -> Void)

    init(
        title: String,
        summary: String?,
        isLoading: Bool,
        airline: String,
        origin: String,
        destination: String,
        depdate: String,
        durationMinutes: Int,
        price: Double,
        onClose: @escaping () -> Void = {}
    ) {
        self.title = title
        self.summary = summary
        self.isLoading = isLoading
        self.airline = airline
        self.origin = origin
        self.destination = destination
        self.depdate = depdate
        self.durationMinutes = durationMinutes
        self.price = price
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button(action: { onClose() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .padding(6)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
            if price > 0 {
                Text("Preço: \(price, format: .currency(code: "BRL"))")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.15), in: Capsule())
            }
            Group {
                if isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Obtendo um resumo rápido…")
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
                    Text("Nenhum resumo disponível.")
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

