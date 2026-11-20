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

  /// 取得の出力 1 行の関門でもある。id は空でなく、link は書けば http か https の URL、time は書けば ISO 8601。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    guard !id.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "empty id")
    }
    link = try c.decodeIfPresent(String.self, forKey: .link)
    if let link, !AutomationRowFields.isWebLink(link) {
      throw DecodingError.dataCorruptedError(
        forKey: .link, in: c, debugDescription: "not an http(s) URL")
    }
    body = try c.decode(String.self, forKey: .body)
    time = try c.decodeIfPresent(String.self, forKey: .time).map { raw in
      guard let time = SessionEvent.parseISO8601(raw) else {
        throw DecodingError.dataCorruptedError(
          forKey: .time, in: c, debugDescription: "not ISO 8601")
      }
      return time
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encodeIfPresent(link, forKey: .link)
    try c.encode(body, forKey: .body)
    try c.encodeIfPresent(time.map(SessionEvent.iso8601), forKey: .time)
  }
}

extension AutomationRowFields {
  /// 行（JSON オブジェクト 1 行）の欄を読む。http か https の URL の `link` が無ければ nil（候補にできない）。文字列でない
  /// `body`・ISO 8601 でない `time` は持たない。
  init?(row text: String) {
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      let link = object["link"] as? String, Self.isWebLink(link)
    else { return nil }
    self.init(
      link: link, body: object["body"] as? String,
      time: (object["time"] as? String).flatMap(SessionEvent.parseISO8601))
  }

  static func isWebLink(_ text: String) -> Bool {
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https", url.host?.isEmpty == false
    else { return false }
    return true
  }
}
