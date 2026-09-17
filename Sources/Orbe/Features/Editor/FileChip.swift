import Foundation
import OrbeEditorCore
import SwiftUI

/// 種別 → 見た目（グリフ・色相）の唯一の決定点。ツリー・ファイルタブ・パンくずはこれしか知らないので、
/// 将来アイコンテーマへ差し替えるときはこの型の中身を変えるだけで済む。
/// 言語は `SyntaxLanguage.detect`（15 言語）で決め、未知は拡張子の頭文字を大文字にした mono（拡張子が
/// 無ければ `·`）。見本（editor/data.ts）は swift / md / json の 3 種だけなので、残りは色相表を暫定で割り当てる。
struct FileChip: Equatable {
  enum Hue: Equatable {
    case orange, blue, yellow, sky, violet, cyan, red, green, teal
  }

  let glyph: String
  /// nil は mono（主文字と `surfaceInk` の地）。
  let hue: Hue?

  static func resolve(_ url: URL) -> FileChip {
    switch SyntaxLanguage.detect(url: url) {
    case .swift: return FileChip(glyph: "S", hue: .orange)
    case .markdown: return FileChip(glyph: "M↓", hue: .blue)
    case .json: return FileChip(glyph: "{}", hue: .yellow)
    case .typescript: return FileChip(glyph: "TS", hue: .sky)
    case .tsx: return FileChip(glyph: "TX", hue: .sky)
    case .javascript: return FileChip(glyph: "JS", hue: .yellow)
    case .css: return FileChip(glyph: "#", hue: .violet)
    case .html: return FileChip(glyph: "<>", hue: .orange)
    case .python: return FileChip(glyph: "Py", hue: .blue)
    case .go: return FileChip(glyph: "Go", hue: .cyan)
    case .rust: return FileChip(glyph: "Rs", hue: .orange)
    case .yaml: return FileChip(glyph: "Y", hue: .red)
    case .toml: return FileChip(glyph: "T", hue: .red)
    case .bash: return FileChip(glyph: "$", hue: .green)
    case .dockerfile: return FileChip(glyph: "D", hue: .teal)
    case nil:
      guard let first = url.pathExtension.first else { return FileChip(glyph: "·", hue: nil) }
      return FileChip(glyph: String(first).uppercased(), hue: nil)
    }
  }

  /// チップの文字サイズ。16 のとき 1 字は 10、記号 2 字は 9、それ以外の 2 字は 8（見本 S 10 / M↓ 8 / {} 9）で、
  /// 他の寸法へは比例して丸める（14 → 9 / 8 / 7、12 → 8 / 7 / 6）。
  func fontSize(for size: CGFloat) -> CGFloat {
    let base: CGFloat
    if glyph.count == 1 {
      base = 10
    } else {
      base = glyph.allSatisfy(\.isPunctuation) || glyph.allSatisfy(\.isSymbol) ? 9 : 8
    }
    return (base * size / 16).rounded()
  }
}

extension ThemeColors {
  func editorHue(_ hue: FileChip.Hue) -> Color {
    switch hue {
    case .orange: return editorHueOrange
    case .blue: return editorHueBlue
    case .yellow: return editorHueYellow
    case .sky: return editorHueSky
    case .violet: return editorHueViolet
    case .cyan: return editorHueCyan
    case .red: return editorHueRed
    case .green: return editorHueGreen
    case .teal: return editorHueTeal
    }
  }
}

/// 種別チップ（角丸の単色文字 ＋ 色相 .16 の淡い地）。ツリー行・ファイルタブは 14（radius 3）、パンくずは
/// 12（radius 2）。字はグリフの字数と寸法で決まる。
struct FileChipView: View {
  let chip: FileChip
  var size: CGFloat = Theme.Layout.editorChip
  @Environment(\.colorScheme) private var scheme

  private static let groundAlpha: Double = 0.16

  var body: some View {
    let small = size < Theme.Layout.editorChip
    let color = chip.hue.map { Color.theme.editorHue($0) } ?? Color.theme.textPrimary
    let ground =
      chip.hue == nil ? EditorInk(scheme).fill(Self.groundAlpha) : color.opacity(Self.groundAlpha)
    Text(chip.glyph)
      .font(Font(Theme.Typography.editorChip(size: chip.fontSize(for: size)) as CTFont))
      .foregroundStyle(color)
      .frame(width: size, height: size)
      .background(
        RoundedRectangle(cornerRadius: small ? 2 : Theme.Radius.xs).fill(ground))
  }
}
