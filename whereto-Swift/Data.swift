import Foundation

/// We coerce all fields to String due to unquoted numeric values in JSON.
struct Flight: Identifiable, Codable {
    let id: String
    let airline: String
    let origin: String
    let destination: String
    let departureTime: String
    let duration: String
    let priceEco: String
    let priceExec: String
    let pricePremium: String
    
    private enum CodingKeys: String, CodingKey {
        case id = "ID_Voo"
        case airline = "Companhia"
        case origin = "Origem"
        case destination = "Destino"
        case departureTime = "Data_Partida"
        case duration = "Duracao_Horas"
        case priceEco = "Preco_Economica"
        case priceExec = "Preco_Executiva"
        case pricePremium = "Preco_Premium"
    }
    
    private static func decodeString(_ key: CodingKeys, from container: KeyedDecodingContainer<CodingKeys>) throws -> String {
        if let s = try? container.decode(String.self, forKey: key) { return s }
        if let i = try? container.decode(Int.self, forKey: key) { return String(i) }
        if let d = try? container.decode(Double.self, forKey: key) { return String(d) }
        if let b = try? container.decode(Bool.self, forKey: key) { return String(b) }
        // If value is null or missing, return empty string
        return ""
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try Self.decodeString(.id, from: c)
        self.airline = try Self.decodeString(.airline, from: c)
        self.origin = try Self.decodeString(.origin, from: c)
        self.destination = try Self.decodeString(.destination, from: c)
        self.departureTime = try Self.decodeString(.departureTime, from: c)
        self.duration = try Self.decodeString(.duration, from: c)
        self.priceEco = try Self.decodeString(.priceEco, from: c)
        self.priceExec = try Self.decodeString(.priceExec, from: c)
        self.pricePremium = try Self.decodeString(.pricePremium, from: c)
    }
}

//Loader
enum DataLoadError: Error { 
    case fileNotFound(String)
    case decodeFailed(Error)
}

func loadFlightsFromBundle() throws -> [Flight] {
    let resourceName = "Dataset1"
    let resourceExtension = "json"
    
    guard let url = Bundle.main.url(forResource: resourceName, withExtension: resourceExtension) else {
        print("[Data] Failed to locate resource named \"\(resourceName).\(resourceExtension)\" in bundle: \(Bundle.main.bundlePath)")
        throw DataLoadError.fileNotFound("\(resourceName).\(resourceExtension)")
    }
    print("[Data] Found resource at: \(url.path)")
    
    do {
        let flightData = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let flights = try decoder.decode([Flight].self, from: flightData)
        print("[Data] Successfully decoded \(flights.count) flights from \(resourceName).\(resourceExtension)")
        return flights
    } catch {
        print("[Data] Decode failed with error: \(error)")
        throw DataLoadError.decodeFailed(error)
    }
}

@discardableResult
func verifyDatasetPresence() -> Bool {
    let resourceName = "Dataset1"
    let resourceExtension = "json"
    if let url = Bundle.main.url(forResource: resourceName, withExtension: resourceExtension) {
        print("[Data] ✅ Dataset found: \(url.path)")
        return true
    } else {
        print("[Data] ❌ Dataset not found in bundle. Expected \"\(resourceName).\(resourceExtension)\". Bundle path: \(Bundle.main.bundlePath)")
        return false
    }
}

