// DestinationSummaryAgent.swift
// Foundation Models–powered destination popover summaries

import Foundation
import FoundationModels

@Generable(description: "Um resumo conciso em múltiplos parágrafos (<= 15 linhas quando exibido) sobre o destino cobrindo clima/ambiente, principais atrações, gastronomia, bairros e por que vale a pena visitar. Evite listas em markdown; escreva em prosa. Prefira 3–6 frases. Mencione o nome da cidade explicitamente.")
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
        Você é um redator de viagens para um app de passagens aéreas. Você receberá um código IATA de destino e uma seção "Resolved" que contém a cidade e coordenadas mapeadas a partir do diretório local de aeroportos do app.

        Siga estas regras estritamente:
        - Sempre use os nomes de cidade resolvidos fornecidos. Não infira ou adivinhe cidades a partir de códigos.
        - Se Resolved.destination.city estiver ausente, refira-se genericamente a "o destino" e não nomeie uma cidade.
        - Não contradiga as informações de Resolved.
        - Tom: caloroso, simpático, prestativo; escreva 3–6 frases.
        - Inclua 2–4 destaques (cultura, pontos turísticos, gastronomia) entrelaçados em prosa.
        - Evite avisos de segurança, advertências ou desculpas. Nunca peça desculpas.
        - Mantenha o texto autocontido e neutro; sem links.
        - Tamanho alvo para caber em até 15 linhas em um cartão estreito.
        - Escreva em português do Brasil.
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
        Resuma o destino para um viajante considerando este itinerário:

        Itinerário:
        - Código de destino: \(destinationCode.uppercased())
        
        Resolved (do diretório local de aeroportos; é autoritativo — não infira além disso):
        \(resolvedJSON)

        Escreva uma visão geral concisa do destino, adequada para um pequeno popover. Não inclua títulos. Use o nome da cidade de destino resolvido se presente; caso contrário, refira-se genericamente a "o destino" sem tentar adivinhar um nome. 
        """

        let response = try await session.respond(to: prompt, generating: DestinationSummary.self)
        return response.content.text
    }
}

