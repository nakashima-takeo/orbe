import Observation

/// ボードの状態。部品（今は自動追加 1 つ）のモデルと、フッターの右の断りの 1 枠を持ち、部品へ焦点を当て直す口になる。
@Observable final class BoardModel {
  let intake: BoardIntakeModel
  /// 部品が置き、次の操作で部品が消す。
  private(set) var refusal: L10nKey?

  init(intake: BoardIntakeModel) {
    self.intake = intake
    intake.onRefusal = { [weak self] in self?.refusal = $0 }
  }

  /// 器が、焦点が外にあればホストへ first responder を渡し、渡したか（焦点が外から入ったか）を返す口。
  @ObservationIgnored var onFocus: () -> Bool = { true }

  /// 焦点をボードの中へ当てる。外から入るなら部品は欄から始まり、中にあるなら選んでいる場所へ当て直す——ボードを選ぶ・パレットを
  /// 閉じる・workspace を戻るのは入り直しで、裏のタブが閉じたのは中の続きだから。何度呼んでも同じ結果になる。
  func focus() {
    if onFocus() { intake.enter() } else { intake.refocus() }
  }

  /// 地のクリック。ボードの中の操作なので、外から入ったときも選んでいる場所へ当て直す。
  func refocus() {
    _ = onFocus()
    intake.refocus()
  }
}
