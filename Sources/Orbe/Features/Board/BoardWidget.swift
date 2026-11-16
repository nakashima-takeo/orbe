import Foundation

/// ボードに置くウィジェット。種類で指し、1 つのボードに同じ種類は 1 つまで（保証者は `SessionStore`）。外の表現（保存・制御 API）は
/// `{"kind": "automation"}` のオブジェクトで、ウィジェットに設定が付いても外の形を壊さない。
enum BoardWidget: String, CaseIterable, Codable {
  /// 自動化のウィジェット（依頼の欄・一覧・右の欄）。
  case automation

  private enum CodingKeys: String, CodingKey {
    case kind
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try c.decode(String.self, forKey: .kind)
    guard let widget = BoardWidget(rawValue: kind) else {
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: c, debugDescription: "unknown board widget kind: \(kind)")
    }
    self = widget
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(rawValue, forKey: .kind)
  }

  /// 制御 API の応答の 1 要素。
  var json: [String: Any] { ["kind": rawValue] }
}
