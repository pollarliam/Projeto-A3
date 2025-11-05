import SwiftUI
import MapKit
import FoundationModels

struct MockMainView: View {
    var body: some View {
        MockMainContentView()
    }
}

private struct MockFlight: Identifiable, Equatable {
    let id: Int
    let airline: String
    let origin: String
    let destination: String
    let priceEco: Double
    let depdate: String
}

private struct MockMainContentView: View {
    private let model = SystemLanguageModel.default
    
    
    @State private var flights: [MockFlight] = [
        MockFlight(id: 0004, airline: "Tanngrisnir", origin: "ASG", destination: "VNM", priceEco: 329.99, depdate: "Oct 21, 09:35"),
        MockFlight(id: 0004, airline: "Tanngrisnir", origin: "ASG", destination: "VNM", priceEco: 329.99, depdate: "Oct 21, 09:35"),
        MockFlight(id: 0004, airline: "Tanngrisnir", origin: "ASG", destination: "VNM", priceEco: 329.99, depdate: "Oct 21, 09:35"),
        MockFlight(id: 0004, airline: "Tanngrisnir", origin: "ASG", destination: "VNM", priceEco: 329.99, depdate: "Oct 21, 09:35"),
    ]

    // Mocked loading and search states
    @State private var isLoading: Bool = false
    @State private var searchText: String = ""
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 100, longitudeDelta: 100)
        )
    )

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebarList
        } detail: {
            globeView
        }
    }

    private var filteredFlights: [MockFlight] {
        guard !searchText.isEmpty else { return flights }
        return flights.filter { flight in
            let haystack = "\(flight.airline) \(flight.id) \(flight.origin) \(flight.destination)".lowercased()
            return haystack.contains(searchText.lowercased())
        }
    }

    private var sidebarList: some View {
        List {
            Section {
                ForEach(filteredFlights) { flight in
                    FlightCardView(
                        code: flight.airline + " " + String(flight.id),
                        route: "\(flight.origin) → \(flight.destination)",
                        price: flight.priceEco,
                        dep: flight.depdate
                    )
                    .onAppear {
                        // Simulate pagination if needed by appending more mock items
                        guard flight == filteredFlights.last else { return }
                        // Toggle to true to visualize the loading pill
                        // isLoading = true
                    }
                }
            }
            .listSectionSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Hvert?")
        .frame(minWidth: 280)
        .toolbar {
            Button("Filter", systemImage: "line.3.horizontal.decrease") {}
        }
        .overlay(alignment: .topLeading) {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.leading, 8)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
    }

    private var globeView: some View {
        ZStack {
            Map(position: $cameraPosition)
                .mapStyle(.imagery(elevation: .realistic))
                .ignoresSafeArea()

            VStack {
                HStack {
                    if isLoading {
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
        VStack(alignment: .leading, spacing: 6) {
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
       
    }
}

#Preview("Mock UI") {
    MockMainView()
}
