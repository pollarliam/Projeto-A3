// DestinationSummaryAgent.swift
// Foundation Models–powered destination popover summaries

import Foundation
import FoundationModels

@Generable(description: "Compact travel overview for a destination to show in a popover. Keep friendly, factual, and helpful. No safety warnings or apologies.")
struct DestinationSummary: Sendable {
    @Guide(description: "A concise multi-paragraph summary (<= 15 lines when displayed) about the destination covering vibe, top attractions, food, neighborhoods, and why it's worth visiting. Avoid markdown lists; write as prose. Prefer 3–6 sentences. Mention the city name explicitly.")
    var text: String
}

actor DestinationSummaryAgent {
    static let shared = DestinationSummaryAgent()

    private let session: LanguageModelSession

    private struct ResolvedAirport: Codable {
        let code: String
        let city: String?
        let latitude: Double?
        let longitude: Double?
    }

    private struct ResolvedContext: Codable {
        let origin: ResolvedAirport
        let destination: ResolvedAirport
    }

    init() {
        let instructions = """
        You are a travel writer for a flight app. You will be given an IATA destination code and a Resolved section that contains the mapped city and coordinates from the app's local airport directory.

        Follow these rules strictly:
        - Always use the provided resolved city names. Do not infer or guess cities from codes.
        - If Resolved.destination.city is missing, refer to "the destination" generically and do not name a city.
        - Do not contradict the Resolved information.
        - Tone: warm, energetic, helpful; write 3–6 sentences.
        - Include 2–4 highlights (neighborhoods, culture, landmarks, food) woven into prose.
        - Avoid safety disclaimers, warnings, or apologies. Never apologize.
        - Keep it self-contained and neutral; no links.
        - Target length so it fits under 15 lines in a narrow card.
        """
        self.session = LanguageModelSession(instructions: instructions)
    }

    func summarize(destinationCode: String, originCode: String, airline: String, depdate: String, durationMinutes: Int) async throws -> String {
        // Resolve codes using the local airport directory to avoid inference mistakes
        let dir = AirportDirectory.shared
        let dest = dir.airport(forCode: destinationCode)
        let orig = dir.airport(forCode: originCode)

        let resolved = ResolvedContext(
            origin: ResolvedAirport(
                code: originCode.uppercased(),
                city: orig?.city,
                latitude: orig?.latitude,
                longitude: orig?.longitude
            ),
            destination: ResolvedAirport(
                code: destinationCode.uppercased(),
                city: dest?.city,
                latitude: dest?.latitude,
                longitude: dest?.longitude
            )
        )

        // Encode resolved context as pretty-printed JSON for the model to consume
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let resolvedJSON: String
        if let data = try? encoder.encode(resolved), let s = String(data: data, encoding: .utf8) {
            resolvedJSON = s
        } else {
            resolvedJSON = "{\n  \"origin\": { \"code\": \"\(originCode.uppercased())\" },\n  \"destination\": { \"code\": \"\(destinationCode.uppercased())\" }\n}"
        }

        let prompt = """
        Summarize the destination for a traveler considering this itinerary:

        Itinerary:
        - Origin code: \(originCode.uppercased())
        - Destination code: \(destinationCode.uppercased())
        - Airline: \(airline)
        - Departure: \(depdate)
        - Duration: \(durationMinutes) minutes

        Resolved (from local airport directory; authoritative — do not infer beyond this):
        \(resolvedJSON)

        Write a concise overview suitable for a small popover. Do not include headings. Use the resolved destination city name if present; otherwise, refer to "the destination" generically without guessing a name.
        """

        let response = try await session.respond(to: prompt, generating: DestinationSummary.self)
        return response.content.text
    }
}
