import Foundation
import OrbeSessionLog

/// 値は文字列で読む——知らない通知先を、型の名前を出さずに言うため。
extension AutomationNotify: Codable {
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    guard let notify = Self(rawValue: try c.decode(String.self)) else {
      throw DecodingError.dataCorruptedError(
        in: c, debugDescription: "pass menuBar or notificationCenter")
    }
    self = notify
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(rawValue)
  }
}

extension AutomationItem: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, link, body, time
  }

  /// 取得の出力 1 行の関門でもある。id は空でなく、link は http か https の URL、time は ISO 8601。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    guard !id.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "empty id")
    }
    link = try c.decode(String.self, forKey: .link)
    guard Self.isWebLink(link) else {
      throw DecodingError.dataCorruptedError(
        forKey: .link, in: c, debugDescription: "not an http(s) URL")
    }
    body = try c.decode(String.self, forKey: .body)
    let rawTime = try c.decode(String.self, forKey: .time)
    guard let time = SessionEvent.parseISO8601(rawTime) else {
      throw DecodingError.dataCorruptedError(
        forKey: .time, in: c, debugDescription: "not ISO 8601")
    }
    self.time = time
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(link, forKey: .link)
    try c.encode(body, forKey: .body)
    try c.encode(SessionEvent.iso8601(time), forKey: .time)
  }

  private static func isWebLink(_ text: String) -> Bool {
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https", url.host?.isEmpty == false
    else { return false }
    return true
  }
}
