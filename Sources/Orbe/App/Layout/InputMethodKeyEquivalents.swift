import AppKit

/// 変換中の ⌘ 付きのキーを IME へ先に渡す口。窓の根（`ChromeHostingView`）が焦点の受け手に問い、変換中の入力の受け手
/// （端末の面・エディターの新しい面）が答える。根は受け手が何かを知らない。
///
/// 「IME が使ったか」は受け手が判定する——IME へ渡している間にキー割り当てのコマンド（`doCommand`）が届けば、IME は
/// 使わなかった（届いたコマンドは実行しない）。`handleEvent` の戻り値は、使わなかったキーでも真になるので使わない。
@MainActor
protocol InputMethodKeyEquivalents: AnyObject {
  /// 変換中なら ⌘ 付きのキーをまず IME へ渡し、IME が使ったなら true。変換中でなければ何もせず false。
  func offerKeyEquivalentToInputMethod(_ event: NSEvent) -> Bool
}
