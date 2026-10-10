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

  /// 器がホストへ first responder を渡す口。
  @ObservationIgnored var onFocus: () -> Void = {}

  /// 焦点をボードの中（部品の最後に居た場所）へ当て直す。何度呼んでも同じ結果になる。
  func focus() {
    onFocus()
    intake.refocus()
  }
}
