import Foundation

/// 1 行 1 件の JSON の読み取り結果。形は使い手が `Decodable` 型で決め、読めた行だけを受ける。読めない行は行番号と理由を残す。
/// コマンドの出力にも agent の最終応答にも同じ読み方を当てる。
struct JSONLines<Item: Decodable> {
  struct Rejection: Equatable {
    /// 1 始まりの行番号（空行も数える）。
    let line: Int
    let reason: Reason
  }

  enum Reason: Error, Equatable {
    case notJSON
    case notObject
    case missingKey(String)
    case nullValue(String)
    case typeMismatch(String)
    case invalidValue(String)
  }

  /// 読めた行。
  struct Accepted {
    /// 1 始まりの行番号（空行も数える）。
    let line: Int
    /// 前後の空白を除いた原文。
    let text: String
    let item: Item
  }

  let accepted: [Accepted]
  let rejected: [Rejection]

  var items: [Item] { accepted.map(\.item) }

  init(_ text: String) {
    // CRLF は 1 つの Character なので、LF と並べて区切りに数える。
    var lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
    if lines.last?.isEmpty == true { lines.removeLast() }
    var accepted: [Accepted] = []
    var rejected: [Rejection] = []
    for (index, line) in lines.enumerated() {
      let number = index + 1
      let body = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { continue }
      switch Self.decode(body) {
      case .success(let item): accepted.append(Accepted(line: number, text: body, item: item))
      case .failure(let reason): rejected.append(Rejection(line: number, reason: reason))
      }
    }
    self.accepted = accepted
    self.rejected = rejected
  }

  /// 1 行を読む。
  static func decode(_ line: String) -> Result<Item, Reason> {
    let data = Data(line.utf8)
    guard let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    else { return .failure(.notJSON) }
    guard value is [String: Any] else { return .failure(.notObject) }
    do {
      return .success(try JSONDecoder().decode(Item.self, from: data))
    } catch DecodingError.keyNotFound(let key, let context) {
      return .failure(.missingKey(path(context.codingPath + [key])))
    } catch DecodingError.valueNotFound(_, let context) {
      return .failure(.nullValue(path(context.codingPath)))
    } catch DecodingError.typeMismatch(_, let context) {
      return .failure(.typeMismatch(path(context.codingPath)))
    } catch DecodingError.dataCorrupted(let context) {
      return .failure(.invalidValue(path(context.codingPath)))
    } catch {
      return .failure(.invalidValue(""))
    }
  }

  /// `items[0].name` の形。
  private static func path(_ keys: [CodingKey]) -> String {
    keys.reduce(into: "") { path, key in
      if let index = key.intValue {
        path += "[\(index)]"
      } else {
        path += path.isEmpty ? key.stringValue : "." + key.stringValue
      }
    }
  }
}

extension JSONLines.Reason {
  /// 回の記録に残す理由。
  var text: String {
    switch self {
    case .notJSON: "not JSON"
    case .notObject: "not a JSON object"
    case .missingKey(let key): "missing \(key)"
    case .nullValue(let key): "\(key) is null"
    case .typeMismatch(let key): "\(key) has the wrong type"
    case .invalidValue(let key): key.isEmpty ? "invalid value" : "invalid \(key)"
    }
  }
}
