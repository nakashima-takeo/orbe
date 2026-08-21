import SwiftUI

/// パレットのカード本体（WorkspaceSwitcher の器）。ヘッダ行（◐＋クエリ/breadcrumb・
/// 下罫線。入力欄も breadcrumb も無ければ描かない）＋行リスト（padding 6・PaletteRow）＋
/// フッターヒント（上罫線）。
/// 外郭は GlassPanel(.panel α.72・radius 16)＋panel elevation。幅は呼び出し側（PaletteOverlay）が与える。
/// focus は単一の `@FocusState<PaletteFocus?>` に一本化し、入力欄（`TextField`）とカード器
/// （`.focusable()`）の間で移動するだけ。**両方の宛先を常設**するのがこの器の不変条件で
/// （入力欄の常設は `header` 参照）、モード切替が「既存ビュー間の focus 移動」に閉じ、
/// first responder の所在が常に一意になる。focus 確定は model の focusToken で駆動し、
/// **カード内のクリックもここを通る**（→ `simultaneousGesture`）ため、マウスとキーボードを混ぜて使える。
struct PaletteCard: View {
  @Bindable var model: PaletteModel
  /// カード全体の高さ上限（窓に収める。`PaletteOverlay` が窓高から算出して渡す）。
  /// **既定値は持たせない**——`.infinity` の逃げ道を作ると「窓を見ない呼び出し」が残る。
  let maxHeight: CGFloat
  @FocusState private var focus: PaletteFocus?
  /// chrome（ヘッダ・セグメント・一文・ヒント）の実測高。リスト上限から差し引く。
  @State private var chromeHeight: CGFloat = 0

  /// 行リストの見た目の高さ上限（px）。これを超える行は内部スクロールへ。コンポーネント局所の定数
  /// （CompletionList.capHeight と同流儀。グローバルトークンは足さない）。
  static let capHeight: CGFloat = 320

  /// 行リスト帯の内側余白。**帯の高さ＝スクロール域＋この 2 倍**なので、窓の残りから同じ分を引かないと
  /// カードが上限を 12pt 超えて下端（ヒント）が切れる。引く側と敷く側で 1 つの値を共有する。
  static let listPadding: CGFloat = Theme.Space.note

  /// スクロール域の実効上限。**見た目の上限（320）と窓の残りの小さい方**。前者は「長い一覧が縦を
  /// 占有しない」という見た目の判断、後者は「窓を突き抜けない」という器の契約で、別軸なので
  /// 別々の min として掛ける。ビューの外から呼べる形にしてあるのは、この逆算そのものを検証するため。
  static func listMaxHeight(maxHeight: CGFloat, chromeHeight: CGFloat) -> CGFloat {
    min(capHeight, max(0, maxHeight - chromeHeight - listPadding * 2))
  }

  private var listMaxHeight: CGFloat {
    Self.listMaxHeight(maxHeight: maxHeight, chromeHeight: chromeHeight)
  }

  /// セグメント外枠 9 / セグメント 6。`Theme.Radius` の格子（3/4/8/10/12/16）に無い見本の実寸なので
  /// `capHeight` と同じくコンポーネント局所の定数にする（グローバルトークンは足さない）。
  private let segmentRowRadius: CGFloat = 9
  private let segmentRadius: CGFloat = 6

  var body: some View {
    // 面の濃度だけ model.surface（panel .72 / attention は popup .90）で変え、
    // 幾何（radius 16）・blur（hudWindow≒24）・枠（panel .08/.12）・影（panel）は panel 級に固定する。
    GlassPanel(
      level: model.surface, cornerRadius: Theme.Glass.radius(.panel),
      materialOverride: .hudWindow, elevationOverride: .panel, borderOverride: .panel
    ) {
      VStack(alignment: .leading, spacing: 0) {
        // ヘッダのスロットは入力欄と breadcrumb の 2 つ。両方空なら行ごと描かない
        // （他スロット同様「埋まっているものだけ描く」）。入力欄の常設（header 参照）はこの器の中で
        // 成り立つため、入力欄を出しうるパレットはヘッダを持ち続ける——`fieldVisible` が立つモードは
        // この条件を必ず満たし、入力欄なしモードも breadcrumb（‹ 親）を出すため、往復でヘッダは消えない。
        if model.fieldVisible || model.breadcrumb != nil {
          // 罫線ごと 1 枚のプローブで測る（`spacing: 0` の入れ子なのでレイアウトは変わらない）。
          // 罫線を測り漏らすとその分だけ chrome を過小評価し、カードが窓をわずかに超える。
          VStack(alignment: .leading, spacing: 0) {
            header
            divider
          }
          .background(chromeProbe)
        }

        // リスト直上のスロット（セグメント・一文）。どちらも空で出さない＝他パレットは無影響。
        // 罫線はヘッダ側に付いたままで、こことリストの間には入れない。
        if !model.segments.isEmpty {
          segmentBar.background(chromeProbe)
        }
        if !model.caption.isEmpty {
          captionLine.background(chromeProbe)
        }

        // 行ゼロ（入力欄だけのプロンプト＝改名・ディレクトリ・タブ改名）では行リストごと描かない。
        // 描くと 6pt パディングの空帯がヘッダ罫線と hint 罫線に挟まれ、中身ゼロの帯に見える。
        // 窓が低すぎてリストの取り分が 0 になったときも同じ理由で帯ごと畳む。
        if !model.rows.isEmpty, listMaxHeight > 0 {
          ScrollViewReader { proxy in
            ScrollView {
              VStack(spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.offset) { i, row in
                  rowView(i, row)
                    .id(i)
                }
              }
            }
            .frame(maxHeight: listMaxHeight)
            // ScrollView は走査軸に greedy で、上位（PaletteOverlay の全画面提案）から高さを目一杯
            // 取り上限まで伸びる。content 高でハグさせ上限未満では余白を作らないため、垂直方向だけ
            // 内容サイズに固定する（超過時は maxHeight が頭打ちし内部スクロールに入る）。
            .fixedSize(horizontal: false, vertical: true)
            .scrollIndicators(.automatic)
            .onChange(of: model.selected) { proxy.scrollTo(model.selected) }
            // 窓を縮めてリストが縮んだ瞬間も選択行を可視域へ引き戻す。
            .onChange(of: listMaxHeight) { proxy.scrollTo(model.selected) }
            .onAppear { proxy.scrollTo(model.selected) }
            .padding(Self.listPadding)
          }
        }

        if !model.hint.isEmpty || !model.hintKeys.isEmpty {
          VStack(alignment: .leading, spacing: 0) {
            divider
            // 余白はスロットごと。素文字列 hint は従来の 16×10 を保ち（既存パレットの見た目を
            // 変えない）、キー付きセグメントだけがデザイン第10シーンの 9×20 を取る。
            Group {
              if model.hintKeys.isEmpty {
                Text(model.hint)
                  .foregroundStyle(Color.theme.textMuted)
                  .padding(.horizontal, Theme.Space.bar)
                  .padding(.vertical, Theme.Space.step + Theme.Space.hair)
              } else {
                // セグメント間隔 14・キー副色/ラベル muted。
                HStack(spacing: Theme.Space.beat + Theme.Space.hair) {
                  ForEach(model.hintKeys) { hintKey in
                    HStack(spacing: Theme.Space.tick) {
                      Text(hintKey.key).foregroundStyle(Color.theme.textSecondary)
                      Text(hintKey.label).foregroundStyle(Color.theme.textMuted)
                    }
                  }
                }
                .padding(.horizontal, Theme.Space.span)
                .padding(.vertical, 9)
              }
            }
            .font(Font.theme.meta)
          }
          .background(chromeProbe)
        }
      }
    }
    // 窓が許した高さで頭打ちにする（上限は overlay が窓高から逆算して渡す）。上詰めで、
    // 余った縦は下に残す＝カードが窓いっぱいに間延びしない。
    .frame(maxHeight: maxHeight, alignment: .top)
    .onPreferenceChange(ChromeHeightKey.self) { chromeHeight = $0 }
    // カード器（.focusable()）を常設し、入力欄ありモードでカーソルに委ねるべきキーだけ器側で
    // .ignored を返す。宛先常設でモード切替が「既存ビュー間の focus 移動」になる。
    .modifier(PaletteCardKeyCapture(model: model, focus: $focus))
    // カード内のクリックは first responder を宛先から落とす（行を描く `SelectableRow` の
    // `onTapGesture` は、それ自体が focus の宛先にならない）。受けた地点で宛先を確定し直すことで、
    // クリックのアクションが決定でも直接アクションでもモード遷移でも、キー操作がそのまま続く。
    // `simultaneousGesture` は子のジェスチャと競合せず同時に成立するため、行のタップ挙動は変わらない。
    .simultaneousGesture(TapGesture().onEnded { model.focus() })
    .onChange(of: model.focusToken, initial: true) {
      focus = model.fieldVisible ? .field : .card
    }
  }

  /// chrome スロットの実測高を合算して器へ遡上させる probe。chrome の高さは `maxHeight` に
  /// 依存しない（＝この遡上は循環せず 1 パスで収束する）。
  private var chromeProbe: some View {
    GeometryReader { proxy in
      Color.clear.preference(key: ChromeHeightKey.self, value: proxy.size.height)
    }
  }

  private var divider: some View {
    Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
  }

  /// リスト直上の全幅セグメント。地は 2 段目タブ行と同じ `tabRowBg`、選択は他のパレット行と同じ選択塗り。
  /// `ForEach` へは値で渡す（`headerPills` と同じ理由——配列が空へ縮む更新パスで添字読みは範囲外になる）。
  /// index はクロージャへ値で閉じ込め、評価時に配列へ添字で戻らない。
  private var segmentBar: some View {
    HStack(spacing: Theme.Space.tick) {
      ForEach(Array(model.segments.enumerated()), id: \.element.id) { index, segment in
        HStack(spacing: Theme.Space.note) {
          if let glyph = segment.glyph {
            StatusGlyphView(kind: glyph, size: 12)
          }
          Text(segment.label)
        }
        .font(Font.theme.chrome)
        .foregroundStyle(segment.active ? Color.theme.textPrimary : Color.theme.textMuted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: segmentRadius)
            .fill(segment.active ? Color.theme.selectionFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.onTapSegment(index) }
      }
    }
    .padding(Theme.Space.tick)
    .background(RoundedRectangle(cornerRadius: segmentRowRadius).fill(Color.theme.tabRowBg))
    .padding(.horizontal, Theme.Space.step)
    .padding(.top, Theme.Space.step)
    .padding(.bottom, Theme.Space.hair)
  }

  /// リスト直上の一文。キー割当ではなくこの面の前提を言い切るので、フッターのヒントとは別に置く。
  /// 字は補足の小字の語彙（`meta`）をフッターヒントと共有する。
  private var captionLine: some View {
    Text(model.caption)
      .font(Font.theme.meta)
      .foregroundStyle(Color.theme.textMuted)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Theme.Space.bar)
      .padding(.top, Theme.Space.tick)
  }

  /// ヘッダ行: ◐（glyphGradient）＋クエリ入力欄 or breadcrumb（‹ 親）。両スロット空のとき
  /// body 側が行ごと描かないため、ここへは少なくとも一方が埋まった状態で来る。
  ///
  /// **入力欄は `fieldVisible` に依らず常設する**（focus 宛先の常設＝この器の不変条件）。`fieldVisible` は
  /// 「見せて場所を取るか」だけを決め、mount の有無は決めない。宛先が同じ更新 pass で新規 mount されると
  /// SwiftUI はその pass で当てた `@FocusState` を取りこぼし、first responder が常設のカード器に残る
  /// ——↑↓（器が捕捉）だけ効き、←→↵（器が入力欄へ委ねて `.ignored` を返す）が誰にも届かない状態になる。
  /// 行間隔は spacing でなく各スロットの leading padding で作る（隠れた入力欄が余白を生まないため）。
  private var header: some View {
    HStack(spacing: 0) {
      Text("◐")
        .font(Font.theme.title)
        .foregroundStyle(Color.theme.glyphGradient)
      // 絞り込み欄とサブメニュー文脈（設定のフォント/テーマ/カーソル色等）は併存する。
      // breadcrumb を前置しないと絞り込み中に現在地表示が消える。入力欄と併存するときは副色で控えめに、
      // 単独のときは主色で幅一杯に置く。
      if let breadcrumb = model.breadcrumb {
        Text(breadcrumb)
          .font(Font.theme.title)
          .foregroundStyle(
            model.fieldVisible ? Color.theme.textSecondary : Color.theme.textPrimary
          )
          .lineLimit(1)
          .fixedSize(horizontal: model.fieldVisible, vertical: false)
          .frame(maxWidth: model.fieldVisible ? nil : .infinity, alignment: .leading)
          .padding(.leading, Theme.Space.beat)
      }
      queryField
        .padding(.leading, model.fieldVisible ? Theme.Space.beat : 0)
        .frame(maxWidth: model.fieldVisible ? .infinity : 0)
        .opacity(model.fieldVisible ? 1 : 0)
        .allowsHitTesting(model.fieldVisible)
      // ヘッダ右端の表示専用ピル（Attention の `⌘⌘`）。opt-in（空の既存パレットは従来どおり
      // ヘッダ行だけ）。開くキーのような面の素性だけを出し、操作の案内はフッター（hint）が持つ。
      if !model.headerPills.isEmpty {
        HStack(spacing: Theme.Space.step) {
          ForEach(model.headerPills) { pill in
            Text(pill.label).foregroundStyle(Color.theme.textMuted)
          }
        }
        .font(Font.theme.meta)
        .padding(.horizontal, Theme.Space.step)
        .padding(.vertical, Theme.Space.hair)
        .background(
          RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Color.theme.smallPillFill))
      }
    }
    .padding(.horizontal, Theme.Space.span)
    .padding(.vertical, Theme.Space.bar)
  }

  /// 入力欄の双方向バインド。`onQueryChange`（＝「入力欄が編集された」）は **setter からだけ**呼ぶ。
  /// `.onChange(of: model.query)` は「値が変わった」に反応するため、パレットモデル自身の書き込み
  /// （モード遷移時に query を空へ戻す等）まで拾って再構築を誘発し、モデルが置いた選択（サブパレットの
  /// 現在値の行）を潰していた。setter ならモデル側の書き込みは getter しか通らず、跳ね返らない。
  private var queryBinding: Binding<String> {
    Binding(
      get: { model.query },
      set: { edited in
        guard edited != model.query else { return }
        model.query = edited
        model.onQueryChange()
      })
  }

  /// 絞り込み/改名の入力欄（純 SwiftUI `TextField`・裸のテキスト＝パレットのヘッダ様式）。
  private var queryField: some View {
    TextField("", text: queryBinding)
      .textFieldStyle(.plain)
      .font(Font.theme.title)
      .foregroundStyle(Color.theme.textPrimary)
      .focused($focus, equals: .field)
      // 純正 placeholder は色を握れず IME 変換中も消えないため、共通モディファイアで muted 描画しつつ
      // marked text がある間は抑制する。
      .imePlaceholder(
        model.placeholder, showWhenEmpty: model.query.isEmpty, focused: focus == .field,
        font: Font.theme.title, color: Color.theme.textMuted
      )
      .frame(maxWidth: .infinity)
      // 確定＝onSubmit（IME 変換確定の Enter では発火しない＝誤爆しない）。
      .onSubmit { model.onActivate() }
      // ↑↓＝一覧ナビ、⌘↑↓＝有効な先頭/末尾行へジャンプ、→＝ドリルイン（改名中はカーソルに委ねる）、Esc＝戻る。
      // ←＝filter 入力欄では戻る（onLeft）、editor 入力欄（改名）ではカーソル移動。
      // 矢印は単一の catch-all に集約し ⌘ 有無で分岐する（bare ハンドラが ⌘↑ を食う不確実性を構造で排除）。
      .onKeyPress { press in
        switch press.key {
        case .upArrow:
          if press.modifiers.contains(.command) { model.onJumpTop() } else { model.onUp() }
          return .handled
        case .downArrow:
          if press.modifiers.contains(.command) { model.onJumpBottom() } else { model.onDown() }
          return .handled
        default:
          return .ignored
        }
      }
      .onKeyPress(.rightArrow) { model.onRight() ? .handled : .ignored }
      .onKeyPress(.leftArrow) {
        guard model.fieldIsFilter else { return .ignored }
        model.onLeft()
        return .handled
      }
      // filter 入力欄でクエリが空のときだけ delete を継承解除（onDelete）へ回す。空欄 backspace は元々
      // no-op なので後退なく相乗りできる。非空・非 filter は TextField の backspace（文字削除）に委ねる。
      .onKeyPress(.delete) {
        guard model.fieldIsFilter, model.query.isEmpty else { return .ignored }
        model.onDelete()
        return .handled
      }
      .onKeyPress(.escape) {
        model.onEscape(); return .handled
      }
  }

  /// 1 行の描画。`customContent` があれば器（`SelectableRow`）へ直接流す（WS切替行・dormant 減光も乗せる）。無ければ `PaletteRow`。
  @ViewBuilder private func rowView(_ i: Int, _ row: PaletteModel.RowItem) -> some View {
    let selected = i == model.selected && row.enabled
    let tap: () -> Void = { model.onTapRow(i) }
    // ホバー開始で選択をその行へ追従（着色行を常に 1 つに）。モダリティ判定は hoverSelect が握る。
    let hoverEnter: () -> Void = { if row.enabled { model.hoverSelect(i) } }
    if let customContent = row.customContent {
      SelectableRow(selected: selected, action: tap, onHoverEnter: hoverEnter) { customContent }
        .opacity(row.dimmed && !selected ? Theme.Opacity.dormant : 1)
    } else {
      PaletteRow(
        title: row.label, selected: selected, showsChevron: row.chevron, kind: rowKind(row),
        inherited: row.inherited, leading: row.leading, detail: row.detail,
        trailingBadge: row.trailingBadge,
        trailing: model.rowAccessory.flatMap { $0.row == i ? $0.view : nil },
        action: tap, onHoverEnter: hoverEnter)
    }
  }

  private func rowKind(_ row: PaletteModel.RowItem) -> PaletteRow.Kind {
    if row.createStyle { return .createAction }
    if !row.enabled { return row.failure ? .failure : .info }
    return row.dimmed ? .dormant : .normal
  }
}

#if DEBUG
  /// cap＋内部スクロール＋行を狭めた見た目の検証用。18 行・チップ付き・選択は下方（onAppear の scrollTo 追従）。
  private func capPreviewModel(fieldVisible: Bool) -> PaletteModel {
    let model = PaletteModel()
    model.fieldVisible = fieldVisible
    model.placeholder = fieldVisible ? "Switch workspace / type to create" : ""
    model.hint =
      fieldVisible ? "↵ Switch/Create   → Details   esc Close" : "↵ Launch   → Details   esc Close"
    let rollups: [[(state: String, count: Int)]] = [
      [("working", 2), ("waiting", 1)], [("done", 4)], [], [("idle", 1)],
    ]
    model.rows = (0..<18).map { i in
      let name = "workspace-\(String(format: "%02d", i))"
      return .init(
        label: name, dimmed: i % 7 == 6,
        customContent: AnyView(
          WorkspaceSwitcherRow(
            name: name, rollup: rollups[i % rollups.count], path: "~/dev/\(name)")))
    }
    model.selected = 14
    return model
  }

  #Preview("PaletteCard — cap / scroll / slim") {
    // ステージ 560 − 上下 padding 24×2 ＝ カードが使える高さ（呼び出し側が窓を見る契約）。
    HStack(alignment: .top, spacing: Theme.Space.phrase) {
      PaletteCard(model: capPreviewModel(fieldVisible: true), maxHeight: 512)
      PaletteCard(model: capPreviewModel(fieldVisible: false), maxHeight: 512)
    }
    .padding(Theme.Space.phrase)
    .frame(width: 820, height: 560)
    .background(Color.theme.bgSunken)
  }
#endif
