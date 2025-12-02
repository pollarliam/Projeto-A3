// AirportDirectory.swift
// Local airport directory (IATA + coordinates) loaded from bundled JSON.
//
// Provides simple lookup utilities so your Foundation Model (or any search agent)
// can resolve codes to cities and coordinates without inferring or calling Maps.

import Foundation
import CoreLocation

/// A single airport entry.
public struct Airport: Codable, Hashable, Identifiable {
    public var id: String { code }
    /// IATA 3-letter code, e.g. "YYZ".
    public let code: String
    /// Human-friendly airport name (optional). If absent, you can display the city.
    public let name: String?
    /// City where the airport is located, e.g. "Toronto".
    public let city: String
    /// Latitude in decimal degrees.
    public let latitude: Double
    /// Longitude in decimal degrees.
    public let longitude: Double
}

public extension Airport {
    /// Convenience coordinate for MapKit/CoreLocation consumers.
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Immutable, in-memory directory of airports loaded from `airports.json` in the app bundle.
///
/// - Thread-safe by construction: data is loaded once at init and stored in `let` properties.
/// - Lookups:
///   - `airport(forCode:)` — fast dictionary lookup by IATA code (case-insensitive)
///   - `airports(inCity:)` — exact city match (diacritic/case-insensitive)
///   - `searchAirports(matching:)` — substring search across code, city, and name
///   - `coordinate(forCode:)` — convenience helper for map pinning
public struct AirportDirectory {
    public static let shared = AirportDirectory(bundle: .main, resourceName: "IATA_codes")

    public let airports: [Airport]
    private let byCode: [String: Airport]
    private let byCity: [String: [Airport]]

    public init(bundle: Bundle = .main, resourceName: String = "airports") {
        let loaded = AirportDirectory.load(from: bundle, resourceName: resourceName)
        self.airports = loaded
        self.byCode = Dictionary(uniqueKeysWithValues: loaded.map { ($0.code.uppercased(), $0) })
        self.byCity = Dictionary(grouping: loaded, by: { AirportDirectory.normalize($0.city) })
    }

    /// Returns the airport for an IATA code (case-insensitive), e.g. "YYZ".
    public func airport(forCode code: String) -> Airport? {
        byCode[AirportDirectory.normalizeCode(code)]
    }

    /// Returns all airports for an exact city match (case/diacritic-insensitive).
    public func airports(inCity city: String) -> [Airport] {
        byCity[AirportDirectory.normalize(city)] ?? []
    }

    /// Simple substring search across code, city, and name. Returns up to `limit` results.
    public func searchAirports(matching query: String, limit: Int = 10) -> [Airport] {
        let qCode = AirportDirectory.normalizeCode(query)
        let q = AirportDirectory.normalize(query)
        if q.isEmpty && qCode.isEmpty { return [] }

        var results: [Airport] = []
        for a in airports {
            if a.code.uppercased().contains(qCode) ||
               AirportDirectory.normalize(a.city).contains(q) ||
               AirportDirectory.normalize(a.name ?? "").contains(q) {
                results.append(a)
                if results.count >= limit { break }
            }
        }
        return results
    }

    /// Convenience coordinate lookup for an IATA code.
    public func coordinate(forCode code: String) -> CLLocationCoordinate2D? {
        airport(forCode: code)?.coordinate
    }
}

// MARK: - Loading & Normalization

private extension AirportDirectory {
    struct SimpleAirport: Decodable {
        let city: String
        let latitude: Double
        let longitude: Double
        let name: String?
        let country: String?
    }

    static func load(from bundle: Bundle, resourceName: String) -> [Airport] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") ?? bundle.url(forResource: resourceName, withExtension: "JSON") else {
            assertionFailure("airports JSON not found in bundle. Ensure it is included in the app target.")
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()

            // Try dictionary keyed by IATA code first.
            if let dict = try? decoder.decode([String: SimpleAirport].self, from: data) {
                let mapped: [Airport] = dict.map { (code, value) in
                    Airport(
                        code: code.uppercased(),
                        name: value.name,
                        city: value.city,
                        latitude: value.latitude,
                        longitude: value.longitude
                    )
                }
                return mapped.sorted { $0.code < $1.code }
            }

            // Fallback to array form with explicit `code` fields in each object.
            if let array = try? decoder.decode([Airport].self, from: data) {
                return array
            }

            assertionFailure("airports JSON had unexpected shape.")
            return []
        } catch {
            assertionFailure("Failed to decode airports JSON: \(error)")
            return []
        }
    }

    static func normalizeCode(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

#if DEBUG
/// Quick debug helper to validate that the JSON is present and decodes.
public func debugValidateAirportDirectory() {
    let dir = AirportDirectory.shared
    print("[Airports] Loaded entries:", dir.airports.count)
    if let sample = dir.airport(forCode: "YYZ") {
        print("[Airports] Sample YYZ →", sample.city, sample.latitude, sample.longitude)
    }
}
#endif

