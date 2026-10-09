import SwiftUI

/// タスク画面のカード本体。ヘッダー（❯＋入力欄・タブ・範囲）＋選ぶ状態の帯＋本体（左に一覧・右の欄にタスク。
/// GitHub タブは左に open な Issue・PR、右の欄に項目。受信タブは棚・提案・詳細の 3 列）＋フッター（主な操作の 1 行・キーヒント）。焦点の行き先（入力欄 / 右の欄の項目 / 右の欄の編集欄）はモデルの
/// `focusTarget` から一方向に写し、カード内のクリックでも当て直す（⌘T 画面と同じ契約）。
struct TaskPaletteCard: View {
  @Bindable var model: TaskPaletteModel
  let detailWidth: CGFloat
  @Environment(\.localization) private var l10n
  @FocusState private var focus: TaskPaletteFocusTarget?

  var body: some View {
    // 面と blur・影は ⌘T 画面と同じ（大型のフローティングカード）。
    GlassPanel(
      level: .popup, cornerRadius: 14, materialOverride: .hudWindow, elevationOverride: .panel
    ) {
      VStack(spacing: 0) {
        header
        divider
        if model.pick != nil {
          TaskPalettePickBanner(model: model)
          divider
        }
        Group {
          switch model.visibleTab {
          case .tasks:
            HStack(spacing: 0) {
              TaskPaletteList(model: model)
              Rectangle().fill(Color.theme.surface1).frame(width: Theme.Stroke.hairline)
              // 選ぶ状態の間は、右の欄からタスクを変えさせない（キーは一覧の選択だけが効く）。
              TaskPaletteDetail(model: model, focus: $focus)
                .frame(width: detailWidth)
                .allowsHitTesting(model.pick == nil)
            }
          case .github:
            HStack(spacing: 0) {
              TaskPaletteGitHubList(model: model)
              Rectangle().fill(Color.theme.surface1).frame(width: Theme.Stroke.hairline)
              TaskPaletteGitHubPane(model: model, focus: $focus)
                .frame(width: detailWidth)
            }
          case .intake:
            TaskPaletteIntakeBody(model: model.intake, detailWidth: detailWidth)
          }
        }
        .frame(maxHeight: .infinity)
        divider
        TaskPaletteFooter(model: model)
      }
    }
    // 右の欄の項目に居る間はカードの器がキーを受ける。入力欄・編集欄に焦点がある間は、そこが先に受けて
    // 握らなかったキーだけがここへ来るので、器側は右の欄の項目に居るときしか握らない。
    .focusable()
    .focusEffectDisabled()
    .focused($focus, equals: .card)
    .onKeyPress { model.handleCardKey($0) }
    .simultaneousGesture(TapGesture().onEnded { model.focus() })
    .onChange(of: model.focusToken, initial: true) { focus = model.focusTarget }
    // agent の変更を含む列の変化を、描画の外で付け直しへ届ける。
    .onChange(of: model.store.tasks) { model.reconcile() }
    // agent の状態が変わると右の欄の止まる場所（agent の場所）が増減するので、同じく付け直す。
    .onChange(of: model.agents.agents) { model.reconcile() }
    // GitHub タブの行はストア（結び付き）と一覧の置き場の両方で変わるので、行の変化でも付け直す。
    .onChange(of: model.gitHubRows) { model.reconcile() }
    // 出ている行の結び付きが増えたら（agent の変更・完了の欄の開閉・範囲・入力）、その値を取りに行く。
    .onChange(of: model.visibleLinkIDs) { model.ensureVisibleItems() }
    // 裏の回の確定や AI の変更で受信と提案が変わったら、受信タブの選択と居場所を付け直す。
    .onChange(of: model.intake.store.intakes) { model.intake.reconcile() }
    .onChange(of: model.intake.store.proposals) { model.intake.reconcile() }
  }

  private var divider: some View {
    Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
  }

  private var header: some View {
    HStack(spacing: 0) {
      Text("❯")
        .font(Font.theme.title)
        .foregroundStyle(Color.theme.accentPrimary)
      TextField("", text: $model.query)
        .textFieldStyle(.plain)
        .font(Font.theme.title)
        .foregroundStyle(Color.theme.textPrimary)
        .tint(Color.theme.accentPrimary)
        .focused($focus, equals: .field)
        .imePlaceholder(
          l10n.string(placeholderKey),
          showWhenEmpty: model.query.isEmpty, focused: focus == .field, font: Font.theme.title,
          color: Color.theme.textMuted
        )
        .onSubmitIgnoringKeyRepeat { model.submit() }
        .onKeyPress { model.handleFieldKey($0) }
        // 右の欄に居る間は入力欄自身にクリックを渡さず（渡すと焦点だけが入力欄へ移り、モデルの居場所と
        // 食い違う）、上に被せた面で受けて一覧へ戻る操作としてモデルに伝える。焦点はモデルから写る。
        .allowsHitTesting(model.focusTarget == .field)
        .overlay {
          if model.focusTarget != .field {
            Color.clear
              .contentShape(Rectangle())
              .onTapGesture { model.returnToField() }
          }
        }
        .padding(.leading, Theme.Space.step + Theme.Space.hair)
      Spacer(minLength: Theme.Space.step)
      HStack(spacing: Theme.Space.step) {
        TaskPaletteSegments(
          segments: [
            .init(
              title: l10n.string(.taskPaletteTabTasks), count: model.counts.scoped,
              selected: model.visibleTab == .tasks, action: { model.setTab(.tasks) }),
            .init(
              title: "GitHub", count: model.gitHubCount, selected: model.visibleTab == .github,
              action: { model.setTab(.github) }),
            .init(
              title: l10n.string(.taskPaletteTabIntake), count: model.intake.openCount,
              selected: model.visibleTab == .intake, action: { model.setTab(.intake) }),
          ], font: Font.theme.chrome, height: 20, selectedFill: Color.theme.surfaceInk.opacity(0.08)
        )
        // 範囲は受信に効かないので、受信タブでは出さない。
        if model.visibleTab != .intake { scopeSegments }
      }
      .fixedSize()
    }
    .padding(.horizontal, Theme.Space.span)
    .frame(height: Self.headerHeight)
  }

  private var placeholderKey: L10nKey {
    switch model.visibleTab {
    case .tasks: .taskPalettePlaceholder
    case .github: .taskPaletteGitHubPlaceholder
    case .intake: .taskPaletteIntakePlaceholder
    }
  }

  private var scopeSegments: some View {
    TaskPaletteSegments(
      segments: [
        .init(
          title: l10n.string(.taskPaletteScopeAll), count: model.counts.all,
          selected: model.scope == .all, action: { model.setScope(.all) }),
        .init(
          title: model.workspaces.opened.name, count: model.counts.opened,
          selected: model.scope == .opened, action: { model.setScope(.opened) }),
      ], font: Font.theme.chrome, height: 20, selectedFill: Color.theme.tintAccent)
  }

  /// ヘッダーの高さ。⌘⇧S のヘッダー（上下 16 ＋ 14pt の 1 行）と同じ。札の組はこの中に収まる。
  private static let headerHeight: CGFloat = 48
}

/// 切り替えの札の組（ヘッダーのタブ・範囲、右の欄の選択式の値）。焦点は取らない——クリックで入力欄から
/// 焦点を奪わない。
struct TaskPaletteSegments: View {
  struct Segment {
    let title: String
    let count: Int?
    let selected: Bool
    let action: () -> Void
  }

  let segments: [Segment]
  let font: Font
  let height: CGFloat
  let selectedFill: Color

  var body: some View {
    HStack(spacing: Theme.Space.hair) {
      ForEach(segments.indices, id: \.self) { index in
        let segment = segments[index]
        Button(action: segment.action) {
          HStack(spacing: Theme.Space.note) {
            Text(segment.title)
              .foregroundStyle(
                segment.selected ? Color.theme.textPrimary : Color.theme.textSecondary)
            if let count = segment.count {
              Text("\(count)").foregroundStyle(Color.theme.textMuted)
            }
          }
          .font(font)
          .lineLimit(1)
          .fixedSize()
          .padding(.horizontal, Theme.Space.step)
          .frame(height: height)
          .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm + Theme.Space.hair)
              .fill(segment.selected ? selectedFill : .clear)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
      }
    }
    .padding(Theme.Space.hair)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Color.theme.surfaceInk.opacity(0.04)))
  }
}

/// 選ぶ状態の帯（「#221 … を結び付けるタスクを選ぶ」「#212 … に結び付ける Issue・PR を選ぶ」）。
struct TaskPalettePickBanner: View {
  @Bindable var model: TaskPaletteModel
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      Image(systemName: "link")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.theme.accentBright)
      fontResolver.text(title, base: Theme.Typography.workspaceName)
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Theme.Space.span)
    .frame(height: TaskPaletteRowMetrics.line + Theme.Space.tick)
    .background(Color.theme.tintAccent)
  }

  private var title: String {
    switch model.pick {
    case .task(let link, _):
      let title = model.openItem(link.item)?.title
      return l10n.format(
        .taskPalettePickTask,
        ["#\(link.item.number)", title].compactMap { $0 }.joined(separator: " "))
    case .item(let id, _):
      let task = model.store.tasks.first { $0.id == id }
      let number = task?.links.first.map { "#\($0.item.number)" }
      return l10n.format(
        .taskPalettePickItem, [number, task?.title].compactMap { $0 }.joined(separator: " "))
    case nil:
      return ""
    }
  }
}
