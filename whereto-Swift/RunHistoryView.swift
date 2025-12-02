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
                    Text("Métricas de Ordenação")
                        .font(.headline)
                    List {
                        ForEach(runs) { record in
                            Text("run\(record.id): chave=\(record.sortKey.rawValue), ordem=\(record.sortOrder.rawValue), algoritmo=\(record.algorithm.rawValue), tempo=\(String(format: "%.5f", record.durationSeconds))s")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .frame(minHeight: 140)

                    Text("Métricas de Busca")
                        .font(.headline)
                        .padding(.top, 8)
                    List {
                        ForEach(searchRuns) { record in
                            Text("run\(record.id): chave=\(record.key.rawValue), algoritmo=\(record.algorithm.rawValue), consulta=\(record.query), correspondências=\(record.matches), tempo=\(String(format: "%.5f", record.durationSeconds))s")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .frame(minHeight: 140)
                }
                .navigationTitle("Histórico de Execuções")
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
                    Text("Ainda não há histórico")
                        .font(.headline)
                    Text("Abra a janela principal e execute uma ordenação para gerar execuções.")
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
