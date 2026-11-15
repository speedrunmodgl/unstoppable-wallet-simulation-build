import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public Coinbase Exchange ticker: price strings and exchange trade time, not retrieval time.
/// Only explicitly mapped EUR pairs can be executed. No authenticated API or signing.
public struct MarketService {
    public static let products: [String: String] = [
        "bitcoin": "BTC-EUR", "ethereum": "ETH-EUR", "solana": "SOL-EUR",
        "xrp": "XRP-EUR", "dogecoin": "DOGE-EUR"
    ]
    public init() {}
    public func quote(asset: String) async throws -> Quote {
        guard let product = Self.products[asset], let url = URL(string: "https://api.exchange.coinbase.com/products/\(product)/ticker") else { throw LedgerError.invalidQuote }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw LedgerError.invalidQuote }
        struct Ticker: Decodable { let price: String; let time: String }
        let ticker = try JSONDecoder().decode(Ticker.self, from: data)
        let locale = Locale(identifier: "en_US_POSIX")
        guard let price = Decimal(string: ticker.price, locale: locale), !price.isNaN, price > 0 else { throw LedgerError.invalidQuote }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: ticker.time) ?? ISO8601DateFormatter().date(from: ticker.time)
        guard let publishedAt = date else { throw LedgerError.invalidQuote }
        return Quote(asset: asset, price: price, publishedAt: publishedAt, retrievedAt: Date(), source: "Coinbase Exchange \(product)")
    }
}
