import SwiftUI
import MapKit
import SwiftData


struct MainView: View {
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        MainContentView(context: modelContext)
    }
}

private struct MainContentView: View {
    @StateObject private var viewModel: FlightsViewModel
    @State private var sidebarSelection: String? = "overview"
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 100, longitudeDelta: 100)
        )
    )
    
    init(context: ModelContext) {
        _viewModel = StateObject(wrappedValue: FlightsViewModel(context: context))
    }
    
    var body: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                // Barra de pesquisa
                SearchBarView(searchText: $viewModel.searchText)
                // Cartas com voos
                Section {
                    ForEach(viewModel.flights, id: \.id) { flight in
                        FlightCardView(
                            code: flight.airline + " " + String(flight.id),
                            route: "\(flight.origin) → \(flight.destination)",
                            price: flight.price_eco,
                            dep: flight.depdate
                        )
                        .onAppear {
                            viewModel.loadMoreIfNeeded(currentItem: flight)
                        }
                    }
                }
                .listSectionSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .frame(minWidth: 280)
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
                viewModel.load()
            }
        } detail: {
            ZStack {
                // Globo
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
}

