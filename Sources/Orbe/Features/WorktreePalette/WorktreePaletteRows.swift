import SwiftUI

/// worktree パレットのリスト行ビュー（`WorktreePaletteCard` から使う従属ビュー）。カード本体は `WorktreePaletteCard.swift`。

/// リスト内の 1 行（見出し・注記・item）。id は種類ごとに名前空間を分け、`scrollTo` の宛先が
/// 見出しの並び位置と item の平坦 index で衝突して空振りするのを防ぐ。
enum WorktreePaletteListRow: Identifiable {
  case header(sectionID: String, WorktreePaletteSection.Title)
  /// 行が 0 件の欄の、見出しの下の注記。
  case note(sectionID: String, L10nKey)
  /// item は可視の平坦 index を持ち、選択・スクロールの単位になる。
  case item(Int, WorktreePaletteItem)

  var id: String {
    switch self {
    case .header(let section, _): return "header:\(section)"
    case .note(let section, _): return "note:\(section)"
    case .item(let index, _): return Self.itemID(index)
    }
  }

  static func itemID(_ index: Int) -> String { "item:\(index)" }
}

/// リスト内容の実測高（内容ハグ用）。
struct WorktreePaletteContentHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// 初回ロード中のプレースホルダ行（非対話・静的グレー）。寸法は `WorktreePaletteRow` の envelope に一致させ、
/// 先頭グリフ列と名前バーを面トークンの小片で表す。`barWidth` を行ごとに変えて均一ブロックに見せない。
/// 行高は `WorktreePaletteRow` の名前（`workspaceName`）と同じ行ボックスに合わせ、小片はその中で薄く中央に置く。
struct WorktreePaletteSkeletonRow: View {
  /// 待機中に並べる名前バー幅（行ごとに変え均一ブロックに見せない・要素数＝行数）。
  /// **一覧の初回ロードと clean の分類待ちが共有する**——同じ「まだ何も分かっていない」を
  /// 別の並びで描かない。
  static let widths: [CGFloat] = [260, 200, 300, 170, 240, 190, 220]

  let barWidth: CGFloat

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      // 先頭グリフ列。`WorktreePaletteRow` の行高は名前 Text（`workspaceName`）の行ボックスが決めるため、
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

/// 一覧の行と注記の、本文のない行（見出しの下の注記）。
struct WorktreePaletteEmptyNote: View {
  let text: String

  var body: some View {
    Text(text)
      .font(Font.theme.meta)
      .foregroundStyle(Color.theme.textMuted)
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.leading, 14 + Theme.Space.step)
      .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
      .padding(.vertical, Theme.Space.hair)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// worktree パレットのリスト 1 行（一覧の行）。先頭グリフ列（幅 14・中央）＋名前＋補足＋右端の印。
struct WorktreePaletteRow: View {
  let item: WorktreePaletteItem
  let selected: Bool
  /// 行タップ＝決定（release で発火する `onTapGesture`。押し込みでは走らない）。
  let onTap: () -> Void
  /// ホバー開始＝選択の追従（決定は走らない）。効くかどうかは入力モダリティが握る（→ `ModalSelection`）。
  let onHoverEnter: () -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    WorktreePaletteRowFrame(
      glyph: item.glyph, name: item.nameKey.map { l10n.string($0) } ?? item.name,
      nameSuffix: item.glyph == .newBranch ? l10n.string(.worktreePaletteCreateSuffix) : nil,
      detail: item.detailKey.map { l10n.string($0) } ?? item.detail, selected: selected,
      onTap: onTap, onHoverEnter: onHoverEnter
    ) {
      trailing
    }
  }

  /// 右端: 今の worktree は「現在」の札、clean 行は候補件数バッジ＋`⏎`（**0 件ならバッジだけ消え、行
  /// そのものは残る**）、ブランチ行は同期ピル（`↑N` / `↓N`）か、無ければ `checkout → worktree`。
  @ViewBuilder private var trailing: some View {
    if let count = item.candidateCount {
      HStack(spacing: Theme.Space.tick) {
        if count > 0 {
          WorktreePaletteTag(
            text: l10n.plural(
              count, one: .worktreeCleanCandidatesOne, other: .worktreeCleanCandidatesOther))
        }
        Text("⏎")
          .font(Font.theme.sectionLabel)
          .foregroundStyle(Color.theme.textMuted)
          .fixedSize()
      }
    } else if item.isCurrent, item.glyph == .worktree {
      WorktreePaletteTag(text: l10n.string(.worktreePaletteCurrentTag))
    } else if let sync = item.sync {
      WorktreePaletteSyncPills(sync: sync)
    } else if case .checkout = item.enter {
      WorktreePaletteTruncatingSlot(l10n.string(.worktreePaletteWorktreeCheckout)) {
        Text($0)
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
      }
    }
  }
}

/// 行末の accent の札（「現在」・候補件数）。
struct WorktreePaletteTag: View {
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

/// 行の骨格（先頭グリフ列＋名前＋補足＋右端）。一覧の行とベースを選ぶ画面の行が共有する。
/// 選択行のみ accent 地（`selectionFill`＝accent .14 の淡塗り）でハイライト。
struct WorktreePaletteRowFrame<Trailing: View>: View {
  let glyph: WorktreePaletteItem.Glyph
  let name: String
  /// 名前の直後に muted で続ける語（作成行の「を作る」）。
  var nameSuffix: String?
  let detail: String?
  let selected: Bool
  let onTap: () -> Void
  let onHoverEnter: () -> Void
  @ViewBuilder let trailing: () -> Trailing
  @Environment(\.chromeFontResolver) private var fontResolver

  /// 要素の間隔は HStack の spacing でなく各要素の先頭の余白が運ぶ——縮みきって幅 0 になった枠にも
  /// HStack は両側に spacing を入れるので、spacing に任せると畳んだ枠の位置で間隔が 2 倍に開く。
  var body: some View {
    let gap = Theme.Space.step
    return HStack(spacing: 0) {
      glyphColumn
      // 行は割り当て幅を超えない。縮むのは名前・補足が先。
      WorktreePaletteTruncatingSlot(name, leading: gap) {
        fontResolver.text($0, base: Theme.Typography.workspaceName)
          .font(Font.theme.workspaceName)
          .foregroundStyle(Color.theme.textPrimary)
      }
      .layoutPriority(1)
      if let suffix = nameSuffix ?? detail {
        WorktreePaletteTruncatingSlot(suffix, leading: gap) {
          fontResolver.text($0, base: Theme.Typography.meta)
            .font(Font.theme.meta)
            .foregroundStyle(Color.theme.textMuted)
        }
      }
      Spacer(minLength: gap + Theme.Space.tick + gap)
      trailing()
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

  /// 先頭グリフ列（幅 14・中央）。文字グリフ（▤⎇⇅＋❯）を種別で出し分ける。
  private var glyphColumn: some View {
    Group {
      switch glyph {
      case .worktree, .directory:
        Text("▤").font(Font.theme.chrome).foregroundStyle(Color.theme.textMuted)
      case .localBranch:
        Text("⎇").font(Font.theme.chrome).foregroundStyle(Color.theme.textMuted)
      case .remoteBranch:
        Text("⇅").font(Font.theme.chrome).foregroundStyle(Color.theme.textMuted)
      case .newBranch:
        Text("＋").font(Font.theme.chrome).foregroundStyle(Color.theme.accentPrimary)
      case .clean:
        Text("❯").font(Font.theme.chrome).foregroundStyle(Color.theme.accentPrimary)
      }
    }
    .frame(width: 14, alignment: .center)
  }
}

/// 縮みうる 1 行テキストの枠。末尾省略で読める形になる幅（先頭 1 文字＋…）があれば出し、無ければ
/// まったく出さない——`Text` は「…」を付ける幅も無いと、先頭の文字を「…」なしで途中まで描いてしまう。
/// 読める最小幅は、同じ描き方の見本（先頭 1 文字＋…）を見えない形で置いて測る。
/// 前後の余白は出すときだけ幅に足し、出さないときは余白ごと幅 0 になる。
struct WorktreePaletteTruncatingSlot<Content: View>: View {
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
