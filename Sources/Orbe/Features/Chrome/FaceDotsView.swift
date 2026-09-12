import SwiftUI

extension Chrome {
  /// タブ行右端の位置ドットの予約幅（ドット 14 ＋ gap 4 ＋ ドット 14 ＋ 右余白 4）。
  static let faceDotsWidth: CGFloat =
    FaceDotsView.longWidth + FaceDotsView.gap + FaceDotsView.longWidth + FaceDotsView.trailing
}

/// タブ行右端の位置ドット（エディター・端末の 2 点）。焦点＝キー色の長丸、見えていて非焦点＝半透明の
/// 長丸、隠れている＝薄い小丸。右端の端末ドットを錨に、幅と色を `Theme.Motion.faceDot` で遷移する。
struct FaceDotsView: View {
  let dots: FaceGeometry.FaceDots
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let longWidth: CGFloat = 14
  static let shortWidth: CGFloat = 6
  static let height: CGFloat = 6
  static let gap: CGFloat = 4
  static let trailing: CGFloat = 4

  var body: some View {
    HStack(spacing: Self.gap) {
      dot(dots.editor, color: Color.theme.faceEditor)
      dot(dots.terminal, color: Color.theme.faceTerminal)
    }
    .frame(width: Chrome.faceDotsWidth - Self.trailing, alignment: .trailing)
    .padding(.trailing, Self.trailing)
    .animation(reduceMotion ? nil : .easeInOut(duration: Theme.Motion.faceDot), value: dots)
  }

  private func dot(_ state: FaceGeometry.DotState, color: Color) -> some View {
    RoundedRectangle(cornerRadius: Self.height / 2)
      .fill(color.opacity(state == .focus ? 1 : state == .on ? 0.5 : 0.3))
      .frame(width: state == .off ? Self.shortWidth : Self.longWidth, height: Self.height)
  }
}
