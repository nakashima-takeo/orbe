import AppKit
import SwiftUI

extension View {
  /// ↵ の確定。押し続けたキーリピートでは発火しない。`onSubmit` は field editor の改行から来るので、リピートが
  /// どの経路で届いても（入力欄の `onKeyPress` を通らないことがある——押し始めを別の面が受け、押している途中で
  /// 焦点がこの入力欄へ移ると、SwiftUI は押し始めを見ていないキーのリピートを `onKeyPress` へ渡さない）、
  /// 確定の入口で捨てる。判定は届いたキーそのもの（`NSApp.currentEvent`）で行う。
  func onSubmitIgnoringKeyRepeat(_ action: @escaping () -> Void) -> some View {
    onSubmit {
      guard NSApp.currentEvent.map({ $0.type == .keyDown && $0.isARepeat }) != true else { return }
      action()
    }
  }
}
