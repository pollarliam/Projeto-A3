//
//  ViewModel.swift
//  whereto-Swift
//
//  Created by Ramael Cerqueira on 2025/10/9.
//

import Foundation
import Combine

@MainActor
final class FlightsViewModel: ObservableObject {
    @Published var flights: [Flight] = []
    
    func load() {
        do {
            flights = try loadFlightsFromBundle()
        } catch {
            print("Failed to load flights: \(error)")
        }
    }
}
