import SwiftUI

extension View {
  /// 固定寸の部品が密なヘッダ行で、あふれを CSS の `overflow: hidden` 同様に右端で切る。
  /// 幅を提案値に固定して親の膨張（＝ペイン全体の中央寄せ両断ち）を防ぐ。
  func paneRowClipped() -> some View {
    frame(maxWidth: .infinity, alignment: .leading).clipped()
  }
}

/// 反転セグメント切替（レールのタブ・ビューアの表示切替で共用。Segmented）。
/// 地 tabRowBg・padding 1・radius 4。項目 padding 2×8（dense 1×7）・radius 3、
/// active は前景色反転（textPrimary 地に tabActiveText 文字）。
struct PaneSegmented: View {
  struct Item {
    let key: String
    let label: String
  }

  let items: [Item]
  let activeKey: String
  var dense = false
  let onSelect: (String) -> Void

  var body: some View {
    HStack(spacing: 1) {
      ForEach(items, id: \.key) { item in
        Text(item.label)
          .font(Font.theme.paneSegment)
          .lineLimit(1)
          .foregroundStyle(
            item.key == activeKey ? Color.theme.tabActiveText : Color.theme.textMuted
          )
          .padding(.horizontal, dense ? 7 : 8)
          .padding(.vertical, dense ? 1 : 2)
          .background(
            RoundedRectangle(cornerRadius: 3)
              .fill(item.key == activeKey ? Color.theme.textPrimary : Color.clear)
          )
          .contentShape(Rectangle())
          .onTapGesture { onSelect(item.key) }
      }
    }
    .padding(1)
    .background(RoundedRectangle(cornerRadius: 4).fill(Color.theme.tabRowBg))
  }
}

/// 変更ステータスのバッジ（M/A/D/C の四角。StatusBadge・13×13・radius 3・淡塗り）。
struct StatusBadgeView: View {
  let badge: ChangeBadge
  var size: CGFloat = 13
  var font: Font = Font.theme.paneFootnote

  var body: some View {
    Text(badge.letter)
      .font(font)
      .foregroundStyle(badge.color)
      .frame(width: size, height: size)
      .background(RoundedRectangle(cornerRadius: 3).fill(badge.tint))
  }
}

extension ChangeBadge {
  var color: Color {
    switch self {
    case .modified: return .theme.accentPrimary
    case .added: return .theme.diffAdded
    case .deleted: return .theme.diffRemoved
    case .conflict: return .theme.conflict
    }
  }

  /// バッジ地の淡塗り（見本: M=18% / A=16%。D/C も同系の淡さで揃える）。
  var tint: Color {
    switch self {
    case .modified: return .theme.accentPrimary.opacity(0.18)
    case .added: return .theme.diffAdded.opacity(0.16)
    case .deleted: return .theme.diffRemoved.opacity(0.16)
    case .conflict: return .theme.conflict.opacity(0.16)
    }
  }
}

/// stage 状態のチェックボックス（未 / 一部 / 済。StageBox・12×12）。
struct StageBoxView: View {
  let state: StageState

  var body: some View {
    switch state {
    case .staged:
      StatusGlyphView(kind: .done, size: 11)
        .frame(width: 12, height: 12)
    case .partial:
      RoundedRectangle(cornerRadius: 2.5)
        .fill(Color.theme.diffAdded.opacity(0.22))
        .frame(width: 12, height: 12)
        .overlay(Rectangle().fill(Color.theme.diffAdded).frame(width: 6, height: 2))
    case .none:
      RoundedRectangle(cornerRadius: 2.5)
        .strokeBorder(Color.theme.surfaceInk.opacity(0.22), lineWidth: 1)
        .frame(width: 12, height: 12)
    }
  }
}

/// `+N −M` の色分けテキスト（addDelText。フォントは呼び出し側）。
struct AddDelText: View {
  let add: Int
  let del: Int

  var body: some View {
    (Text(verbatim: "+\(add)").foregroundColor(.theme.diffAdded)
      + (del > 0 ? Text(verbatim: " −\(del)").foregroundColor(.theme.diffRemoved) : Text("")))
      .lineLimit(1)
  }
}

/// hunk ヘッダやボタン列で使う小ボタン（`stage s`・`解除 s`・`checkout` 等）。
struct PaneMiniButton: View {
  let label: String
  var font: Font = Font.theme.paneSegment
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(label)
        .font(font)
        .foregroundStyle(Color.theme.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .overlay(
          RoundedRectangle(cornerRadius: 3)
            .strokeBorder(Color.theme.surfaceInk.opacity(0.14), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
