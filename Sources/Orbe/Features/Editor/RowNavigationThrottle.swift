import Foundation

/// 行の列でキーで選択を動かしたときの開きの間引き（検索結果とソース管理の列が共有する）。1 回の開きはファイルを読むので、
/// リピートごとに開くと選択の移動が遅れる。窓（75ms。VS Code の検索結果と同じ）の外のリピートでない押下はすぐ開いて窓を
/// 始め、窓の中の押下は待って窓を延ばす。押している間（キーリピートを含む）は開かず、キーを離してから窓が閉じたとき、
/// その時点の選択を開く——押し続けても開くのは押し始めの 1 件と離した後の最後の 1 件だけ。押し続けを時間ではなく離した
/// ことで見るのは、リピートの間隔（macOS の既定は約 83〜90ms）も初期遅延も窓より長く、時間だけでは押している間に窓が
/// 切れるため。離したことが届かないときは、次のリピートでない押下で離したものとして扱う。
///
/// 待っている開きは、すぐ開く出口と、人の注意が列から移ったこと（列から焦点が外れた・列の外を押した・パネルが隠れた）で
/// 捨てる（`drop`）——後から前の選択が開いて、すぐ開いたものや人が押したものを入れ替えない。
@MainActor
final class RowNavigationThrottle {
  static let window: TimeInterval = 0.075

  /// 窓の時計（テストは手で進める）。
  let delay = EditorDelay()
  /// 今の選択を開く（窓の外の押下ですぐ・窓が閉じたとき）。
  var open: () -> Void = {}
  private var isWindowOpen = false
  /// キーで動かした後、まだ離していない（押し続けている）。
  private var isKeyHeld = false
  /// 窓の中で動いた（窓が閉じたら、その時点の選択を開く）。
  private var hasPending = false

  /// キーで選択を動かした。窓の外のリピートでない押下ならすぐ開いて窓を始め、そうでなければ待つ。
  func didNavigate(isRepeat: Bool) {
    if !isRepeat { isKeyHeld = false }
    if isRepeat || isKeyHeld || isWindowOpen {
      hasPending = true
    } else {
      fire()
    }
    isKeyHeld = true
    if !isRepeat { startWindow() }
  }

  /// 列のキーを離した。待ちがあれば、ここから窓が閉じたときに開く。
  func keyDidRelease() {
    guard isKeyHeld else { return }
    isKeyHeld = false
    if hasPending { startWindow() }
  }

  /// 待っている開きを捨て、押しているキーを離したものとして扱う。
  func drop() {
    hasPending = false
    isKeyHeld = false
  }

  private func startWindow() {
    isWindowOpen = true
    delay.run(after: Self.window) { [weak self] in
      guard let self else { return }
      isWindowOpen = false
      if hasPending, !isKeyHeld { fire() }
    }
  }

  private func fire() {
    hasPending = false
    open()
  }
}
