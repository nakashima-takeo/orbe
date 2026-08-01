import SwiftUI

/// Dispatch のリスト行ビュー（`DispatchCard` から使う従属ビュー）。カード本体は `DispatchCard.swift`。

/// リスト内の 1 行（見出し or item）。id は header/item で名前空間を分け、`scrollTo` の宛先が
/// 見出しの並び位置と item の平坦 index で衝突して空振りするのを防ぐ。
enum DispatchListRow: Identifiable {
  case header(String)
  /// item は可視の平坦 index を持ち、選択・スクロールの単位になる。
  case item(Int, DispatchItem)

  var id: String {
    switch self {
    case .header(let title): return "header:\(title)"
    case .item(let index, _): return Self.itemID(index)
    }
  }

  static func itemID(_ index: Int) -> String { "item:\(index)" }
}

/// ヘッダ＋フッター（chrome）の合算高。リスト cap から差し引き、カードが窓を超えないようにする。
struct DispatchChromeHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

/// リスト内容の実測高（内容ハグ用）。
struct DispatchContentHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// issue/PR 行末の muted な「開く」アフォーダンス（external-link 系）。⌘↵ と対の副操作。
struct OpenWebButton: View {
  let action: () -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    Button(action: action) {
      HStack(spacing: Theme.Space.tick) {
        Text("↗")
        Text(l10n.string(.dispatchHintOpen))
      }
      .font(Font.theme.sectionLabel)
      .foregroundStyle(Color.theme.textMuted)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(Capsule().fill(Color.theme.smallPillFill))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

/// gh 誘導情報・ローディング行（選択・実行の対象外・muted）。ローディング時のみ先頭に working スピナ。
struct DispatchInfoRow: View {
  let item: DispatchItem
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      Group {
        if item.isLoadingRow {
          StatusGlyphView(kind: .working, size: 10)
        } else {
          Color.clear
        }
      }
      .frame(width: 14, alignment: .center)
      Text(item.infoKind.map { l10n.string($0.key) } ?? item.name)
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 初回ロード中のプレースホルダ行（非対話・静的グレー）。寸法は `DispatchRow` の envelope に一致させ、
/// 先頭グリフ列と名前バーを面トークンの小片で表す。`barWidth` を行ごとに変えて均一ブロックに見せない。
/// 行高は `DispatchRow` の名前（`workspaceName`）と同じ行ボックスに合わせ、小片はその中で薄く中央に置く。
struct DispatchSkeletonRow: View {
  let barWidth: CGFloat

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      // 先頭グリフ列。`DispatchRow` の行高は名前 Text（`workspaceName`）の行ボックスが決めるため、
      // 同じフォントの不可視 Text を同居させて同一の行高を確保する（薄い小片はその行ボックス中央に載る）。
      ZStack {
        Text(verbatim: " ").font(Font.theme.workspaceName).hidden().accessibilityHidden(true)
        RoundedRectangle(cornerRadius: Theme.Radius.sm)
          .fill(Color.theme.surface2)
          .frame(width: 10, height: 10)
      }
      .frame(width: 14, alignment: .center)
      RoundedRectangle(cornerRadius: Theme.Radius.sm)
        .fill(Color.theme.surface2)
        .frame(width: barWidth, height: 10)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 行末チップ（`#142` 等）。先頭に branch グリフ・地は tint(diffAdd, .12)＝`tintDone`・文字 diffAdd。
struct DispatchBadgeView: View {
  let badge: DispatchBadge

  var body: some View {
    HStack(spacing: Theme.Space.tick) {
      GitGlyphView(kind: .branch, size: 10, color: .theme.diffAdded)
      Text(badge.text).lineLimit(1)
    }
    .font(Font.theme.sectionLabel)
    .foregroundStyle(Color.theme.diffAdded)
    .padding(.horizontal, 7)
    .padding(.vertical, 1)
    .background(Capsule().fill(Color.theme.tintDone))
    .fixedSize()
  }
}

/// Dispatch のリスト 1 行。先頭グリフ列（幅 14・中央）＋色付き ID＋名前＋補足＋右端チップ/ノート/「開く」。
/// 選択行のみ accent 地（`selectionFill`＝accent .14 の淡塗り）でハイライト。
struct DispatchRow: View {
  let item: DispatchItem
  let selected: Bool
  /// 行タップ＝決定（release で発火する `onTapGesture`。押し込みでは走らない）。
  let onTap: () -> Void
  /// ホバー開始＝選択の追従（決定は走らない）。効くかどうかは入力モダリティが握る（→ `ModalSelection`）。
  let onHoverEnter: () -> Void
  /// issue/PR 行の「開く」（ブラウザ表示）。nil で出さない。
  /// `Button` は行の `onTapGesture` より内側で、SwiftUI は内側のジェスチャを優先するため
  /// 「開く」クリックが行の決定（worktree 作成）を巻き込むことはない。
  let onOpenWeb: (() -> Void)?
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      glyphColumn
      if let idText = item.idText {
        Text(idText)
          .font(Font.theme.chrome)
          .foregroundStyle(Color.theme.diffAdded)
          .lineLimit(1)
          .fixedSize()
      }
      fontResolver.text(item.name, base: Theme.Typography.workspaceName)
        .font(Font.theme.workspaceName)
        .foregroundStyle(nameColor)
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(1)
      if let detail = item.detail {
        fontResolver.text(detail, base: Theme.Typography.meta)
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      if let reviewNote = item.reviewNote {
        Text(l10n.string(reviewNote.key))
          .font(Font.theme.sectionLabel)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .fixedSize()
      }
      Spacer(minLength: Theme.Space.tick)
      trailing
    }
    .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(selected ? Color.theme.selectionFill : .clear)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: onTap)
    // ホバー開始のみ通知（終了では何もしない＝選択はその行に残り、キー操作と同じ据わりになる）。
    .onHover { if $0 { onHoverEnter() } }
  }

  /// 先頭グリフ列（幅 14・中央）。文字グリフ（▤⎇⇅）と octicon（issue/PR）を種別で出し分ける。
  @ViewBuilder private var glyphColumn: some View {
    Group {
      switch item.glyph {
      case .worktree:
        Text("▤").font(Font.theme.chrome)
          .foregroundStyle(item.isPrimary ? Color.theme.stateWorking : Color.theme.textMuted)
      case .localBranch:
        Text("⎇").font(Font.theme.chrome).foregroundStyle(Color.theme.textMuted)
      case .remoteBranch:
        Text("⇅").font(Font.theme.chrome).foregroundStyle(Color.theme.textMuted)
      case .issue:
        GitGlyphView(kind: .issue, size: 12, color: Color.theme.diffAdded)
      case .pullRequest:
        GitGlyphView(kind: .branch, size: 12, color: Color.theme.diffAdded)
      case .none:
        Color.clear
      }
    }
    .frame(width: 14, alignment: .center)
  }

  /// 右端: worktree/branch はチップ（＋working リング）、issue/PR は muted ノート。issue/PR は末尾に「開く」。
  private var trailing: some View {
    HStack(spacing: Theme.Space.tick) {
      if !item.badges.isEmpty || item.showsWorkingIndicator {
        ForEach(item.badges) { badge in DispatchBadgeView(badge: badge) }
        if item.showsWorkingIndicator {
          StatusGlyphView(kind: .working, size: 10)
            .padding(.leading, Theme.Space.hair)
        }
      } else if let note = item.worktreeNote {
        Text(l10n.string(note.noteKey))
          .font(Font.theme.sectionLabel)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .fixedSize()
      }
      if let onOpenWeb {
        OpenWebButton(action: onOpenWeb)
          .padding(.leading, Theme.Space.hair)
      }
    }
  }

  private var nameColor: Color {
    item.isPrimary ? Color.theme.textPrimary : Color.theme.textSecondary
  }
}
