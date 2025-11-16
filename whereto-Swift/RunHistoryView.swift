import SwiftUI
import Combine

// A tiny global registry so secondary windows can access the same FlightsViewModel instance
final class FlightsViewModelRegistry: ObservableObject {
    static let shared = FlightsViewModelRegistry()
    private init() {}
    @Published var current: FlightsViewModel?
}

struct RunHistoryView: View {
    // We access the current view model via the registry to avoid changing the main UI wiring
    @StateObject private var registry = FlightsViewModelRegistry.shared
    @State private var runs: [FlightsViewModel.RunRecord] = []
    @State private var searchRuns: [FlightsViewModel.SearchRunRecord] = []
    @State private var cancellable: AnyCancellable?
    @State private var searchCancellable: AnyCancellable?

    var body: some View {
        Group {
            if let vm = registry.current {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sorting Metrics")
                        .font(.headline)
                    List {
                        ForEach(runs) { record in
                            Text("run\(record.id): key=\(record.sortKey.rawValue), order=\(record.sortOrder.rawValue), algo=\(record.algorithm.rawValue), time=\(String(format: "%.5f", record.durationSeconds))s")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .frame(minHeight: 140)

                    Text("Search Metrics")
                        .font(.headline)
                        .padding(.top, 8)
                    List {
                        ForEach(searchRuns) { record in
                            Text("run\(record.id): key=\(record.key.rawValue), algo=\(record.algorithm.rawValue), query=\(record.query), matches=\(record.matches), time=\(String(format: "%.5f", record.durationSeconds))s")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .frame(minHeight: 140)
                }
                .navigationTitle("Run History")
                .frame(minWidth: 500, minHeight: 380)
                .onAppear {
                    // Seed with current history
                    runs = vm.runHistory
                    searchRuns = vm.searchRunHistory
                    // Cancel any prior subscriptions
                    cancellable?.cancel()
                    searchCancellable?.cancel()
                    // Subscribe to future updates
                    cancellable = vm.$runHistory
                        .receive(on: DispatchQueue.main)
                        .sink { newRuns in
                            runs = newRuns
                        }
                    searchCancellable = vm.$searchRunHistory
                        .receive(on: DispatchQueue.main)
                        .sink { newRuns in
                            searchRuns = newRuns
                        }
                }
                .onDisappear {
                    cancellable?.cancel(); cancellable = nil
                    searchCancellable?.cancel(); searchCancellable = nil
                }
            } else {
                VStack(spacing: 12) {
                    Text("No run history yet")
                        .font(.headline)
                    Text("Open the main window and perform a sort to generate runs.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 360, minHeight: 200)
            }
        }
        .padding(0)
        .onReceive(registry.$current) { newVM in
            guard let newVM else { return }
            runs = newVM.runHistory
            searchRuns = newVM.searchRunHistory
            cancellable?.cancel()
            searchCancellable?.cancel()
            cancellable = newVM.$runHistory
                .receive(on: DispatchQueue.main)
                .sink { newRuns in runs = newRuns }
            searchCancellable = newVM.$searchRunHistory
                .receive(on: DispatchQueue.main)
                .sink { newRuns in searchRuns = newRuns }
        }
    }
}

#Preview {
    RunHistoryView()
}
