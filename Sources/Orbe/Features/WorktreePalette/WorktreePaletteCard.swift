import SwiftUI

/// worktree パレットのカードの焦点の宛先。一覧とベースを選ぶ画面は入力欄、clean と最新化は TextField を
/// 持たないのでカード器が受ける。
enum WorktreePaletteFocus: Hashable {
  case field, card
}

/// worktree パレットのカード本体。ヘッダ（❯＋入力欄）＋一覧では起動先とベースのバー＋
/// リスト部（可変セクション・maxHeight 380・内部スクロール）＋フッター（選択連動の ↵ の説明/エラー＋キーヒント）。
/// 器はそのままに、中身だけ list / clean / 最新化 / ベースを選ぶ の 4 モードで切り替わる。
/// 外郭は `GlassPanel(.popup, radius 14)`。入力欄のあるモードではヘッダの `TextField` にキーを集約し、
/// ↑↓/⇥/⇧⇥/esc/↵ を横取りしてフォーカス逸脱を防ぐ（`PaletteCard`/`SearchField` の field モードと同パターン）。
struct WorktreePaletteCard: View {
  @Bindable var model: WorktreePaletteModel
  @Environment(\.localization) private var l10n
  /// カード全体の高さ上限（窓に収める。WorktreePaletteOverlay が窓高から算出して渡す）。
  let maxHeight: CGFloat
  @FocusState private var focus: WorktreePaletteFocus?
  /// リスト内容の実測高（ハグ用・上限で切った値）。初期は cap にして初回の 0 collapse フラッシュを避ける。
  @State private var contentHeight: CGFloat = Self.listCap
  /// ヘッダ＋バー＋フッターの実測高（リスト cap から差し引き、カードが窓を超えないようにする）。
  @State private var chromeHeight: CGFloat = 0

  /// リスト部の内容基準の高さ上限（380）。実測高を流すリスト（一覧・ベースを選ぶ画面）が共有する。
  static let listCap: CGFloat = 380

  /// リスト部の実効高。内容にハグしつつ 380 と「窓 − chrome」の小さい方で頭打ち（超過は内部スクロール）。
  private var listHeight: CGFloat {
    let available = max(0, maxHeight - chromeHeight)
    return min(contentHeight, min(Self.listCap, available))
  }

  /// 入力欄が焦点を持つモード。
  private var hasField: Bool { model.mode == .list || model.mode == .basePicker }

  var body: some View {
    // 面/枠は popup 級（α.90・.10/.14）だが、worktree パレットの blur は panel 級（24px）・影は大型
    // フローティング（0 20 60）。level だけでは表せない組み合わせなので material/elevation を明示上書きする。
    GlassPanel(
      level: .popup, cornerRadius: 14, materialOverride: .hudWindow, elevationOverride: .panel
    ) {
      VStack(spacing: 0) {
        header
        divider
        if model.mode == .list {
          WorktreePaletteBars(model: model)
            .background(chromeProbe)
          divider
        }
        switch model.mode {
        case .list:
          list
        case .clean:
          WorktreeCleanList(model: model.clean).frame(height: listHeight)
        case .refresh:
          if let refresh = model.refresh {
            WorktreePaletteRefreshList(
              model: refresh, onConfirm: { model.confirmRefresh($0) },
              onHover: { model.hoverRefresh($0) }
            )
            .frame(height: listHeight, alignment: .top)
          }
        case .basePicker:
          if let picker = model.basePicker {
            WorktreeBasePickerList(model: picker, onConfirm: { model.confirmBasePick(at: $0) })
              .frame(height: listHeight, alignment: .top)
          }
        }
        divider
        footer
      }
    }
    .frame(maxHeight: maxHeight, alignment: .top)
    .onPreferenceChange(ChromeHeightKey.self) { chromeHeight = $0 }
    .onPreferenceChange(WorktreePaletteContentHeightKey.self) { contentHeight = $0 }
    .modifier(WorktreePaletteCardKeyCapture(model: model, focus: $focus))
    // カード内のクリックで焦点を確定し直す（汎用 PaletteCard と同じ契約。行タップ・ボタンもこの契約に
    // 乗る）。宛先はモードが決める。
    .simultaneousGesture(TapGesture().onEnded { model.focus() })
    .onChange(of: model.focusToken, initial: true) {
      focus = hasField ? .field : .card
    }
    // 先頭の欄の入力（文脈のタスクの worktree・主・PR の head）の変化を、描画の外で provider へ届ける。
    .onChange(of: model.taskInputs) { model.onTaskInputsChanged() }
  }

  /// ヘッダ／バー／フッターの実測高を合算して chrome 高に集約する probe。
  private var chromeProbe: some View {
    GeometryReader { proxy in
      Color.clear.preference(key: ChromeHeightKey.self, value: proxy.size.height)
    }
  }

  private var divider: some View {
    Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
  }

  // MARK: - ヘッダ（入力欄）

  /// 枠と ❯ は全モード共通。中身だけ切り替える。
  /// **入力欄は clean / 最新化でも mount したまま**幅 0・opacity 0 で隠す（`PaletteCard` が記録している罠と同じ——
  /// 焦点の宛先が同じ更新 pass で新規 mount されると SwiftUI は `@FocusState` を取りこぼし、
  /// first responder がカード器に残ってキーが死ぬ）。ベースを選ぶ画面も同じ 1 本を使い回す。
  ///
  /// 要素の間隔は HStack の spacing でなく各要素の leading padding が運ぶ——幅 0 で隠した入力欄も
  /// spacing を両側で消費するので、spacing に任せると `❯` と中身の間が 2 倍に開く。
  private var header: some View {
    let gap = Theme.Space.step + Theme.Space.hair
    return HStack(spacing: 0) {
      Text("❯")
        .font(Font.theme.title)
        .foregroundStyle(Color.theme.accentPrimary)
      queryField
        .frame(maxWidth: hasField ? .infinity : 0)
        .padding(.leading, gap)
        .opacity(hasField ? 1 : 0)
        .allowsHitTesting(hasField)
      switch model.mode {
      case .list:
        Spacer(minLength: Theme.Space.step)
        if let task = model.task {
          WorktreePaletteTaskBadge(task: task, onRemove: { model.clearTaskContext() })
            .padding(.leading, gap)
        }
        keyCap("⌘T").padding(.leading, gap)
      case .basePicker:
        Spacer(minLength: Theme.Space.step)
        Text(l10n.string(.worktreeCleanBack))
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .fixedSize()
          .padding(.leading, gap)
      case .clean:
        WorktreeCleanHeader(model: model.clean)
      case .refresh:
        if let refresh = model.refresh { WorktreePaletteRefreshHeader(model: refresh) }
      }
    }
    .padding(.horizontal, Theme.Space.bar)
    .padding(.vertical, Theme.Space.beat)
    .background(chromeProbe)
  }

  /// 開いたキーの札（右上の `⌘T`）。
  private func keyCap(_ text: String) -> some View {
    Text(text)
      .font(Font.theme.meta)
      .foregroundStyle(Color.theme.textMuted)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, Theme.Space.note)
      .padding(.vertical, Theme.Space.hair)
      .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Color.theme.smallPillFill))
  }

  /// 入力欄。一覧では検索と新しいブランチ名、ベースを選ぶ画面ではベースの絞り込み。設計見本の静的
  /// プロンプト＋擬似点滅カーソルは、実 `TextField` のキャレットで置き換える。
  private var queryField: some View {
    TextField("", text: queryBinding)
      .textFieldStyle(.plain)
      .font(Font.theme.title)
      .foregroundStyle(Color.theme.textPrimary)
      // キャレット/選択色を accent に固定（ヘッダ ❯ プロンプトと同じ affordance。
      // 既定のシステムアクセント任せだと Orbe の配色から浮くため明示する）。
      .tint(Color.theme.accentPrimary)
      .focused($focus, equals: .field)
      // 純正 placeholder は色を握れず IME 変換中も消えないため、共通モディファイアで muted 描画しつつ
      // marked text がある間は抑制する。
      .imePlaceholder(
        l10n.string(placeholderKey), showWhenEmpty: queryBinding.wrappedValue.isEmpty,
        focused: focus == .field, font: Font.theme.title, color: Color.theme.textMuted
      )
      .onChange(of: model.query) { model.onQueryChanged() }
      // 実行＝onSubmit（IME 変換確定の Enter では発火しない＝誤爆しない）。行タップと同じ決定 funnel。
      .onSubmit { model.submit() }
      .onKeyPress { WorktreePaletteFieldKeys.handle($0, model: model) }
  }

  /// モードに応じた入力の行き先。一覧の入力ロック中（作成中・預かった ↵ の待ち）は打鍵を握り潰す
  /// （focus は保持し、失敗後すぐ操作へ戻れる）。
  private var queryBinding: Binding<String> {
    if model.mode == .basePicker, let picker = model.basePicker {
      return Binding(get: { picker.query }, set: { picker.query = $0 })
    }
    return Binding(get: { model.query }, set: { if !model.isLocked { model.query = $0 } })
  }

  private var placeholderKey: L10nKey {
    if model.mode == .basePicker { return .worktreePaletteBaseQueryPlaceholder }
    return model.task == nil
      ? .worktreePaletteQueryPlaceholder : .worktreePaletteTaskQueryPlaceholder
  }

  // MARK: - リスト部

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        // 行は見えている分だけ生成する（件数が数百〜千を超えても ↑↓・打鍵の反応を保つ）。
        LazyVStack(alignment: .leading, spacing: 0) {
          if model.hasLoadedOnce {
            // 行 identity（row.id）＝ scrollTo の宛先。見出し・注記と item で id 名前空間を分け、
            // 見出しの並び位置と item の平坦 index が衝突して scrollTo が空振りするのを防ぐ。
            ForEach(rows) { row in
              switch row {
              case .header(_, let title): sectionLabel(title)
              case .note(_, let key): WorktreePaletteEmptyNote(text: l10n.string(key))
              case .item(let index, let item):
                WorktreePaletteRow(
                  item: item, task: model.rowTask(item), selected: index == model.selected,
                  // 行タップ（release）＝決定。↵ と同じ funnel を通り、選択移動と実行が一体で走る。
                  onTap: { model.activate(at: index) },
                  // ホバー開始＝選択の追従だけ（決定は走らない）。
                  onHoverEnter: { model.hoverSelect(index) }
                )
              }
            }
          } else {
            // 初回ロード（最初の rebuild）まで、候補行の形をした非対話プレースホルダで空フレームを埋める。
            ForEach(WorktreePaletteSkeletonRow.widths.indices, id: \.self) { index in
              WorktreePaletteSkeletonRow(barWidth: WorktreePaletteSkeletonRow.widths[index])
            }
          }
        }
        .padding(Theme.Space.note)
        .background(
          GeometryReader { geometry in
            // Lazy の内容高は未生成の行を推定で数え、スクロールで行が生成されるたびに動く。上限で切れば
            // 上限を超える件数では値が止まり、スクロールのたびにカード全体が描き直されない。
            Color.clear.preference(
              key: WorktreePaletteContentHeightKey.self,
              value: min(geometry.size.height, Self.listCap))
          }
        )
      }
      // 内容にハグしつつ cap/窓で頭打ちの実効高を与える。定高なので超過分は内部スクロールに回り、
      // 末尾行/セクションまで確実に到達できる（fixedSize だと ScrollView が内容高へ伸び切り、
      // カードが窓外へはみ出して末尾に届かなくなる）。
      .frame(height: listHeight)
      .scrollIndicators(.automatic)
      .onChange(of: model.selected) { scrollToSelection(proxy) }
      .onChange(of: listHeight) { scrollToSelection(proxy) }
      .onAppear { scrollToSelection(proxy) }
    }
  }

  /// 選択行（平坦 index）を可視域へ追従させる。狭窓・多件数でも常にハイライトが見える。
  private func scrollToSelection(_ proxy: ScrollViewProxy) {
    proxy.scrollTo(WorktreePaletteListRow.itemID(model.selected))
  }

  /// セクション見出し（選択対象外・大文字・極小・letterSpacing 1・muted）。
  private func sectionLabel(_ title: WorktreePaletteSection.Title) -> some View {
    Text(sectionTitle(title))
      .font(Font.theme.sectionLabel)
      .tracking(Theme.Typography.trackingLabel)
      .foregroundStyle(Color.theme.textMuted)
      .padding(.top, Theme.Space.step)
      .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
      .padding(.bottom, Theme.Space.hair + 1)
  }

  private func sectionTitle(_ title: WorktreePaletteSection.Title) -> String {
    switch title {
    case .newBranch: l10n.string(.worktreePaletteSectionNewBranch)
    case .worktrees(let repository):
      repository.isEmpty ? "WORKTREES" : "WORKTREES · \(repository.uppercased())"
    case .branches: "BRANCHES"
    case .worktreesAndBranches: "WORKTREES・BRANCHES"
    case .task(let number):
      number.map { l10n.format(.worktreePaletteSectionTask, "#\($0)") }
        ?? l10n.string(.worktreePaletteSectionThisTask)
    }
  }

  private var rows: [WorktreePaletteListRow] {
    var out: [WorktreePaletteListRow] = []
    var index = 0
    for section in model.visibleSections {
      if let title = section.title { out.append(.header(sectionID: section.id, title)) }
      if section.items.isEmpty, let note = section.emptyNote {
        out.append(.note(sectionID: section.id, note))
      }
      for item in section.items {
        out.append(.item(index, item))
        index += 1
      }
    }
    return out
  }

  // MARK: - フッター

  @ViewBuilder private var footer: some View {
    switch model.mode {
    case .list:
      WorktreePaletteListFooter(model: model)
        .padding(.horizontal, Theme.Space.bar)
        .padding(.vertical, Theme.Space.step + Theme.Space.hair)
        .background(chromeProbe)
    case .clean:
      WorktreeCleanFooter(
        model: model.clean, onExecute: { model.executeClean() },
        onClose: { model.exitOrCancelClean() }
      )
      .background(chromeProbe)
    case .refresh:
      if let refresh = model.refresh {
        WorktreePaletteRefreshFooter(model: refresh, targetName: model.selectedTargetName)
          .background(chromeProbe)
      }
    case .basePicker:
      if let picker = model.basePicker {
        WorktreeBasePickerFooter(model: picker)
          .padding(.horizontal, Theme.Space.bar)
          .padding(.vertical, Theme.Space.step + Theme.Space.hair)
          .background(chromeProbe)
      }
    }
  }
}

#if DEBUG
  #Preview("worktree パレット — sample") {
    let model = WorktreePaletteModel()
    model.setTargets(
      agents: [AgentCLI(command: "claude", path: "/usr/bin/claude")], defaultCommand: "claude")
    model.hasLoadedOnce = true
    model.sections = WorktreePaletteSectionBuilder.build(.designSample)
    model.restoreSelection(matching: nil)
    return ZStack {
      BackgroundGlow()
      WorktreePaletteOverlay(model: model)
    }
    .frame(width: 720, height: 560)
  }

  #Preview("worktree パレット — skeleton") {
    let model = WorktreePaletteModel()
    model.setTargets(
      agents: [AgentCLI(command: "claude", path: "/usr/bin/claude")], defaultCommand: "claude")
    return ZStack {
      BackgroundGlow()
      WorktreePaletteOverlay(model: model)
    }
    .frame(width: 720, height: 560)
  }
#endif
