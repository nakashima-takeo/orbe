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
    /// 出力の上限で切れた最後の行。
    case truncated
  }

  let items: [Item]
  let rejected: [Rejection]

  /// `truncated` は出力が上限で切られたか。改行で終わっていない最後の行を、切れた行として捨てる。
  init(_ text: String, truncated: Bool = false, decoder: JSONDecoder = JSONDecoder()) {
    // CRLF は 1 つの Character なので、LF と並べて区切りに数える。
    var lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
    let cutLine = truncated && lines.last?.isEmpty == false ? lines.count : nil
    if lines.last?.isEmpty == true { lines.removeLast() }
    var items: [Item] = []
    var rejected: [Rejection] = []
    for (index, line) in lines.enumerated() {
      let number = index + 1
      let body = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { continue }
      if number == cutLine {
        rejected.append(Rejection(line: number, reason: .truncated))
        continue
      }
      switch Self.decode(Data(body.utf8), decoder: decoder) {
      case .success(let item): items.append(item)
      case .failure(let reason): rejected.append(Rejection(line: number, reason: reason))
      }
    }
    self.items = items
    self.rejected = rejected
  }

  private static func decode(_ data: Data, decoder: JSONDecoder) -> Result<Item, Reason> {
    guard let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    else { return .failure(.notJSON) }
    guard value is [String: Any] else { return .failure(.notObject) }
    do {
      return .success(try decoder.decode(Item.self, from: data))
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
