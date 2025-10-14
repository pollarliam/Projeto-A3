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
                            status: flight.demand,
                            dep: flight.depdate,
                            arr: ""
                        )
                    }
                }
                .listSectionSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .frame(minWidth: 280)
            .task {
                #if DEBUG
                debugValidateContainer()
                #endif
                viewModel.load()
            }
        } detail: {
            ZStack {
                // Globo
                Map(position: $cameraPosition)
                    .mapStyle(.imagery(elevation: .realistic))
                    .ignoresSafeArea()
                
                
            }
        }
    }
}


private struct FlightCardView: View {
    let code: String
    let route: String
    let status: String
    let dep: String
    let arr: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(code)
                    .font(.headline)
                Spacer()
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
            }
            Text(route)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Image(systemName: "airplane.departure")
                    Text(dep)
                }
                HStack(spacing: 4) {
                    Image(systemName: "airplane.arrival")
                    Text(arr)
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
    
    private var statusColor: Color {
        switch status.lowercased() {
        case "on time", "boarding":
            return .green
        case "delayed":
            return .orange
        default:
            return .secondary
        }
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
            .padding(8)
            .background(.primary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.clear)
    }
}

#Preview {
    MainView()
}
