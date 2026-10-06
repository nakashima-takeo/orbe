import SwiftUI

/// フッター右端のキーヒント 1 つ（キーは textPrimary・ラベルは親の色）。
struct PaletteKeyHint: View {
  let key: String
  let label: String

  var body: some View {
    HStack(spacing: Theme.Space.tick) {
      Text(key).foregroundStyle(Color.theme.textPrimary)
      Text(label)
    }
  }
}
