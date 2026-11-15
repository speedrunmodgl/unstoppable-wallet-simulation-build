import XCTest
@testable import SimulationCore

final class LedgerTests: XCTestCase {
    func testBitcoinScenarioPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        func quote(_ price: Decimal) -> Quote { Quote(asset: "bitcoin", price: price, publishedAt: now, retrievedAt: now, source: "test") }
        var store: LedgerStore? = try LedgerStore(url: url)
        let wallet = try store!.update { try $0.createWallet(name: "Test", startingCash: 1000) }
        try store!.update { try $0.trade(walletID: wallet, buy: true, quote: quote(100000), amount: 1000, id: UUID(), now: now) }
        var ledger = try store!.load()
        XCTAssertEqual(ledger.wallets[0].cash, 0)
        XCTAssertEqual(ledger.wallets[0].positions["bitcoin"]?.quantity, Decimal(string: "0.01"))
        XCTAssertEqual(try ledger.valuation(walletID: wallet, prices: ["bitcoin": 90000]).total, 900)
        XCTAssertEqual(try ledger.valuation(walletID: wallet, prices: ["bitcoin": 90000]).unrealized, -100)
        XCTAssertEqual(try ledger.valuation(walletID: wallet, prices: ["bitcoin": 120000]).total, 1200)
        XCTAssertEqual(try ledger.valuation(walletID: wallet, prices: ["bitcoin": 120000]).unrealized, 200)
        try store!.update { try $0.trade(walletID: wallet, buy: false, quote: quote(120000), amount: Decimal(string: "0.01")!, id: UUID(), now: now) }
        store = nil
        store = try LedgerStore(url: url)
        ledger = try store!.load()
        XCTAssertEqual(ledger.wallets[0].cash, 1200)
        XCTAssertEqual(ledger.wallets[0].positions["bitcoin"]?.quantity, 0)
        XCTAssertEqual(ledger.wallets[0].positions["bitcoin"]?.realized, 200)
        XCTAssertEqual(ledger.entries.count, 3)
    }
    func testFailuresDoNotMutateAndDuplicatesAreRejected() throws {
        var ledger = Ledger()
        let wallet = try ledger.createWallet(name: "Test", startingCash: 1000)
        let now = Date(), id = UUID()
        let quote = Quote(asset: "solana", price: 100, publishedAt: now, retrievedAt: now, source: "test")
        XCTAssertThrowsError(try ledger.trade(walletID: wallet, buy: true, quote: quote, amount: 1001, id: id, now: now))
        try ledger.trade(walletID: wallet, buy: true, quote: quote, amount: 100, id: id, now: now)
        XCTAssertThrowsError(try ledger.trade(walletID: wallet, buy: true, quote: quote, amount: 1, id: id, now: now))
        XCTAssertThrowsError(try ledger.trade(walletID: wallet, buy: false, quote: quote, amount: 2, id: UUID(), now: now))
        XCTAssertEqual(ledger.wallets[0].cash, 900)
        XCTAssertNil(try ledger.valuation(walletID: wallet, prices: [:]).total)
        let stale = Quote(asset: "bitcoin", price: 1, publishedAt: now.addingTimeInterval(-121), retrievedAt: now, source: "test")
        XCTAssertThrowsError(try ledger.trade(walletID: wallet, buy: true, quote: stale, amount: 1, id: UUID(), now: now))
    }
    func testWeightedCostAndContributions() throws {
        var ledger = Ledger(); let wallet = try ledger.createWallet(name: "Test", startingCash: 1000); let now = Date()
        func quote(_ p: Decimal) -> Quote { Quote(asset: "bitcoin", price: p, publishedAt: now, retrievedAt: now, source: "test") }
        try ledger.trade(walletID: wallet, buy: true, quote: quote(100), amount: 200, id: UUID(), now: now)
        try ledger.trade(walletID: wallet, buy: true, quote: quote(200), amount: 200, id: UUID(), now: now)
        try ledger.trade(walletID: wallet, buy: false, quote: quote(300), amount: Decimal(string: "1.5")!, id: UUID(), now: now)
        try ledger.cashChange(walletID: wallet, amount: 500, deposit: true)
        XCTAssertEqual(ledger.wallets[0].positions["bitcoin"]?.cost, 200)
        XCTAssertEqual(ledger.wallets[0].positions["bitcoin"]?.realized, 250)
        XCTAssertEqual(try ledger.valuation(walletID: wallet, prices: ["bitcoin": 300]).unrealized, 250)
    }
    func testFeesMultipleWalletsAndRollback() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try LedgerStore(url: url)
        let first = try store.update { try $0.createWallet(name: "First", startingCash: 1000) }
        let second = try store.update { try $0.createWallet(name: "Second", startingCash: 50) }
        let now = Date()
        let quote = Quote(asset: "solana", price: 100, publishedAt: now, retrievedAt: now, source: "test")
        try store.update { try $0.trade(walletID: first, buy: true, quote: quote, amount: 101, feeRate: Decimal(string: "0.01")!, id: UUID(), now: now) }
        let result = try store.load()
        XCTAssertEqual(result.wallets.first(where: { $0.id == first })?.positions["solana"]?.quantity, 1)
        XCTAssertEqual(result.wallets.first(where: { $0.id == first })?.positions["solana"]?.cost, 101)
        XCTAssertEqual(result.wallets.first(where: { $0.id == second })?.cash, 50)
        XCTAssertThrowsError(try store.update { (ledger: inout Ledger) throws -> Void in
            try ledger.cashChange(walletID: second, amount: 10, deposit: true)
            throw LedgerError.invalidAmount
        })
        XCTAssertEqual(try store.load().wallets.first(where: { $0.id == second })?.cash, 50)
    }
}
