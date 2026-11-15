import Foundation
import SQLite3

public enum StorageError: Error { case sqlite(String), unsupportedVersion }

/// One versioned ledger snapshot per database. BEGIN IMMEDIATE serializes writers; a
/// failed validation, encode, or commit rolls the entire operation back.
public final class LedgerStore {
    private var db: OpaquePointer?
    private let lock = NSLock()
    public init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StorageError.sqlite("Unable to open simulation database")
        }
        do {
            try execute("PRAGMA busy_timeout=5000")
            try execute("CREATE TABLE IF NOT EXISTS ledger (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, payload BLOB NOT NULL)")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StorageError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }
    private func loadUnlocked() throws -> Ledger {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT version,payload FROM ledger WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw StorageError.sqlite("Read prepare failed") }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return Ledger() }
        guard status == SQLITE_ROW else { throw StorageError.sqlite("Read failed") }
        guard sqlite3_column_int(statement, 0) == 1 else { throw StorageError.unsupportedVersion }
        guard let bytes = sqlite3_column_blob(statement, 1) else { throw StorageError.sqlite("Missing ledger") }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
        return try JSONDecoder().decode(Ledger.self, from: data)
    }
    public func load() throws -> Ledger {
        lock.lock(); defer { lock.unlock() }
        return try loadUnlocked()
    }
    @discardableResult public func update<T>(_ operation: (inout Ledger) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            var ledger = try loadUnlocked()
            let result = try operation(&ledger)
            let payload = try JSONEncoder().encode(ledger)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO ledger(id,version,payload) VALUES(1,1,?)", -1, &statement, nil) == SQLITE_OK else { throw StorageError.sqlite("Write prepare failed") }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let bindStatus = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
            let status = bindStatus == SQLITE_OK ? sqlite3_step(statement) : bindStatus
            sqlite3_finalize(statement)
            guard status == SQLITE_DONE else { throw StorageError.sqlite("Write failed") }
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
