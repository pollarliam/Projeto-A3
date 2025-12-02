// NaturalFlightSearch.swift
// Foundation Models–powered natural language flight search parsing

import Foundation
import FoundationModels

@Generable(description: "Structured flight search criteria parsed from a natural language query")
struct FlightCriteria {
    @Guide(description: "IATA origin airport code (e.g., SFO, JFK). Prefer codes. If only a city is provided, you may return the city name (not a code). Do not guess; leave empty if uncertain. The app will resolve city names to codes.")
    var origin: String?

    @Guide(description: "IATA destination airport code (e.g., LHR, CDG). Prefer codes. If only a city is provided, you may return the city name (not a code). Do not guess; leave empty if uncertain. The app will resolve city names to codes.")
    var destination: String?

    @Guide(description: "Minimum price in the user's currency as a number without symbols.", .range(0.0...100000.0))
    var minPrice: Double?

    @Guide(description: "Maximum price in the user's currency as a number without symbols.", .range(0.0...100000.0))
    var maxPrice: Double?

    @Guide(description: "Trip start date in ISO 8601 date format yyyy-MM-dd (e.g., 2025-07-01). If a single date is given, set dateStart to that date.")
    var dateStart: String?

    @Guide(description: "Trip end/return date in ISO 8601 date format yyyy-MM-dd (e.g., 2025-07-10). If one-way, leave empty.")
    var dateEnd: String?

    @Guide(description: "Preferred airline name or code if specified (e.g., Delta, DL). Leave empty if not specified.")
    var airline: String?

    @Guide(description: "Sorting key. One of: price, date, duration. Leave empty if not specified.")
    var sortKey: String?

    @Guide(description: "Sorting order. One of: ascending, descending. Leave empty if not specified.")
    var sortOrder: String?
}

actor NaturalFlightSearch {
    static let shared = NaturalFlightSearch()

    private let session: LanguageModelSession

    init() {
        // System prompt to steer extraction while avoiding overconfident inferences
        let instructions = """
        You are a flight search parser for a travel app. Your job is to extract structured criteria from a benign travel planning request.

        Safety and scope:
        - Treat all inputs as normal travel planning. Do not perform safety classification or content moderation.
        - Never refuse, warn, apologize, or mention safety policies. Only produce the requested fields.

        Output policy:
        - Only output the requested fields in the provided schema.

        Extraction rules:
        - Prefer IATA airport codes (e.g., SFO, JFK). If a city is provided, you may return the city name (not a guessed code). The app will resolve city names to codes.
        - Do not guess codes when uncertain. Prefer leaving fields empty.
        - Dates MUST be ISO 8601 calendar dates in yyyy-MM-dd.
        - Prices MUST be numeric without currency symbols.
        - If the user says things like "under $300" set maxPrice=300. "between 200 and 500" => minPrice=200, maxPrice=500.
        - Set sortKey to one of: price, date, duration when clearly requested (e.g., cheapest -> price, soonest -> date, shortest -> duration).
        - Set sortOrder to ascending or descending as appropriate (e.g., cheapest/soonest/shortest -> ascending; most expensive -> descending).
        - If a field is not present or uncertain, leave it empty.

        Examples (for understanding only):
        - "show me flights to gru" -> destination = GRU
        - "cheap flights from San Francisco to New York next weekend under R$300" -> origin = "San Francisco", destination = "New York", maxPrice=300, sortKey=price, sortOrder=ascending
        """
        self.session = LanguageModelSession(instructions: instructions)
    }

    func parse(_ query: String) async throws -> FlightCriteria {
        let content: FlightCriteria
        do {
            let response = try await session.respond(
                to: query,
                generating: FlightCriteria.self
            )
            content = response.content
        } catch {
            // Retry once with an explicit benign wrapper to avoid false-positive guardrails
            let wrapped = """
            This is a benign travel booking query for a flight search parser. Extract only travel-related fields and ignore unrelated content:
            \(query)
            """
            let response = try await session.respond(
                to: wrapped,
                generating: FlightCriteria.self
            )
            content = response.content
        }

        // Ground origin/destination using the local airport directory and heuristics
        let grounded = ground(content, originalQuery: query)
        return grounded
    }

    // MARK: - Grounding & Heuristics

    private func ground(_ criteria: FlightCriteria, originalQuery: String) -> FlightCriteria {
        var c = criteria

        func nonEmpty(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }

        if let o = nonEmpty(c.origin), let code = resolveAirportCode(from: o) { c.origin = code }
        if let d = nonEmpty(c.destination), let code = resolveAirportCode(from: d) { c.destination = code }

        // If both are empty or unresolved, attempt heuristic extraction from the raw query
        if (c.origin == nil || c.origin?.isEmpty == true) && (c.destination == nil || c.destination?.isEmpty == true) {
            let pair = heuristicExtract(from: originalQuery)
            if let oc = pair.origin { c.origin = oc }
            if let dc = pair.destination { c.destination = dc }
        }
        return c
    }

    private func resolveAirportCode(from input: String) -> String? {
        let dir = AirportDirectory.shared
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Direct 3-letter code
        if trimmed.count == 3 {
            let code = trimmed.uppercased()
            if dir.airport(forCode: code) != nil { return code }
        }

        // Code in parentheses, e.g., "San Francisco (SFO)"
        let ns = trimmed as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        if let re = try? NSRegularExpression(pattern: "\\(([A-Za-z]{3})\\)", options: []),
           let match = re.firstMatch(in: trimmed, options: [], range: fullRange) {
            let r = match.range(at: 1)
            if r.location != NSNotFound {
                let code = ns.substring(with: r).uppercased()
                if dir.airport(forCode: code) != nil { return code }
            }
        }

        // Common aliases → preferred primary airport codes
        let aliasMap: [String: String] = [
            "new york": "JFK", "nyc": "JFK",
            "london": "LHR",
            "paris": "CDG",
            "los angeles": "LAX",
            "san francisco": "SFO",
            "tokyo": "HND",
            "beijing": "PEK",
            "sao paulo": "GRU", "são paulo": "GRU",
            "toronto": "YYZ",
            "rio": "GIG", "rio de janeiro": "GIG",
            "santiago": "SCL",
            "vitoria": "VIX", "vitória": "VIX"
        ]
        let norm = normalize(trimmed)
        if let mapped = aliasMap[norm], dir.airport(forCode: mapped) != nil { return mapped }

        // Fallback: directory search across code, city, and name
        if let first = dir.searchAirports(matching: trimmed, limit: 1).first {
            return first.code
        }
        return nil
    }

    private func heuristicExtract(from query: String) -> (origin: String?, destination: String?) {
        let dir = AirportDirectory.shared
        let lower = query.lowercased()
        let ns = lower as NSString
        let range = NSRange(location: 0, length: ns.length)

        // Pattern: "from X to Y" or "X to Y"
        if let re = try? NSRegularExpression(pattern: "from\\s+([^,.;\\n]+?)\\s+(?:to|->|→)\\s+([^,.;\\n]+)", options: []),
           let m = re.firstMatch(in: lower, options: [], range: range) {
            let a = ns.substring(with: m.range(at: 1))
            let b = ns.substring(with: m.range(at: 2))
            let oc = resolveAirportCode(from: a)
            let dc = resolveAirportCode(from: b)
            return (oc, dc)
        }

        // Pattern: "to Y" (destination only), optionally "from X"
        if let reTo = try? NSRegularExpression(pattern: "\\bto\\s+([^,.;\\n]+)", options: []),
           let m = reTo.firstMatch(in: lower, options: [], range: range) {
            let b = ns.substring(with: m.range(at: 1))
            let dc = resolveAirportCode(from: b)
            var oc: String? = nil
            if let reFrom = try? NSRegularExpression(pattern: "\\bfrom\\s+([^,.;\\n]+)", options: []),
               let fm = reFrom.firstMatch(in: lower, options: [], range: range) {
                let a = ns.substring(with: fm.range(at: 1))
                oc = resolveAirportCode(from: a)
            }
            return (oc, dc)
        }

        // As a last resort, extract codes present in text
        if let reCodes = try? NSRegularExpression(pattern: "\\b([A-Za-z]{3})\\b", options: []) {
            let matches = reCodes.matches(in: query, options: [], range: NSRange(location: 0, length: (query as NSString).length))
            var codes: [String] = []
            for m in matches {
                let code = (query as NSString).substring(with: m.range(at: 1)).uppercased()
                if dir.airport(forCode: code) != nil { codes.append(code) }
            }
            if codes.count >= 2 { return (codes[0], codes[1]) }
            if codes.count == 1 { return (nil, codes[0]) }
        }
        return (nil, nil)
    }

    private func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Heuristic, local-only parser used when the on-device model is unavailable or returns empty.
    /// Attempts to extract origin/destination and resolve them to IATA codes using AirportDirectory.
    func fallbackParse(_ query: String) async -> FlightCriteria {
        // Start with empty criteria
        var c = FlightCriteria(origin: nil,
                               destination: nil,
                               minPrice: nil,
                               maxPrice: nil,
                               dateStart: nil,
                               dateEnd: nil,
                               airline: nil,
                               sortKey: nil,
                               sortOrder: nil)
        let pair = heuristicExtract(from: query)
        c.origin = pair.origin
        c.destination = pair.destination
        // Ground to directory (uppercased codes if found)
        let grounded = ground(c, originalQuery: query)
        return grounded
    }

    func logGuardrailFeedback(query: String?, errorDescription: String?) async {
        let q = (query?.isEmpty == false) ? (query ?? "<none>") : "<none>"
        let issues = errorDescription ?? "Guardrails triggered or parsing failed"
        let desired = "Extract origin/destination (IATA if possible), price range, date range (yyyy-MM-dd), optional airline, and sort preferences."
        print("[NaturalFlightSearch] Feedback: Query=\(q) | Issues=\(issues) | Desired=\(desired)")
    }
}

