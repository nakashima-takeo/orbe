import Foundation

/// ボードに置く部品。種類で指し、1 つのボードに同じ種類は 1 つまで（保証者は `SessionStore`）。外の表現（保存・制御 API）は
/// `{"kind": "intake"}` のオブジェクトで、部品に設定が付いても外の形を壊さない。
enum BoardPart: String, CaseIterable, Codable {
  /// タスクの自動追加の部品（見出し・依頼の欄・一覧・詳細）。
  case automation = "intake"

  private enum CodingKeys: String, CodingKey {
    case kind
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try c.decode(String.self, forKey: .kind)
    guard let part = BoardPart(rawValue: kind) else {
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: c, debugDescription: "unknown board part kind: \(kind)")
    }
    self = part
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(rawValue, forKey: .kind)
  }

  /// 制御 API の応答の 1 要素。
  var json: [String: Any] { ["kind": rawValue] }
}
