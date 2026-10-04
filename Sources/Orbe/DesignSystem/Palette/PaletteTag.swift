import SwiftUI

/// 行末の accent の札（「現在」・件数など）。
struct PaletteTag: View {
  let text: String

  var body: some View {
    Text(text)
      .font(Font.theme.sectionLabel)
      .foregroundStyle(Color.theme.accentPrimary)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 7)
      .padding(.vertical, 1)
      .background(Capsule().fill(Color.theme.tintAccent))
  }
}
