import Foundation

public enum LedgerError: Error, LocalizedError {
    case invalidAmount, insufficientCash, insufficientHoldings, duplicate, unknownWallet, invalidQuote, staleQuote, arithmetic
    public var errorDescription: String? {
        switch self {
        case .invalidAmount: return "Enter a valid positive amount."
        case .insufficientCash: return "Insufficient virtual cash."
        case .insufficientHoldings: return "Insufficient virtual holdings."
        case .duplicate: return "This operation was already executed."
        case .unknownWallet: return "Wallet not found."
        case .invalidQuote: return "Invalid market quote."
        case .staleQuote: return "Market quote is stale or has no verified publication time."
        case .arithmetic: return "Amount exceeds supported decimal precision."
        }
    }
}

// Overflow and underflow are rejected. Foundation Decimal rounds loss of precision down.
enum Math {
    static func calculate(_ a: Decimal, _ b: Decimal, _ op: (UnsafeMutablePointer<Decimal>, UnsafePointer<Decimal>, UnsafePointer<Decimal>, Decimal.RoundingMode) -> Decimal.CalculationError) throws -> Decimal {
        var lhs = a, rhs = b, result = Decimal()
        let error = op(&result, &lhs, &rhs, .down)
        guard error == .noError || error == .lossOfPrecision, !result.isNaN else { throw LedgerError.arithmetic }
        return result
    }
    static func add(_ a: Decimal, _ b: Decimal) throws -> Decimal { try calculate(a, b, NSDecimalAdd) }
    static func sub(_ a: Decimal, _ b: Decimal) throws -> Decimal { try calculate(a, b, NSDecimalSubtract) }
    static func mul(_ a: Decimal, _ b: Decimal) throws -> Decimal { try calculate(a, b, NSDecimalMultiply) }
    static func div(_ a: Decimal, _ b: Decimal) throws -> Decimal {
        guard b != 0 else { throw LedgerError.arithmetic }
        return try calculate(a, b, NSDecimalDivide)
    }
}

public struct Position: Codable, Equatable {
    public var quantity: Decimal = 0
    public var cost: Decimal = 0
    public var realized: Decimal = 0
}
public struct Wallet: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var cash: Decimal
    public var contributions: Decimal
    public var positions: [String: Position]
}
public struct Entry: Codable, Identifiable, Equatable {
    public let id: UUID
    public let walletID: UUID
    public let kind: String
    public let asset: String?
    public let quantity: Decimal?
    public let price: Decimal?
    public let value: Decimal
    public let fee: Decimal
    public let realized: Decimal
    public let source: String?
    public let date: Date
}
public struct Quote: Equatable {
    public let asset: String
    public let price: Decimal
    public let publishedAt: Date
    public let retrievedAt: Date
    public let source: String
    public init(asset: String, price: Decimal, publishedAt: Date, retrievedAt: Date, source: String) {
        self.asset = asset; self.price = price; self.publishedAt = publishedAt; self.retrievedAt = retrievedAt; self.source = source
    }
}
public struct Valuation {
    public let total: Decimal?
    public let unrealized: Decimal?
    public let realized: Decimal
}
public struct Ledger: Codable {
    public private(set) var wallets: [Wallet] = []
    public private(set) var entries: [Entry] = []
    public init() {}

    @discardableResult public mutating func createWallet(name: String, startingCash: Decimal, id: UUID = UUID(), now: Date = Date()) throws -> UUID {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !startingCash.isNaN, startingCash >= 0 else { throw LedgerError.invalidAmount }
        guard !wallets.contains(where: { $0.id == id }) else { throw LedgerError.duplicate }
        wallets.append(Wallet(id: id, name: name, cash: startingCash, contributions: startingCash, positions: [:]))
        entries.append(Entry(id: UUID(), walletID: id, kind: "Contribution", asset: nil, quantity: nil, price: nil, value: startingCash, fee: 0, realized: 0, source: nil, date: now))
        return id
    }
    public mutating func cashChange(walletID: UUID, amount: Decimal, deposit: Bool, id: UUID = UUID(), now: Date = Date()) throws {
        guard !amount.isNaN, amount > 0 else { throw LedgerError.invalidAmount }
        guard !entries.contains(where: { $0.id == id }) else { throw LedgerError.duplicate }
        guard let i = wallets.firstIndex(where: { $0.id == walletID }) else { throw LedgerError.unknownWallet }
        var wallet = wallets[i]
        if !deposit && wallet.cash < amount { throw LedgerError.insufficientCash }
        wallet.cash = try deposit ? Math.add(wallet.cash, amount) : Math.sub(wallet.cash, amount)
        wallet.contributions = try deposit ? Math.add(wallet.contributions, amount) : Math.sub(wallet.contributions, amount)
        wallets[i] = wallet
        entries.append(Entry(id: id, walletID: walletID, kind: deposit ? "Contribution" : "Cash removal", asset: nil, quantity: nil, price: nil, value: amount, fee: 0, realized: 0, source: nil, date: now))
    }
    // A buy spends a total EUR amount including fee; a sell amount is cryptocurrency units.
    public mutating func trade(walletID: UUID, buy: Bool, quote: Quote, amount: Decimal, feeRate: Decimal = 0, id: UUID, now: Date = Date()) throws {
        guard !amount.isNaN, amount > 0, !feeRate.isNaN, feeRate >= 0, feeRate < 1 else { throw LedgerError.invalidAmount }
        guard !entries.contains(where: { $0.id == id }) else { throw LedgerError.duplicate }
        guard !quote.price.isNaN, quote.price > 0, !quote.asset.isEmpty else { throw LedgerError.invalidQuote }
        let age = now.timeIntervalSince(quote.publishedAt), retrievalAge = now.timeIntervalSince(quote.retrievedAt)
        guard age >= -5, age <= 120, retrievalAge >= -5, retrievalAge <= 120 else { throw LedgerError.staleQuote }
        guard let i = wallets.firstIndex(where: { $0.id == walletID }) else { throw LedgerError.unknownWallet }
        var wallet = wallets[i], position = wallet.positions[quote.asset] ?? Position()
        let quantity: Decimal, value: Decimal, fee: Decimal, realized: Decimal
        if buy {
            guard wallet.cash >= amount else { throw LedgerError.insufficientCash }
            value = try Math.div(amount, Math.add(1, feeRate))
            fee = try Math.sub(amount, value)
            quantity = try Math.div(value, quote.price)
            guard quantity > 0 else { throw LedgerError.arithmetic }
            wallet.cash = try Math.sub(wallet.cash, amount)
            position.quantity = try Math.add(position.quantity, quantity)
            position.cost = try Math.add(position.cost, amount)
            realized = 0
        } else {
            quantity = amount
            guard position.quantity >= quantity else { throw LedgerError.insufficientHoldings }
            value = try Math.mul(quantity, quote.price)
            fee = try Math.mul(value, feeRate)
            let cost = try quantity == position.quantity ? position.cost : Math.div(Math.mul(position.cost, quantity), position.quantity)
            realized = try Math.sub(Math.sub(value, fee), cost)
            wallet.cash = try Math.add(wallet.cash, Math.sub(value, fee))
            position.quantity = try Math.sub(position.quantity, quantity)
            position.cost = try Math.sub(position.cost, cost)
            position.realized = try Math.add(position.realized, realized)
        }
        wallet.positions[quote.asset] = position
        wallets[i] = wallet
        entries.append(Entry(id: id, walletID: walletID, kind: buy ? "Buy" : "Sell", asset: quote.asset, quantity: quantity, price: quote.price, value: value, fee: fee, realized: realized, source: quote.source, date: now))
    }
    public func valuation(walletID: UUID, prices: [String: Decimal]) throws -> Valuation {
        guard let wallet = wallets.first(where: { $0.id == walletID }) else { throw LedgerError.unknownWallet }
        var total = wallet.cash, unrealized: Decimal = 0, realized: Decimal = 0, complete = true
        for (asset, position) in wallet.positions {
            realized = try Math.add(realized, position.realized)
            guard position.quantity > 0 else { continue }
            guard let price = prices[asset], !price.isNaN, price >= 0 else { complete = false; continue }
            let value = try Math.mul(position.quantity, price)
            total = try Math.add(total, value)
            unrealized = try Math.add(unrealized, Math.sub(value, position.cost))
        }
        return Valuation(total: complete ? total : nil, unrealized: complete ? unrealized : nil, realized: realized)
    }
}
