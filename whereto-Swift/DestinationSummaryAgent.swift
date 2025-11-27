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

    init() {
        let instructions = """
        You are a travel writer for a flight app. Given an IATA destination code and optional context (origin, airline, date, duration), write a concise, upbeat overview of the destination city for a popover above a map pin.
        - Use the IATA code to resolve the city (e.g., GRU -> São Paulo, JFK -> New York, CDG -> Paris, HND -> Tokyo, LHR -> London, PEK -> Beijing, SFO -> San Francisco).
        - Tone: warm, energetic, helpful; 3–6 sentences.
        - Include 2–4 highlights (neighborhoods, culture, landmarks, food) woven into prose.
        - Avoid safety disclaimers, warnings, or policy talk. Never apologize.
        - Keep it self-contained and neutral; no links. Avoid hallucinating facts beyond common knowledge.
        - Target length so it fits under 15 lines in a narrow card.
        """
        self.session = LanguageModelSession(instructions: instructions)
    }

    func summarize(destinationCode: String, originCode: String, airline: String, depdate: String, durationMinutes: Int) async throws -> String {
        let prompt = """
        Summarize the destination for a traveler considering this itinerary:
        - Origin: \(originCode)
        - Destination: \(destinationCode)
        - Airline: \(airline)
        - Departure: \(depdate)
        - Duration: \(durationMinutes) minutes
        Provide a concise overview suitable for a small popover. Do not include headings.
        """
        let response = try await session.respond(to: prompt, generating: DestinationSummary.self)
        return response.text
    }
}
