import Observation

/// ボードの状態。描く部品の並び（前面の workspace のボードの投影）・部品（今は自動化 1 つ）のモデル・フッターの右の断りの
/// 1 枠を持ち、部品へ焦点を当て直す口になる。
@Observable final class BoardModel {
  let automation: BoardAutomationModel
  /// 描く部品の並び。作った後に書くのは `show(_:)` だけ。
  private(set) var parts: [BoardPart]
  /// 部品が置き、次の操作で部品が消す。
  private(set) var refusal: L10nKey?

  init(automation: BoardAutomationModel, parts: [BoardPart]) {
    self.automation = automation
    self.parts = parts
    automation.onRefusal = { [weak self] in self?.refusal = $0 }
  }

  /// 器の first responder が器か配下にあるか。
  @ObservationIgnored var focusIsInside: () -> Bool = { false }
  /// 器がホストへ first responder を渡す。
  @ObservationIgnored var takeFocus: () -> Void = {}

  /// 描く並びを替える。焦点がボードの中にあったときだけ当て直す——置かれた部品があれば外から入るのと同じく欄から（空のボードを
  /// 見ていた人が続けて打てる）、無ければホストに残す（窓のキーを効かせ続ける）。外にある焦点は奪わない。
  func show(_ parts: [BoardPart]) {
    guard parts != self.parts else { return }
    // 部品が消えると焦点の宛先も画面から消え、焦点が窓へ落ちるので、替える前に読む。
    let inside = focusIsInside()
    self.parts = parts
    if !parts.contains(.automation) { refusal = nil }
    guard inside else { return }
    takeFocus()
    if parts.contains(.automation) { automation.enter() }
  }

  /// 焦点をボードの中へ当てる。外から入るなら部品は欄から始まり、中にあるなら選んでいる場所へ当て直す——ボードを選ぶ・パレットを
  /// 閉じる・workspace を戻るのは入り直しで、裏のタブが閉じたのは中の続きだから。部品が無ければホストに置くだけ。何度呼んでも
  /// 同じ結果になる。
  func focus() {
    let entering = enter()
    guard parts.contains(.automation) else { return }
    if entering { automation.enter() } else { automation.refocus() }
  }

  /// 自動化の部品へ、その自動化を開くよう頼む（ピル・通知センターのクリックから。焦点を当てた後に呼ぶ）。部品が無ければ
  /// ボードが開いているだけ。
  func open(automation id: Int) {
    guard parts.contains(.automation) else { return }
    automation.open(id)
  }

  /// 自動化の部品で、その自動化の行を選んでいるか。
  func selects(automation id: Int) -> Bool {
    parts.contains(.automation) && automation.list.selectedID == .automation(id)
  }

  /// 部品の焦点の合図を受け取り、当てる場所を返す（ビューが合図の進みと、部品が現れたときに呼ぶ）。焦点がボードの外にあれば
  /// 合図は捨てる——ボードを一瞬選んで同じ turn にタブへ移ると、合図が届く頃には焦点が端末にあるため。`show(_:)` と同じく、
  /// 外にある焦点は奪わない。
  func takeFocusRequest() -> BoardAutomationModel.Place? {
    let place = automation.takeFocusRequest()
    return focusIsInside() ? place : nil
  }

  /// 地のクリック。ボードの中の操作なので、外から入ったときも選んでいる場所へ当て直す。
  func refocus() {
    _ = enter()
    if parts.contains(.automation) { automation.refocus() }
  }

  /// 焦点が外にあればホストへ渡し、渡したか（焦点が外から入ったか）を返す。中にあるときに渡し直すと、依頼の欄の入力を終わらせて、
  /// 当て直す先の焦点を取りこぼす。
  private func enter() -> Bool {
    guard !focusIsInside() else { return false }
    takeFocus()
    return true
  }
}
