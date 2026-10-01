import AppKit

/// 面の view のうち、エンジンの外から見える部分——変換中の ⌘ 付きのキーを IME へ先に渡す口。窓の根はエディターか
/// を知らず、焦点の受け手にこの口を問う（Orbe の窓のキーの層の口への準拠は、合成点が宣言する）。
public class TextSurfaceInputView: NSView {
  /// IME へキーを渡している最中か、渡している間にキー割り当てのコマンドが届いたか。
  private var offering = false
  private var commandArrived = false

  /// 変換中か（面の view が答える）。
  var composing: Bool { false }

  /// 変換中なら、⌘ 付きのキーをまず IME へ渡す。IME が使った（渡している間にキー割り当てのコマンドが届かなかった）なら
  /// true。届いたコマンドは実行しない——キーは呼び手の今の順で改めて流れ、キー割り当てのあるキーは keyDown の中で改めて
  /// コマンドとして届く。`handleEvent` の戻り値は、IME が使わなかったキーでも真になるので使わない。
  public func offerKeyEquivalentToInputMethod(_ event: NSEvent) -> Bool {
    guard composing, let context = inputContext else { return false }
    offering = true
    commandArrived = false
    defer { offering = false }
    _ = context.handleEvent(event)
    return !commandArrived
  }

  override public func doCommand(by selector: Selector) {
    guard !offering else {
      commandArrived = true
      return
    }
    super.doCommand(by: selector)
  }
}
