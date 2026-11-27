import Foundation
import CoreFoundation

/// Encodes Foundation-style JSON objects without calling
/// `JSONSerialization.data(withJSONObject:)`.
///
/// The Objective-C writer can raise an `NSException` while bridging Swift
/// collections. `NSException` bypasses Swift `do/catch`, so callers cannot
/// recover even when they use `try` or `try?`. Converting the supported JSON
/// graph to an `Encodable` value first keeps failures in Swift's error model.
public enum SafeJSONSerialization {
    public static func data(
        withJSONObject object: Any,
        options: JSONSerialization.WritingOptions = []
    ) throws -> Data {
        let value = try JSONValue(object)
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = []
        if options.contains(.prettyPrinted) { formatting.insert(.prettyPrinted) }
        if options.contains(.sortedKeys) { formatting.insert(.sortedKeys) }
        if options.contains(.withoutEscapingSlashes) { formatting.insert(.withoutEscapingSlashes) }
        encoder.outputFormatting = formatting
        return try encoder.encode(value)
    }

    public struct UnsupportedValueError: LocalizedError, Sendable {
        public let typeName: String

        public var errorDescription: String? {
            PMString("error.json.unsupportedType", typeName)
        }
    }

    private enum JSONValue: Encodable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case signedInteger(Int64)
        case unsignedInteger(UInt64)
        case number(Double)
        case bool(Bool)
        case null

        init(_ rawValue: Any) throws {
            let mirror = Mirror(reflecting: rawValue)
            if mirror.displayStyle == .optional {
                if let wrapped = mirror.children.first?.value {
                    self = try JSONValue(wrapped)
                } else {
                    self = .null
                }
                return
            }

            if rawValue is NSNull {
                self = .null
                return
            }

            // Swift numeric values bridge to NSNumber. Inspect the Core
            // Foundation type first because NSNumber(1) also casts to Bool.
            if let number = rawValue as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    self = .bool(number.boolValue)
                    return
                }
                let encoding = String(cString: number.objCType)
                switch encoding {
                case "C", "S", "I", "L", "Q":
                    self = .unsignedInteger(number.uint64Value)
                case "f", "d":
                    let value = number.doubleValue
                    guard value.isFinite else {
                        throw UnsupportedValueError(typeName: "non-finite number")
                    }
                    self = .number(value)
                default:
                    self = .signedInteger(number.int64Value)
                }
                return
            }

            if let string = rawValue as? String {
                self = .string(string)
                return
            }
            if let dictionary = rawValue as? [String: Any] {
                self = .object(try dictionary.mapValues(JSONValue.init))
                return
            }
            if let array = rawValue as? [Any] {
                self = .array(try array.map(JSONValue.init))
                return
            }
            if let dictionary = rawValue as? NSDictionary {
                var result: [String: JSONValue] = [:]
                for (key, value) in dictionary {
                    guard let key = key as? String else {
                        throw UnsupportedValueError(typeName: "non-string dictionary key")
                    }
                    result[key] = try JSONValue(value)
                }
                self = .object(result)
                return
            }
            if let array = rawValue as? NSArray {
                self = .array(try array.map(JSONValue.init))
                return
            }

            throw UnsupportedValueError(typeName: String(reflecting: type(of: rawValue)))
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .object(let values):
                var container = encoder.container(keyedBy: JSONKey.self)
                for (key, value) in values {
                    try container.encode(value, forKey: JSONKey(key))
                }
            case .array(let values):
                var container = encoder.unkeyedContainer()
                for value in values { try container.encode(value) }
            case .string(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .signedInteger(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .unsignedInteger(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .number(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .bool(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .null:
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            }
        }
    }

    private struct JSONKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            return nil
        }
    }
}
