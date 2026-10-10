import Observation

/// ボードの状態。部品（今は自動追加 1 つ）のモデルと、ボードの中の焦点の宛先へ焦点を当て直す合図を持つ。
@Observable final class BoardModel {
  let intake: BoardIntakeModel
  /// 進むたびに、ボードの中の焦点の宛先へ焦点を当て直す。
  private(set) var focusToken = 0

  init(intake: BoardIntakeModel) {
    self.intake = intake
  }

  /// 器がホストへ first responder を渡す口。
  @ObservationIgnored var onFocus: () -> Void = {}

  /// 焦点をボードの中の宛先へ当て直す。何度呼んでも同じ結果になる。
  func focus() {
    onFocus()
    focusToken &+= 1
  }
}
