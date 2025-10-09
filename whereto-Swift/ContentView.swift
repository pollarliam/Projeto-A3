import SwiftUI
import MapKit




struct MainView: View {
    @StateObject private var viewModel = FlightsViewModel()
    @State private var sidebarSelection: String? = "overview"
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 100, longitudeDelta: 100)
        )
    )
    
    
    var body: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                // Barra de pesquisa
                SearchBarView()
                // Cartas com voos
                Section {
                    ForEach(viewModel.flights) { flight in
                        FlightCardView(
                            code: "\(flight.airline) \(flight.id)",
                            route: "\(flight.origin) → \(flight.destination)",
                            status: "",
                            dep: "",
                            arr: "—",
                            priceEco: flight.priceEco,
                            priceExec: flight.priceExec,
                            pricePremium: flight.pricePremium
                        )
                    }
                }
                .listSectionSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .frame(minWidth: 280)
            .onAppear {
                viewModel.load()
            }
            .toolbar {
                Button("Sort by Price") {
                    viewModel.flights.sort { $0.priceEco < $1.priceEco }
                }
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
    let priceEco: String
    let priceExec: String
    let pricePremium: String
    
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
            HStack {
                Text("Eco: \(priceEco,) · Exec: \(priceExec,) · Premium: \(pricePremium,)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
    @State private var searchText: String = ""
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
