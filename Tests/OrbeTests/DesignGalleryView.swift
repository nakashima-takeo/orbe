import SwiftUI

@testable import Orbe

/// スナップショット対象の部品ギャラリー（Buttons / DSTab / PaletteRow）。
/// `DesignGallerySnapshotTests` が Light/Dark で撮る（`testRenderGallery`）。
struct GalleryView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.bar) {
      label("Button — primary / secondary")
      HStack(spacing: Theme.Space.beat) {
        Button("作成") {}.buttonStyle(DSPrimaryButtonStyle())
        Button("作成") {}.buttonStyle(DSPrimaryButtonStyle()).disabled(true)
        Button("キャンセル") {}.buttonStyle(DSSecondaryButtonStyle())
        Button("キャンセル") {}.buttonStyle(DSSecondaryButtonStyle()).disabled(true)
      }

      label("DSTab — single: active / default")
      HStack(spacing: Chrome.tabGap) {
        DSTabSegment { DSTab(title: "claude", active: true, stateGlyph: .working) }
        DSTabSegment { DSTab(title: "build", stateGlyph: .waiting) }
        DSTabSegment { DSTab(title: "agy") }
      }
      .padding(Chrome.tabRowPad)
      .frame(height: Chrome.tabRowHeight)
      .background(Color.theme.tabRowBg)
      .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs))

      label("DSTabSegment — grouped (worktree bar + divided cells, selected inside)")
      HStack(spacing: Chrome.tabGap) {
        DSTabSegment {
          DSSegmentBar(color: Color.theme.worktreeBar[WorktreeColor.index(forKey: "storefront")])
          DSTab(title: "s/s/checkout", stateGlyph: .working, divided: true)
          DSTab(title: "s/api", active: true, stateGlyph: .waiting, divided: true)
          DSTab(title: "storefront", divided: true)
        }
        DSTabSegment { DSTab(title: "~/notes") }
      }
      .padding(Chrome.tabRowPad)
      .frame(height: Chrome.tabRowHeight)
      .background(Color.theme.tabRowBg)
      .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs))

      label("DSTab — editing (Cmd+R inline rename)")
      // 実 TabBar を再現（地 tab.rowBg・padding 3・gap 2・＋ボタン）。編集タブは下限 tabEditFloor 幅。
      HStack(spacing: Chrome.tabGap) {
        DSTabSegment {
          DSTab(
            title: "feature/editor", active: false, stateGlyph: .working,
            editing: true, editingText: .constant("feature/editor")
          )
          .frame(width: Chrome.tabEditFloor)
        }
        DSTabSegment { DSTab(title: "build", stateGlyph: .waiting) }
        DSTabSegment { DSTab(title: "agy") }
      }
      .padding(Chrome.tabRowPad)
      .frame(height: Chrome.tabRowHeight)
      .background(Color.theme.tabRowBg)
      .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs))

      label("DSTab — editing empty (派生名 placeholder)")
      HStack(spacing: Chrome.tabGap) {
        DSTabSegment {
          DSTab(
            title: "", active: false, stateGlyph: .working,
            editing: true, editingText: .constant(""), editPlaceholder: "src · main"
          )
          .frame(width: Chrome.tabEditFloor)
        }
        DSTabSegment { DSTab(title: "build", stateGlyph: .waiting) }
      }
      .padding(Chrome.tabRowPad)
      .frame(height: Chrome.tabRowHeight)
      .background(Color.theme.tabRowBg)
      .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs))

      label("PaletteRow — selected / default / dormant / info")
      VStack(spacing: 0) {
        PaletteRow(title: "claude", selected: true)
        PaletteRow(title: "codex")
        PaletteRow(title: "gemini（休眠）", kind: .dormant)
        PaletteRow(title: "CLI が見つかりません", showsChevron: false, kind: .info)
      }
      .padding(Theme.Space.step)
      .background(Color.theme.bgSunken)
      .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
      .frame(width: 300)

      Spacer(minLength: 0)
    }
    .padding(Theme.Space.phrase)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.theme.bgBase)
  }

  private func label(_ text: String) -> some View {
    Text(text)
      .font(Font.theme.meta)
      .foregroundStyle(Color.theme.textMuted)
  }
}
