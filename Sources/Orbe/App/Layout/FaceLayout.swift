import Foundation

/// タブの中の面。端末とエディターの 2 つで、焦点はどちらか一方にある。
enum Face: String, Codable, Equatable {
  case terminal
  case editor
}

/// タブ 1 枚の面の配置——エディター幅の割合と焦点の面。永続表現と同型。
///
/// 正規形: `editorRatio == 0` なら焦点は端末、`1` ならエディター。焦点の面は常に見えている面で、
/// 書き手（背のドラッグ・永続の decode・pane の焦点通知）は `normalized` を通してから状態に置く。
struct FaceLayout: Equatable, Codable {
  var editorRatio: Double
  var focus: Face

  /// 既定: 端末だけ。
  static let terminalOnly = FaceLayout(editorRatio: 0, focus: .terminal)

  /// 割合を 0…1 に収め、全面の側へ焦点を寄せた正規形。
  var normalized: FaceLayout {
    let ratio = editorRatio.isFinite ? min(max(editorRatio, 0), 1) : 0
    if ratio <= 0 { return FaceLayout(editorRatio: 0, focus: .terminal) }
    if ratio >= 1 { return FaceLayout(editorRatio: 1, focus: .editor) }
    return FaceLayout(editorRatio: ratio, focus: focus)
  }
}
