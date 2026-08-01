import AppKit
import SwiftUI

/// 補完 popup の facade（SearchBar に倣う）。`NSHostingView<CompletionList>` を `SurfaceView` に
/// 重ねる。focusable な要素を持たず端末がフォーカスを維持する。候補・選択 index を保持し、
/// accept のために直近 update の buffer/cursor も覚える（位置は SurfaceView が ime_point から置く）。
final class CompletionController: NSView {
  private let model = CompletionListModel()
  private let host: NSHostingView<CompletionList>

  /// 直近 update の編集状態（accept がこれと選択候補から適用結果を組む）。
  private(set) var buffer = ""
  private(set) var cursor = 0
  /// accept で置換する現在トークンの範囲（buffer 内 Character オフセット）。
  private(set) var replaceStart = 0
  private(set) var replaceEnd = 0

  override var acceptsFirstResponder: Bool { false }

  /// 背景透過ホルダー（WindowController 所有）を root へ渡し、透過時は端末上でも veil 濃度を揃える。
  init(translucency: ChromeTranslucency) {
    host = NSHostingView(rootView: CompletionList(model: model, translucency: translucency))
    super.init(frame: .zero)
    wantsLayer = true
    // SwiftUI 背景の alpha を端末面まで通す（透過時に素通し半透明が端末へ抜けるよう不透明ラスタを止める）。
    host.wantsLayer = true
    host.layer?.isOpaque = false
    host.translatesAutoresizingMaskIntoConstraints = false
    addSubview(host)
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: leadingAnchor),
      host.trailingAnchor.constraint(equalTo: trailingAnchor),
      host.topAnchor.constraint(equalTo: topAnchor),
      host.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  /// 候補と編集状態を差し替え、選択を先頭へ戻す。
  /// choices は engine の priority 順。ここで表示グループ順へ 1 度だけ並べ替え、
  /// 以降 selected/current/moveSelection はこの並びの上で回る（見出しはビューが種別境界で導出）。
  func update(
    buffer: String, cursor: Int, choices: [CompletionChoice], replaceStart: Int, replaceEnd: Int
  ) {
    // 現在トークンの入力済み部分（プレフィックス強調・学習の matchQuality 用）。cursor はトークン途中にも
    // なり得るため clamp。オフセットは scalar 単位（buffer/replaceStart/cursor すべて zsh/engine と揃えた scalar）。
    let chars = Array(buffer.unicodeScalars)
    let end = min(max(cursor, replaceStart), chars.count)
    let query =
      replaceStart < end ? String(String.UnicodeScalarView(chars[replaceStart..<end])) : ""
    // engine 元順を学習キー（頻度・recency）で安定再ソートしてから種別グループ化する。学習ゼロなら
    // 入力順を保持（現行と完全一致）。matchQuality が最上位キーなので完全一致優先は不可侵。
    let scopes = CompletionLearning.scopes(buffer: buffer, replaceStart: replaceStart)
    let ranked = CompletionLearning.shared.rank(
      choices, query: query, scopes: scopes, now: Date().timeIntervalSince1970)
    let ordered = CompletionList.displayOrdered(ranked)
    self.buffer = buffer
    self.cursor = cursor
    self.replaceStart = replaceStart
    self.replaceEnd = replaceEnd
    model.choices = ordered
    model.selected = 0
    model.query = query
  }

  /// 選択を循環移動する（↑/↓）。
  func moveSelection(_ delta: Int) {
    guard !model.choices.isEmpty else { return }
    model.selected = (model.selected + delta + model.choices.count) % model.choices.count
  }

  /// 選択を先頭/末尾候補へジャンプする（⌘↑=先頭・⌘↓=末尾。空は no-op）。
  func jumpSelection(_ d: Int) {
    guard !model.choices.isEmpty else { return }
    model.selected = d < 0 ? 0 : model.choices.count - 1
  }

  /// 現在選択中の候補。
  var current: CompletionChoice? {
    model.choices.indices.contains(model.selected) ? model.choices[model.selected] : nil
  }

  /// 選択候補の side card 用詳細（description が非空のときだけ）。汎用データのみ・git メタは持たない。
  /// スクロール状態は持たない（薄い行の scrollY は CompletionList が selected から派生する）。
  var selectedDetail: CompletionDetail? {
    guard let choice = current, !choice.description.isEmpty else { return nil }
    return CompletionDetail(
      name: choice.value, kind: CompletionKind.from(choice.type), description: choice.description)
  }

  /// 中身に合わせた推奨サイズ（SurfaceView が ime_point 基準で frame を置くのに使う）。
  var preferredSize: NSSize {
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }
}
