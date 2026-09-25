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
  /// 待機中に並べる名前バー幅（行ごとに変え均一ブロックに見せない・要素数＝行数）。
  /// **一覧の初回ロードと clean の分類待ちが共有する**——同じ「まだ何も分かっていない」を
  /// 別の並びで描かない。
  static let widths: [CGFloat] = [260, 200, 300, 170, 240, 190, 220]

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

/// 行末チップ（`#142` 等）。先頭に branch グリフ・地は `tintDiffAdded`（＝diffAdd .12）・文字 diffAdd。
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
    .background(Capsule().fill(Color.theme.tintDiffAdded))
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

  /// 要素の間隔は HStack の spacing でなく各要素の先頭の余白が運ぶ——縮みきって幅 0 になった枠にも
  /// HStack は両側に spacing を入れるので、spacing に任せると畳んだ枠の位置で間隔が 2 倍に開く。
  var body: some View {
    let gap = Theme.Space.step
    return HStack(spacing: 0) {
      glyphColumn
      if let idText = item.idText {
        Text(idText)
          .font(Font.theme.chrome)
          .foregroundStyle(Color.theme.diffAdded)
          .lineLimit(1)
          .fixedSize()
          .padding(.leading, gap)
      }
      // 行は割り当て幅を超えない。縮むのは名前・補足が先で、それでも入らないときだけ右側のノートを切る。
      DispatchTruncatingSlot(item.name, leading: gap) {
        fontResolver.text($0, base: Theme.Typography.workspaceName)
          .font(Font.theme.workspaceName)
          .foregroundStyle(nameColor)
      }
      .layoutPriority(1)
      if let detail = item.detailKey.map({ l10n.string($0) }) ?? item.detail {
        DispatchTruncatingSlot(detail, leading: gap) {
          fontResolver.text($0, base: Theme.Typography.meta)
            .font(Font.theme.meta)
            .foregroundStyle(Color.theme.textMuted)
        }
      }
      if let reviewNote = item.reviewNote {
        DispatchTruncatingSlot(l10n.string(reviewNote.key), leading: gap) {
          Text($0)
            .font(Font.theme.sectionLabel)
            .foregroundStyle(Color.theme.textMuted)
        }
        .layoutPriority(2)
      }
      Spacer(minLength: gap + Theme.Space.tick + gap)
      trailing
        .layoutPriority(2)
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
      case .clean:
        Text("❯").font(Font.theme.chrome).foregroundStyle(Color.theme.accentPrimary)
      case .none:
        Color.clear
      }
    }
    .frame(width: 14, alignment: .center)
  }

  /// 右端: worktree/branch はチップ（＋working リング）、issue/PR は muted ノート。issue/PR は末尾に「開く」。
  /// clean 行は候補件数バッジ＋`⏎`（**0 件ならバッジだけ消え、行そのものは残る**）。
  /// Local branch 行は上のどれも無いときだけ同期ピル（`↑N` / `↓N`）。
  /// ノートと「開く」の間隔はノートが持つ（ノートが縮みきって消えたら、間隔も一緒に消える）。
  private var trailing: some View {
    let tick = Theme.Space.tick
    return HStack(spacing: 0) {
      if let count = item.candidateCount {
        HStack(spacing: tick) {
          if count > 0 {
            Text(
              l10n.plural(
                count, one: .dispatchCleanCandidatesOne, other: .dispatchCleanCandidatesOther)
            )
            .font(Font.theme.sectionLabel)
            .foregroundStyle(Color.theme.accentPrimary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.theme.tintAccent))
          }
          Text("⏎")
            .font(Font.theme.sectionLabel)
            .foregroundStyle(Color.theme.textMuted)
            .fixedSize()
        }
      } else if !item.badges.isEmpty || item.showsWorkingIndicator {
        HStack(spacing: tick) {
          ForEach(item.badges) { badge in DispatchBadgeView(badge: badge) }
          if item.showsWorkingIndicator {
            StatusGlyphView(kind: .working, size: 10)
              .padding(.leading, Theme.Space.hair)
          }
        }
      } else if let note = trailingNote {
        DispatchTruncatingSlot(l10n.string(note.noteKey), trailing: onOpenWeb == nil ? 0 : tick) {
          Text($0)
            .font(Font.theme.sectionLabel)
            .foregroundStyle(Color.theme.textMuted)
        }
      } else if let sync = item.sync {
        DispatchSyncPills(sync: sync)
      }
      if let onOpenWeb {
        OpenWebButton(action: onOpenWeb)
          .padding(.leading, Theme.Space.hair + (trailingNote == nil ? tick : 0))
      }
    }
  }

  /// 右端に出すノート（件数バッジ・チップ・working リングのある行では出さない）。
  private var trailingNote: DispatchWorktreeKind? {
    guard item.candidateCount == nil, item.badges.isEmpty, !item.showsWorkingIndicator else {
      return nil
    }
    return item.worktreeNote
  }

  private var nameColor: Color {
    item.isPrimary ? Color.theme.textPrimary : Color.theme.textSecondary
  }
}

/// 縮みうる 1 行テキストの枠。末尾省略で読める形になる幅（先頭 1 文字＋…）があれば出し、無ければ
/// まったく出さない——`Text` は「…」を付ける幅も無いと、先頭の文字を「…」なしで途中まで描いてしまう。
/// 読める最小幅は、同じ描き方の見本（先頭 1 文字＋…）を見えない形で置いて測る。
/// 前後の余白は出すときだけ幅に足し、出さないときは余白ごと幅 0 になる。
struct DispatchTruncatingSlot<Content: View>: View {
  let text: String
  let leading: CGFloat
  let trailing: CGFloat
  let render: (String) -> Content

  init(
    _ text: String, leading: CGFloat = 0, trailing: CGFloat = 0,
    @ViewBuilder render: @escaping (String) -> Content
  ) {
    self.text = text
    self.leading = leading
    self.trailing = trailing
    self.render = render
  }

  var body: some View {
    TruncatingSlotLayout(leading: leading, trailing: trailing) {
      render(text).lineLimit(1).truncationMode(.tail)
      render(String(text.prefix(1)) + "…").lineLimit(1).fixedSize().hidden()
    }
    .clipped()
  }
}

/// 子 [本体, 見本]。余白を除いた幅が本体の全幅にも見本の幅にも満たなければ、余白ごと幅 0 で本体を
/// 描かない。
private struct TruncatingSlotLayout: Layout {
  let leading: CGFloat
  let trailing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    let insets = leading + trailing
    let inner = ProposedViewSize(
      width: proposal.width.map { max(0, $0 - insets) }, height: proposal.height)
    let fits = content.sizeThatFits(inner)
    let shown = CGSize(width: fits.width + insets, height: fits.height)
    guard let width = inner.width, subviews.count == 2 else { return shown }
    let full = content.sizeThatFits(.unspecified).width
    let readable = subviews[1].sizeThatFits(.unspecified).width
    return width >= min(full, readable) ? shown : CGSize(width: 0, height: fits.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let width = max(0, bounds.width - leading - trailing)
    for subview in subviews {
      subview.place(
        at: CGPoint(x: bounds.minX + leading, y: bounds.minY),
        proposal: ProposedViewSize(width: width, height: bounds.height))
    }
  }
}
