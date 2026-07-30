import Foundation

/// Barcode → label nutrition, via Open Food Facts (the open, license-free product database —
/// no API key, no account, nothing about the athlete in the request but the barcode itself).
/// All judgment lives in the pure `BarcodeFood` engine; this file is only the network hop.
@MainActor
final class OpenFoodFactsService {

    enum Outcome: Equatable {
        case found(BarcodeFood.ScannedProduct)
        /// The database genuinely doesn't know this code — the athlete should describe it instead.
        case notFound
        /// Network trouble — worth a retry, unlike `notFound`.
        case unavailable
    }

    /// Session-lifetime cache: re-scanning the same wrapper mid-snack costs nothing and works
    /// offline. Bounded implicitly by how many distinct products one person scans in a session.
    private var cache: [String: BarcodeFood.ScannedProduct] = [:]

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        session = URLSession(configuration: config)
    }

    func lookup(barcode: String) async -> Outcome {
        guard BarcodeFood.isLikelyFoodBarcode(barcode) else { return .notFound }
        if let hit = cache[barcode] { return .found(hit) }

        // Slim the payload to the fields the decoder reads — OFF products can be 100 KB+ raw.
        var components = URLComponents(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json")!
        components.queryItems = [.init(name: "fields",
                                       value: "product_name,brands,serving_size,nutriments")]
        var request = URLRequest(url: components.url!)
        // OFF asks integrators to identify themselves; this is the whole courtesy.
        request.setValue("momentum-ios/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            // OFF answers 404 with a status-0 JSON body for unknown codes; both spellings mean
            // "we don't know it", not "try again".
            if http.statusCode == 404 { return .notFound }
            guard (200..<300).contains(http.statusCode) else { return .unavailable }
            guard let product = BarcodeFood.product(fromOFF: data, barcode: barcode) else {
                return .notFound
            }
            cache[barcode] = product
            return .found(product)
        } catch {
            return .unavailable
        }
    }
}
