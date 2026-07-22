import SwiftUI

/// フルウィンドウ overlay。strong scrim（暗幕＋blur）＋上端 54px アンカーの Dispatch カード。
/// カード幅= min(640, 窓幅−32)。scrim タップで閉じる。
struct DispatchOverlay: View {
  @Bindable var model: DispatchPaletteModel

  /// カード上端の窓上端からの距離・カードの基準幅（Dispatch 専用。汎用 PaletteOverlay の 66/560 とは別値）。
  private let topAnchor: CGFloat = 54
  private let cardWidth: CGFloat = 640

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .top) {
        Scrim(strength: .strong)
          .contentShape(Rectangle())
          // 作成中は scrim タップも握り潰す（キーの Esc 閉じと同様。ここが抜けると作成中にカード外を
          // クリックで palette が閉じ、completion が palette 消失で取りこぼされ worktree が孤児化する）。
          .onTapGesture { if !model.isPreparing { model.onDismiss() } }
        // カードは窓に収める（高さ上限＝窓高 − 70 相当）。上端アンカー＋下端に bar 分の
        // 余白を残した高さを上限に渡し、内部でリスト部が縮んで内部スクロールへ回る。
        DispatchCard(
          model: model,
          maxHeight: max(0, geo.size.height - topAnchor - Theme.Space.bar)
        )
        .frame(width: min(cardWidth, geo.size.width - Theme.Space.bar * 2))
        .padding(.top, topAnchor)
        .frame(maxWidth: .infinity, alignment: .top)
      }
    }
    .ignoresSafeArea()
    // 実マウス移動（NSEvent .mouseMoved）だけを拾ってモダリティを .pointer に落とす透明レイヤ
    // （汎用 PaletteOverlay と同じ機構）。スクロールで行がカーソル下を横切る SwiftUI onHover と違い、
    // mouseMoved は物理移動でのみ出るため、キー操作中の選択奪取が起きない。
    .overlay(MouseMovedDetector { model.inputModality = .pointer })
  }
}

/// Dispatch のカード本体。ヘッダ（❯＋絞り込み入力欄＋起動 agent チップ）＋
/// リスト部（可変セクション・maxHeight 380・内部スクロール）＋フッター（選択連動の実行説明/エラー＋キーヒント）。
/// 外郭は `GlassPanel(.popup, radius 14)`。ヘッダの `TextField` にキーを集約し、↑↓/⇥/esc/↵/⌘↵ を横取りして
/// フォーカス逸脱を防ぐ（`PaletteCard`/`SearchField` の field モードと同パターン）。
struct DispatchCard: View {
  @Bindable var model: DispatchPaletteModel
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver
  /// カード全体の高さ上限（窓に収める。DispatchOverlay が窓高から算出して渡す）。
  let maxHeight: CGFloat
  @FocusState private var fieldFocused: Bool
  /// リスト内容の実測高（ハグ用）。初期は cap にして初回の 0 collapse フラッシュを避ける。
  @State private var contentHeight: CGFloat = 380
  /// ヘッダ＋フッターの実測高（リスト cap から差し引き、カードが窓を超えないようにする）。
  @State private var chromeHeight: CGFloat = 0

  /// リスト部の内容基準の高さ上限（380・コンポーネント局所定数）。
  private let listCap: CGFloat = 380

  /// 初回ロード中スケルトンの名前バー幅（行ごとに変え均一ブロックに見せない・要素数＝行数）。
  private static let skeletonWidths: [CGFloat] = [260, 200, 300, 170, 240, 190, 220]

  /// リスト部の実効高。内容にハグしつつ 380 と「窓 − chrome」の小さい方で頭打ち（超過は内部スクロール）。
  private var listHeight: CGFloat {
    let available = max(0, maxHeight - chromeHeight)
    return min(contentHeight, min(listCap, available))
  }

  var body: some View {
    // 面/枠は popup 級（α.90・.10/.14）だが、Dispatch の blur は panel 級（24px）・影は大型
    // フローティング（0 20 60）。level だけでは表せない組み合わせなので material/elevation を明示上書きする。
    GlassPanel(
      level: .popup, cornerRadius: 14, materialOverride: .hudWindow, elevationOverride: .panel
    ) {
      VStack(spacing: 0) {
        header
        divider
        list
        divider
        footer
      }
    }
    .frame(maxHeight: maxHeight, alignment: .top)
    .onPreferenceChange(DispatchChromeHeightKey.self) { chromeHeight = $0 }
    .onChange(of: model.focusToken, initial: true) { fieldFocused = true }
  }

  /// ヘッダ／フッターの実測高を合算して chrome 高に集約する probe。
  private var chromeProbe: some View {
    GeometryReader { proxy in
      Color.clear.preference(key: DispatchChromeHeightKey.self, value: proxy.size.height)
    }
  }

  private var divider: some View {
    Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
  }

  // MARK: - ヘッダ（絞り込み入力欄）

  private var header: some View {
    HStack(spacing: Theme.Space.step + Theme.Space.hair) {
      Text("❯")
        .font(Font.theme.title)
        .foregroundStyle(Color.theme.accentPrimary)
      queryField
      Spacer(minLength: Theme.Space.step)
      targetChip
    }
    .padding(.horizontal, Theme.Space.bar)
    .padding(.vertical, Theme.Space.beat)
    .background(chromeProbe)
  }

  /// 絞り込み入力欄。設計見本の静的「agent」ラベル＋擬似点滅カーソルは、実 `TextField` のキャレットで置き換える。
  private var queryField: some View {
    // 作成中は検索入力を受け付けない（keystroke を握り潰す）。focus は保持し、失敗後すぐ操作へ戻れる。
    TextField(
      "", text: Binding(get: { model.query }, set: { if !model.isPreparing { model.query = $0 } })
    )
    .textFieldStyle(.plain)
    .font(Font.theme.title)
    .foregroundStyle(Color.theme.textPrimary)
    // キャレット/選択色を accent に固定（ヘッダ ❯ プロンプトと同じ affordance。
    // 既定のシステムアクセント任せだと Orbe の配色から浮くため明示する）。
    .tint(Color.theme.accentPrimary)
    .focused($fieldFocused)
    // 純正 placeholder は色を握れず IME 変換中も消えないため、共通モディファイアで muted 描画しつつ
    // marked text がある間は抑制する。
    .imePlaceholder(
      l10n.string(.dispatchQueryPlaceholder), showWhenEmpty: model.query.isEmpty,
      focused: fieldFocused, font: Font.theme.title, color: Color.theme.textMuted
    )
    .frame(maxWidth: .infinity)
    .onChange(of: model.query) { model.onQueryChanged() }
    // 実行＝onSubmit（IME 変換確定の Enter では発火しない＝誤爆しない）。行タップと同じ決定 funnel。
    .onSubmit { model.activate() }
    // ↑↓＝一覧ナビ、⌘↑↓＝対話行の先頭/末尾へジャンプ、⇥＝agent 巡回（握らないとフォーカスが抜けキーが死ぬ）、esc＝閉じる。
    // 矢印は単一の catch-all に集約し ⌘ 有無で分岐する（bare ハンドラが ⌘↑ を食う不確実性を構造で排除）。
    // 作成中はいずれも握り潰す（選択移動・ジャンプ・agent 変更・閉じ＝キャンセルをさせず完了まで待つ）。
    .onKeyPress { press in
      switch press.key {
      case .upArrow:
        if !model.isPreparing {
          if press.modifiers.contains(.command) { model.jump(-1) } else { model.move(-1) }
        }
        return .handled
      case .downArrow:
        if !model.isPreparing {
          if press.modifiers.contains(.command) { model.jump(1) } else { model.move(1) }
        }
        return .handled
      default:
        return .ignored
      }
    }
    .onKeyPress(.tab) {
      if !model.isPreparing { model.cycleTarget() }
      return .handled
    }
    .onKeyPress(.escape) {
      if !model.isPreparing { model.onDismiss() }
      return .handled
    }
    // ⌘↵＝issue/PR をブラウザで開く。plain ↵（onSubmit）と修飾で分ける（SearchField と同流儀）。
    .onKeyPress { press in
      guard press.key == .return, press.modifiers.contains(.command) else { return .ignored }
      guard !model.isPreparing else { return .handled }
      if let item = model.selectedItem, item.canOpenWeb { model.onOpenWeb(item) }
      return .handled
    }
  }

  /// 起動先のチップ（⇥ で巡回・agent は raw command／shell は "shell"）。targets は常に非空。
  private var targetChip: some View {
    HStack(spacing: Theme.Space.note) {
      Text("◐")
        .foregroundStyle(Color.theme.glyphGradient)
      Text(l10n.format(.dispatchAgentOpen, model.selectedTargetName))
        .foregroundStyle(Color.theme.accentPrimary)
    }
    .font(Font.theme.meta)
    .lineLimit(1)
    .fixedSize()
    .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
    .padding(.vertical, Theme.Space.hair + 1)
    .background(Capsule().fill(Color.theme.tintAccent))
  }

  // MARK: - リスト部

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if model.hasLoadedOnce {
            // 行 identity（row.id）＝ scrollTo の宛先。header と item で id 名前空間を分け（"header:"/"item:"）、
            // 見出しの並び位置と item の平坦 index が衝突して scrollTo が空振りするのを防ぐ。
            ForEach(rows) { row in
              switch row {
              case .header(let title): sectionLabel(title)
              case .item(let index, let item):
                if item.isInteractive {
                  DispatchRow(
                    item: item, selected: index == model.selected,
                    // 行タップ（release）＝決定。↵ と同じ funnel を通り、選択移動と実行が一体で走る。
                    onTap: { model.activate(at: index) },
                    // ホバー開始＝選択の追従だけ（決定は走らない）。非対話行は DispatchInfoRow へ
                    // 分岐してこの経路を通らず、モデル側の関門でも弾かれる。
                    onHoverEnter: { model.hoverSelect(index) },
                    onOpenWeb: item.canOpenWeb ? { model.onOpenWeb(item) } : nil
                  )
                } else {
                  DispatchInfoRow(item: item)
                }
              }
            }
          } else {
            // 初回ロード（最初の rebuild）まで、候補行の形をした非対話プレースホルダで空フレームを埋める。
            ForEach(Array(Self.skeletonWidths.enumerated()), id: \.offset) { _, width in
              DispatchSkeletonRow(barWidth: width)
            }
          }
        }
        .padding(Theme.Space.note)
        .background(
          GeometryReader { geometry in
            Color.clear.preference(key: DispatchContentHeightKey.self, value: geometry.size.height)
          }
        )
      }
      // 内容にハグしつつ cap/窓で頭打ちの実効高を与える。定高なので超過分は内部スクロールに回り、
      // 末尾行/セクションまで確実に到達できる（fixedSize だと ScrollView が内容高へ伸び切り、
      // カードが窓外へはみ出して末尾に届かなくなる）。
      .frame(height: listHeight)
      .scrollIndicators(.automatic)
      .onPreferenceChange(DispatchContentHeightKey.self) { contentHeight = $0 }
      .onChange(of: model.selected) { scrollToSelection(proxy) }
      .onChange(of: listHeight) { scrollToSelection(proxy) }
      .onAppear { scrollToSelection(proxy) }
    }
  }

  /// 選択行（平坦 index）を可視域へ追従させる。狭窓・多件数でも常にハイライトが見える。
  private func scrollToSelection(_ proxy: ScrollViewProxy) {
    proxy.scrollTo(DispatchListRow.itemID(model.selected))
  }

  /// セクション見出し（選択対象外・大文字・極小・letterSpacing 1・muted）。
  private func sectionLabel(_ title: String) -> some View {
    Text(title.uppercased())
      .font(Font.theme.sectionLabel)
      .tracking(Theme.Typography.trackingLabel)
      .foregroundStyle(Color.theme.textMuted)
      .padding(.top, Theme.Space.step)
      .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
      .padding(.bottom, Theme.Space.hair + 1)
  }

  private var rows: [DispatchListRow] {
    var out: [DispatchListRow] = []
    var index = 0
    for section in model.visibleSections {
      out.append(.header(section.title))
      for item in section.items {
        out.append(.item(index, item))
        index += 1
      }
    }
    return out
  }

  // MARK: - フッター

  private var footer: some View {
    HStack(spacing: Theme.Space.step) {
      // 説明は 1 つの Text に連結して単位で truncate（狭幅で個々に折り返して崩れるのを防ぐ）。
      description
        .font(Font.theme.meta)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: Theme.Space.step)
      // 作成中は操作が無効なのでキーヒントも出さない（効かない案内を残さない＝UI が嘘をつかない）。
      if !model.isPreparing {
        keyHints
          .layoutPriority(1)  // 狭幅ではキーヒントを残し説明側を truncate
      }
    }
    .padding(.horizontal, Theme.Space.bar)
    .padding(.vertical, Theme.Space.step + Theme.Space.hair)
    .background(chromeProbe)
  }

  @ViewBuilder private var description: some View {
    if model.isPreparing {
      // 作成中は左端の `↵` を出さず、gh「読み込み中…」行と同語彙の working スピナ＋muted ラベルのみ。
      HStack(spacing: Theme.Space.note) {
        StatusGlyphView(kind: .working, size: 10)
        Text(l10n.string(.dispatchPreparing)).foregroundStyle(Color.theme.textMuted)
      }
    } else if let error = model.errorMessage {
      Text(error).foregroundStyle(Color.theme.danger)
    } else if let item = model.selectedItem, let footer = item.footer {
      Text("↵ ").foregroundStyle(Color.theme.textMuted)
        + fontResolver.text(footer.target, base: Theme.Typography.meta)
        .foregroundStyle(Color.theme.textPrimary)
        + Text(" " + l10n.string(footer.kind.prepositionKey) + " ")
        .foregroundStyle(Color.theme.textMuted)
        + Text(model.selectedTargetName).foregroundStyle(Color.theme.accentPrimary)
        + Text(" " + l10n.string(.dispatchLaunchSuffix)).foregroundStyle(Color.theme.textMuted)
    }
  }

  private var keyHints: some View {
    HStack(spacing: Theme.Space.step + Theme.Space.hair) {
      keyHint("↑↓", l10n.string(.dispatchHintSelect))
      keyHint("⇥", l10n.string(.dispatchHintAgent))
      if model.selectedItem?.canOpenWeb == true { keyHint("⌘↵", l10n.string(.dispatchHintOpen)) }
      keyHint("esc", l10n.string(.dispatchHintClose))
    }
    .font(Font.theme.sectionLabel)
    .foregroundStyle(Color.theme.textMuted)
    .fixedSize()
  }

  private func keyHint(_ key: String, _ label: String) -> some View {
    HStack(spacing: Theme.Space.tick) {
      Text(key).foregroundStyle(Color.theme.textPrimary)
      Text(label)
    }
  }
}

#if DEBUG
  #Preview("Dispatch — sample") {
    let model = DispatchPaletteModel()
    model.setTargets(
      agents: [AgentCLI(command: "claude", path: "/usr/bin/claude")], defaultCommand: "claude")
    model.sections = DispatchSectionBuilder.build(.designSample)
    model.hasLoadedOnce = true
    return ZStack {
      BackgroundGlow()
      DispatchOverlay(model: model)
    }
    .frame(width: 720, height: 560)
  }

  #Preview("Dispatch — preparing") {
    let model = DispatchPaletteModel()
    model.setTargets(
      agents: [AgentCLI(command: "claude", path: "/usr/bin/claude")], defaultCommand: "claude")
    model.sections = DispatchSectionBuilder.build(.designSample)
    model.hasLoadedOnce = true
    model.isPreparing = true
    return ZStack {
      BackgroundGlow()
      DispatchOverlay(model: model)
    }
    .frame(width: 720, height: 560)
  }

  #Preview("Dispatch — skeleton") {
    let model = DispatchPaletteModel()
    model.setTargets(
      agents: [AgentCLI(command: "claude", path: "/usr/bin/claude")], defaultCommand: "claude")
    return ZStack {
      BackgroundGlow()
      DispatchOverlay(model: model)
    }
    .frame(width: 720, height: 560)
  }
#endif
