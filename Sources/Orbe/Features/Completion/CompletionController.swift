import AppKit
import SwiftUI

/// 補完 popup の facade（SearchBar に倣う）。`NSHostingView<CompletionList>` を `SurfaceView` に
/// 重ねる。focusable な要素を持たず端末がフォーカスを維持する。候補・選択 index を保持し、
/// accept のために直近 update の buffer と置換範囲も覚える（位置は SurfaceView が ime_point から置く）。
final class CompletionController: NSView {
  private let model = CompletionListModel()
  private let host: NSHostingView<CompletionList>

  /// 直近 update の編集状態（accept がこれと選択候補から適用結果を組む）。
  private(set) var buffer = ""
  /// accept で置換する現在トークンの範囲（buffer 内 Character オフセット）。
  private(set) var replaceStart = 0
  private(set) var replaceEnd = 0
  /// 直近 update で engine の commandPath から導出した二層スコープ。accept 経路（record）は
  /// これを読む——rank と record が同一の engine 事実を共有し、非対称が構造的に起きない。
  private(set) var scopes = CompletionLearning.LearningScopes(staticScope: "", dynamicScope: "")

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

  /// 候補と編集状態を差し替え、選択を先頭へ戻す。engine の結果（候補と解析事実）をそのまま受け、
  /// 置換範囲だけ host が導いた値を添える。
  /// `result.choices` は engine の priority 順。ここで表示グループ順へ 1 度だけ並べ替え、
  /// 以降 selected/current/moveSelection はこの並びの上で回る（見出しはビューが種別境界で導出）。
  /// `result.query` は候補値と直接比較できる正規化済みトークンで、プレフィックス強調と matchQuality
  /// の両方がこれを基準にする（パス候補では候補値も basename なので basename 部分が光る）。
  func update(
    buffer: String, result: CompletionResult, replaceStart: Int, replaceEnd: Int
  ) {
    // engine 元順を学習キー（頻度・recency）で安定再ソートしてから種別グループ化する。学習ゼロなら
    // 入力順を保持（現行と完全一致）。matchQuality が最上位キーなので完全一致優先は不可侵。
    let scopes = CompletionLearning.scopes(commandPath: result.commandPath)
    let ranked = CompletionLearning.shared.rank(
      result.choices, query: result.query, scopes: scopes, now: Date().timeIntervalSince1970)
    let ordered = CompletionList.displayOrdered(ranked)
    self.buffer = buffer
    self.replaceStart = replaceStart
    self.replaceEnd = replaceEnd
    self.scopes = scopes
    model.choices = ordered
    model.selected = 0
    model.query = result.query
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
