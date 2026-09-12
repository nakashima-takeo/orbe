import SwiftUI

/// エディター面の空状態: 沈んだ ◐ と一文、ショートカット 2 行。
struct EditorEmptyView: View {
  @Environment(\.localization) private var l10n

  // 見本（EmptyView.tsx）の寸法。◐ の下 18・一文の下 22・ラベル列の幅 170。
  private let glyphSize: CGFloat = 44
  private let leadTop: CGFloat = 18
  private let hintsTop: CGFloat = 22
  private let labelWidth: CGFloat = 170

  var body: some View {
    VStack(spacing: 0) {
      OrbeMarkGlyph(size: glyphSize, color: Color.theme.editorGhost)
      Text(l10n.string(.editorEmptyLead))
        .font(Font.theme.editorLead)
        .foregroundStyle(Color.theme.textMuted)
        .padding(.top, leadTop)
      VStack(alignment: .leading, spacing: Theme.Space.step) {
        shortcut(.editorEmptySearchProject, key: "⌘⇧F")
        shortcut(.editorEmptyBackToTerminal, key: "⌘E")
      }
      .padding(.top, hintsTop)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func shortcut(_ label: L10nKey, key: String) -> some View {
    HStack(spacing: Theme.Space.beat) {
      Text(l10n.string(label))
        .font(Font.theme.editorHint)
        .foregroundStyle(Color.theme.textMuted)
        .frame(width: labelWidth, alignment: .trailing)
      EditorKbd(key: key)
    }
  }
}

/// 空状態のキー表記（枠 hairline・地 fill・radius 4・padding 1 7）。
private struct EditorKbd: View {
  let key: String
  @Environment(\.colorScheme) private var scheme

  // 見本の dark 値。light は換算（地 ×0.6 / 枠 ×1.4）。
  private static let fillAlpha: CGFloat = 0.05
  private static let borderAlpha: CGFloat = 0.14

  var body: some View {
    let dark = scheme == .dark
    Text(key)
      .font(Font.theme.editorHint)
      .tracking(Theme.Typography.trackingKey)
      .foregroundStyle(Color.theme.editorIcon)
      // tracking は末尾グリフの後にも付くため、その分だけ trailing を詰めて光学中央を保つ。
      .padding(.trailing, -Theme.Typography.trackingKey)
      .padding(.vertical, 1)
      .padding(.horizontal, 7)
      .padding(Theme.Stroke.hairline)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.sm)
          .fill(Color.theme.surfaceInk.opacity(dark ? Self.fillAlpha : Self.fillAlpha * 0.6))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.sm)
          .strokeBorder(
            Color.theme.borderInk.opacity(dark ? Self.borderAlpha : Self.borderAlpha * 1.4),
            lineWidth: Theme.Stroke.hairline))
  }
}

#if DEBUG
  enum EditorEmptyFixtures {
    /// 空状態を面の地（bgBase）の上で描く。gallery が dark / light を撮る。
    @MainActor static func gallery() -> some View {
      EditorEmptyView()
        .background(Color.theme.bgBase)
        .environment(\.localization, LocalizationStore(language: .ja))
    }
  }

  #Preview("EditorEmptyView") {
    EditorEmptyFixtures.gallery().frame(width: 640, height: 480)
  }
#endif
