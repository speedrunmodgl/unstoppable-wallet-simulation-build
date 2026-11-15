import SwiftUI

struct TradePreview {
    let walletID: UUID
    let asset: String
    let buy: Bool
    let amount: Decimal
    let quote: Quote
    let entry: Entry
    let orderID: UUID
}

@main
struct SimulationApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}

@MainActor
final class SimulationModel: ObservableObject {
    @Published var ledger = Ledger()
    @Published var quotes: [String: Quote] = [:]
    @Published var message: String?
    @Published var loading = false
    private var store: LedgerStore?
    let assets = ["bitcoin", "ethereum", "solana", "xrp", "dogecoin"]

    init() {
        do {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            store = try LedgerStore(url: dir.appendingPathComponent("simulation.sqlite"))
            ledger = try store!.load()
        } catch { message = "Unable to open local simulation storage: \(error.localizedDescription)" }
    }
    func create(starting: String) {
        guard let amount = Decimal(string: starting, locale: Locale(identifier: "en_US_POSIX")) else { message = "Invalid starting amount"; return }
        update { try $0.createWallet(name: "My Wallet", startingCash: amount) }
    }
    func update<T>(_ operation: (inout Ledger) throws -> T) {
        do {
            guard let store else { throw StorageError.sqlite("Storage is unavailable") }
            _ = try store.update(operation)
            ledger = try store.load()
        } catch { message = error.localizedDescription }
    }
    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        var failures = 0
        for asset in assets {
            do { quotes[asset] = try await MarketService().quote(asset: asset) }
            catch { failures += 1 }
        }
        if failures > 0 { message = "Some prices could not be refreshed. Existing quotes may be stale." }
    }
    func preview(asset: String, buy: Bool, amount: Decimal, id: UUID, quote: Quote) throws -> TradePreview {
        guard let wallet = ledger.wallets.first else { throw LedgerError.unknownWallet }
        var trial = ledger
        try trial.trade(walletID: wallet.id, buy: buy, quote: quote, amount: amount, id: id)
        guard let entry = trial.entries.last, entry.id == id else { throw LedgerError.arithmetic }
        return TradePreview(walletID: wallet.id, asset: asset, buy: buy, amount: amount, quote: quote, entry: entry, orderID: id)
    }
    func prepare(asset: String, buy: Bool, amount: String, id: UUID) async -> TradePreview? {
        guard let n = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else { message = "Enter a valid amount using a decimal point."; return nil }
        do {
            let quote = try await MarketService().quote(asset: asset)
            quotes[asset] = quote
            return try preview(asset: asset, buy: buy, amount: n, id: id, quote: quote)
        } catch { message = error.localizedDescription; return nil }
    }
    func execute(_ preview: TradePreview) async -> (Bool, TradePreview?) {
        do {
            let expired = Date().timeIntervalSince(preview.quote.publishedAt) > 120 || Date().timeIntervalSince(preview.quote.retrievedAt) > 120
            let latest = try await MarketService().quote(asset: preview.asset)
            quotes[preview.asset] = latest
            let revised = try self.preview(asset: preview.asset, buy: preview.buy, amount: preview.amount, id: preview.orderID, quote: latest)
            guard revised.walletID == preview.walletID else { throw LedgerError.unknownWallet }
            if expired || latest.price != preview.quote.price {
                message = "The quote changed or expired. Review the updated amounts and confirm again."
                return (false, revised)
            }
            guard let store else { throw StorageError.sqlite("Storage is unavailable") }
            try store.update { try $0.trade(walletID: preview.walletID, buy: preview.buy, quote: latest, amount: preview.amount, id: preview.orderID) }
            ledger = try store.load()
            return (true, nil)
        } catch { message = error.localizedDescription; return (false, nil) }
    }
}

struct RootView: View {
    @StateObject private var model = SimulationModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var starting = "1000"
    @State private var selectedAsset: String?
    @State private var isBuy = true
    @State private var amount = ""
    @State private var orderID = UUID()
    @State private var tradePreview: TradePreview?
    @State private var processing = false

    private func format(_ value: Decimal?) -> String {
        guard let value else { return "Unavailable" }
        return (value as NSDecimalNumber).stringValue
    }
    var body: some View {
        Group {
            if model.ledger.wallets.isEmpty {
                NavigationStack {
                    Form {
                        Section("Unofficial personal simulator") {
                            Text("Funds are simulated, have no monetary value and cannot be withdrawn. No blockchain transactions are made.")
                            TextField("Starting virtual EUR", text: $starting).keyboardType(.decimalPad)
                            Button("Create wallet") { model.create(starting: starting) }
                        }
                    }.navigationTitle("Unstoppable Wallet")
                }
            } else {
                TabView {
                    NavigationStack {
                        List {
                            if let wallet = model.ledger.wallets.first {
                                let prices = model.quotes.mapValues(\.price)
                                let valuation = try? model.ledger.valuation(walletID: wallet.id, prices: prices)
                                Section {
                                    Text("€\(format(valuation?.total))").font(.largeTitle.bold())
                                    Text("Virtual cash €\(format(wallet.cash))").foregroundStyle(.secondary)
                                    Text("Unrealized €\(format(valuation?.unrealized)) · Realized €\(format(valuation?.realized))").font(.caption)
                                }
                                Section("Assets") {
                                    ForEach(model.assets, id: \.self) { asset in
                                        Button {
                                            selectedAsset = asset; isBuy = true; amount = ""; orderID = UUID(); tradePreview = nil
                                        } label: {
                                            HStack {
                                                VStack(alignment: .leading) {
                                                    Text(asset.capitalized)
                                                    Text("\(format(wallet.positions[asset]?.quantity ?? 0)) units").font(.caption).foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                                if let quote = model.quotes[asset] {
                                                    VStack(alignment: .trailing) {
                                                        Text("€\(format(quote.price))")
                                                        Text(quote.publishedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                                                    }
                                                } else { Text("Unavailable").foregroundStyle(.secondary) }
                                            }
                                        }
                                    }
                                }
                            }
                        }.navigationTitle("My Wallet").refreshable { await model.refresh() }
                    }.tabItem { Label("Wallet", systemImage: "wallet.pass") }
                    NavigationStack {
                        List(model.ledger.entries.reversed()) { entry in
                            VStack(alignment: .leading) {
                                Text("\(entry.kind) \(entry.asset ?? "")")
                                Text("€\(format(entry.value)) · \(entry.date.formatted())").font(.caption).foregroundStyle(.secondary)
                            }
                        }.navigationTitle("Activity")
                    }.tabItem { Label("Activity", systemImage: "clock") }
                    NavigationStack {
                        Form {
                            Section("About") {
                                Text("Unofficial personal build. Funds, trades and profits are simulated and have no monetary value.")
                                Text("Prices: Coinbase Exchange public ticker. Quotes can be delayed.")
                                Text("Original Unstoppable Wallet © Horizontal Systems. MIT license.")
                            }
                        }.navigationTitle("Settings")
                    }.tabItem { Label("Settings", systemImage: "gearshape") }
                }.tint(.orange)
            }
        }
        .task {
            while !Task.isCancelled {
                if scenePhase == .active && !model.ledger.wallets.isEmpty { await model.refresh() }
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { break }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.refresh() } } }
        .sheet(isPresented: Binding(get: { selectedAsset != nil }, set: { if !$0 { selectedAsset = nil } })) {
            NavigationStack {
                Form {
                    if let asset = selectedAsset {
                        Picker("Action", selection: $isBuy) { Text("Buy").tag(true); Text("Sell").tag(false) }.pickerStyle(.segmented).disabled(processing)
                        TextField(isBuy ? "Virtual EUR to spend" : "Units to sell", text: $amount).keyboardType(.decimalPad).disabled(processing)
                        Text("These funds and transactions are simulated and cannot be withdrawn.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let preview = tradePreview {
                            Section("Review simulated trade") {
                                LabeledContent("Quote", value: "€\(format(preview.quote.price))")
                                LabeledContent("Quantity", value: format(preview.entry.quantity))
                                LabeledContent("Fee", value: "€\(format(preview.entry.fee))")
                                LabeledContent("Simulated slippage", value: "0%")
                                LabeledContent(preview.buy ? "Total cost" : "Proceeds", value: "€\(format(preview.buy ? preview.amount : preview.entry.value))")
                                Text("Coinbase last trade: \(preview.quote.publishedAt.formatted()). A price change or expired quote requires another review. No real transaction is made.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                Button("Confirm simulated trade") {
                                    processing = true
                                    Task {
                                        let (success, revised) = await model.execute(preview)
                                        processing = false
                                        tradePreview = revised
                                        if success { selectedAsset = nil }
                                    }
                                }.disabled(processing)
                            }
                        } else {
                            Button("Review simulated trade") {
                                processing = true
                                Task {
                                    tradePreview = await model.prepare(asset: asset, buy: isBuy, amount: amount, id: orderID)
                                    processing = false
                                }
                            }.disabled(processing || amount.isEmpty)
                        }
                    }
                }.navigationTitle(selectedAsset?.capitalized ?? "Trade")
                    .toolbar { Button("Close") { selectedAsset = nil }.disabled(processing) }
                    .onChange(of: amount) { _, _ in tradePreview = nil }
                    .onChange(of: isBuy) { _, _ in tradePreview = nil }
            }
        }
        .alert("Simulation", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}
