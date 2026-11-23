import Foundation
import GRDB
import SQLite3

/// 写入热路径上的一个列值。GRDB 的 `StatementArguments` 每个值都要装箱、转换、按 C 字符串绑定,
/// 一行五十多列时这部分比 SQLite 本身还慢;这里直接 `sqlite3_bind_*`,文本带长度。
/// 文本必须已经去掉 NUL(`LibraryCatalogDerivedFields.columnText`),否则读回时会被 GRDB 截断。
enum CatalogValue: Equatable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func optionalText(_ value: String?) -> CatalogValue { value.map(CatalogValue.text) ?? .null }
    static func optionalInt(_ value: Int?) -> CatalogValue { value.map { .int(Int64($0)) } ?? .null }
    static func optionalReal(_ value: Double?) -> CatalogValue { value.map(CatalogValue.real) ?? .null }

    /// 库里读回的值,用来判断一列有没有变。
    init(_ value: DatabaseValue) {
        switch value.storage {
        case .null: self = .null
        case .int64(let number): self = .int(number)
        case .double(let number): self = .real(number)
        case .string(let text): self = .text(text)
        case .blob(let data): self = .blob(data)
        }
    }
}

enum CatalogStatement {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let empty: [CChar] = [0]

    /// 从第 `offset` 个参数起绑定(1 起数)。
    static func bind(_ values: some Collection<CatalogValue>, to statement: Statement, startingAt offset: Int32 = 1) {
        let handle = statement.sqliteStatement
        var index = offset
        for value in values {
            switch value {
            case .null:
                sqlite3_bind_null(handle, index)
            case .int(let number):
                sqlite3_bind_int64(handle, index, number)
            case .real(let number):
                sqlite3_bind_double(handle, index, number)
            case .text(let text):
                bindText(text, handle: handle, index: index)
            case .blob(let data):
                if data.isEmpty {
                    sqlite3_bind_zeroblob(handle, index, 0)
                } else {
                    data.withUnsafeBytes { buffer in
                        _ = sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), transient)
                    }
                }
            }
            index += 1
        }
    }

    static func bind(_ value: CatalogValue, to statement: Statement, at index: Int32) {
        bind(CollectionOfOne(value), to: statement, startingAt: index)
    }

    private static func bindText(_ text: String, handle: OpaquePointer?, index: Int32) {
        var text = text
        text.withUTF8 { buffer in
            if buffer.isEmpty {
                empty.withUnsafeBufferPointer { _ = sqlite3_bind_text(handle, index, $0.baseAddress, 0, transient) }
            } else {
                buffer.withMemoryRebound(to: CChar.self) {
                    _ = sqlite3_bind_text(handle, index, $0.baseAddress, Int32($0.count), transient)
                }
            }
        }
    }

    /// 执行一条已绑定的写语句(不返回行)。
    static func execute(_ statement: Statement, in db: Database) throws {
        let handle = statement.sqliteStatement
        let code = sqlite3_step(handle)
        sqlite3_reset(handle)
        guard code == SQLITE_DONE else {
            throw DatabaseError(
                resultCode: ResultCode(rawValue: code),
                message: String(cString: sqlite3_errmsg(db.sqliteConnection)),
                sql: statement.sql
            )
        }
    }
}

/// 一次性分配的裸内存:每个下标只由一个工作片写一次,`concurrentPerform` 返回后才读
/// (并发写数组属性会触发独占访问检查)。
final class ParallelSlots<Value>: @unchecked Sendable {
    static var slicesPerCore: Int { 4 }
    private let slots: UnsafeMutableBufferPointer<Value?>

    init(count: Int) {
        slots = .allocate(capacity: max(1, count))
        slots.initialize(repeating: nil)
    }

    deinit {
        slots.deinitialize()
        slots.deallocate()
    }

    func set(_ index: Int, _ value: Value) { slots[index] = value }
    func take(_ count: Int) -> [Value] { (0..<count).map { slots[$0]! } }

    /// 把 `0..<count` 分成连续片并行算;片内顺序执行(`body` 可以在片内复用缓存)。
    /// 片数是核数的几倍:导入时写线程占着一个核、系统还有别的进程,只切核数片的话最后几片要排队,
    /// 墙钟时间近乎翻倍;切细了由 GCD 均衡。每个下标的结果只取决于它自己,与怎么切无关。
    static func map(count: Int, minimumSlice: Int = 64, _ body: (Range<Int>, ParallelSlots<Value>) -> Void) -> [Value] {
        let output = ParallelSlots<Value>(count: count)
        guard count > 0 else { return [] }
        let slices = min(max(1, ProcessInfo.processInfo.activeProcessorCount * slicesPerCore),
                         max(1, count / max(1, minimumSlice)))
        let size = (count + slices - 1) / slices
        DispatchQueue.concurrentPerform(iterations: slices) { slice in
            let start = slice * size
            let end = min(count, start + size)
            guard start < end else { return }
            autoreleasepool { body(start..<end, output) }
        }
        return output.take(count)
    }
}
