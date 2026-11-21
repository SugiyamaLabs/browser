import Foundation

/// A JSON value as it travels on the socket. Messages are flat objects (`[String: JSON]`).
public enum JSON: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSON])
  case object([String: JSON])

  public var string: String? { if case .string(let value) = self { value } else { nil } }
  public var double: Double? { if case .number(let value) = self { value } else { nil } }
  public var int: Int? { double.map { Int($0) } }
  public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
  public var array: [JSON]? { if case .array(let value) = self { value } else { nil } }
  public var object: [String: JSON]? { if case .object(let value) = self { value } else { nil } }

  init(any value: Any) {
    switch value {
    case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
    case let number as NSNumber: self = .number(number.doubleValue)
    case let string as String: self = .string(string)
    case let array as [Any]: self = .array(array.map(JSON.init(any:)))
    case let object as [String: Any]: self = .object(object.mapValues(JSON.init(any:)))
    default: self = .null
    }
  }

  var any: Any {
    switch self {
    case .null: NSNull()
    case .bool(let value): value
    // Whole numbers go out as integers ("width": 1000, not 1000.0).
    case .number(let value): value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value
    case .string(let value): value
    case .array(let value): value.map(\.any)
    case .object(let value): value.mapValues(\.any)
    }
  }

  /// One message: a JSON object on one line, ending in "\n".
  static func line(_ message: [String: JSON]) -> Data {
    var data = (try? JSONSerialization.data(withJSONObject: message.mapValues(\.any))) ?? Data("{}".utf8)
    data.append(0x0A)
    return data
  }

  static func parse(_ line: Data) -> [String: JSON]? {
    (try? JSONSerialization.jsonObject(with: line) as? [String: Any]).map { $0.mapValues(JSON.init(any:)) }
  }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(arrayLiteral elements: JSON...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
  public init(nilLiteral: ()) { self = .null }
}
