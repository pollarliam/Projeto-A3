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
            Map(position: $cameraPosition)
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
        .modelContainer(for: [Flights.self], inMemory: true)
}

