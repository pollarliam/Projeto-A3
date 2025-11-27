import Foundation
import FoundationModels

@Generable
struct FlightCriteria: Sendable, Codable {
  @Guide("The origin airport IATA code or city code to depart from. Prefer IATA codes if present. Common city codes: London (LHR), San Francisco (SFO), Los Angeles (LAX), Paris (CDG), New York (JFK).")
  var origin: String?

  @Guide("The destination airport IATA code or city code to arrive at. Prefer IATA codes if present. Common city codes: London (LHR), San Francisco (SFO), Los Angeles (LAX), Paris (CDG), New York (JFK).")
  var destination: String?

  @Guide("The minimum price filter, numeric value representing the minimum price in the flight search.")
  var minPrice: Double?

  @Guide("The maximum price filter, numeric value representing the maximum price in the flight search.")
  var maxPrice: Double?

  @Guide("The start date of the flight search range in ISO 8601 format yyyy-MM-dd.")
  var dateStart: String?

  @Guide("The end date of the flight search range in ISO 8601 format yyyy-MM-dd.")
  var dateEnd: String?

  @Guide("Preferred airline for the flight search.")
  var airline: String?

  @Guide("Sort key to order the results by. Allowed values: price, date, duration.")
  var sortKey: String?

  @Guide("Sort order for the results. Allowed values: ascending, descending.")
  var sortOrder: String?
}

actor NaturalFlightSearch {
  static let shared = NaturalFlightSearch()
  
  private let session: LanguageModelSession

  init() {
    let instructions = """
You are an assistant that extracts structured flight search criteria from a user's natural language query.

Instructions:
- Extract only the following fields when present: origin, destination, minPrice, maxPrice, dateStart, dateEnd, airline, sortKey, sortOrder.
- For origin and destination, prefer IATA airport codes if present. If the user provides a city name without code, use the following common IATA codes:
  London -> LHR
  San Francisco -> SFO
  Los Angeles -> LAX
  Paris -> CDG
  New York -> JFK
- Dates must be in ISO 8601 format: yyyy-MM-dd.
- Prices must be numeric values only.
- sortKey must be one of: price, date, duration.
- sortOrder must be one of: ascending, descending.
- Return only the extracted fields as JSON content matching the FlightCriteria structure.
"""
    self.session = LanguageModelSession(
      model: .gpt4,
      instructions: instructions
    )
  }

  public func parse(_ query: String) async throws -> FlightCriteria {
    let response = try await session.respond(to: query, generating: FlightCriteria.self)
    return response.content
  }
}
