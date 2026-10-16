import SwiftUI

/// タスク画面のカード本体。ヘッダー（❯＋入力欄・タブ）＋選ぶ状態の帯＋本体（左に絞り込みの行と表・右の欄にタスク。
/// GitHub タブは左に open な Issue・PR、右の欄に項目。提案タブは棚・提案・詳細の 3 列）＋フッター（主な操作の 1 行・
/// キーヒント）。絞り込みのメニューはカードの上に重ねる。焦点の行き先（入力欄 / 右の欄の項目 / 右の欄の編集欄）はモデルの
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
              // 入力の行き先を選んでいる間は、一覧を広く使う（右の欄に出すタスクが無い）。
              if model.selectedID != .add {
                Rectangle().fill(Color.theme.surface1).frame(width: Theme.Stroke.hairline)
                // 選ぶ状態の間は、右の欄からタスクを変えさせない（キーは一覧の選択だけが効く）。
                TaskPaletteDetail(model: model, focus: $focus)
                  .frame(width: detailWidth)
                  .allowsHitTesting(model.pick == nil)
              }
            }
          case .github:
            HStack(spacing: 0) {
              TaskPaletteGitHubList(model: model)
              Rectangle().fill(Color.theme.surface1).frame(width: Theme.Stroke.hairline)
              TaskPaletteGitHubPane(model: model, focus: $focus)
                .frame(width: detailWidth)
            }
          case .automation:
            TaskPaletteAutomationBody(model: model.automation, detailWidth: detailWidth)
          }
        }
        .frame(maxHeight: .infinity)
        divider
        TaskPaletteFooter(model: model)
      }
      .overlayPreferenceValue(TaskPaletteFilterMenuAnchor.self) { anchors in
        filterMenu(anchors)
      }
    }
    // 器は焦点がどこにあっても全キーを最初に受ける（`onKeyPress` は祖先から順に配られる）唯一の入口で、
    // モデルの `handleKey` が振り分ける。
    .focusable()
    .focusEffectDisabled()
    .focused($focus, equals: .card)
    .onKeyPress { model.handleKey($0) }
    .simultaneousGesture(TapGesture().onEnded { model.focus() })
    .onChange(of: model.focusToken, initial: true) { focus = model.focusTarget }
    // agent の変更を含むタスク一覧の変化を、描画の外で付け直しへ届ける。
    .onChange(of: model.store.tasks) { model.reconcile() }
    // agent の状態が変わると右の欄の止まる場所（agent の場所）が増減するので、同じく付け直す。
    .onChange(of: model.agents.agents) { model.reconcile() }
    // 会話のタブが増減すると右の欄の止まる場所（会話の行）が増減するので、同じく付け直す。
    .onChange(of: model.sessionTabs.tabs) { model.reconcile() }
    // GitHub タブの行はストア（結び付き）と一覧の置き場の両方で変わるので、行の変化でも付け直す。
    .onChange(of: model.gitHubRows) { model.reconcile() }
    // 出ている行の結び付きが増えたら（agent の変更・絞り込み・入力）、その値を取りに行く。
    .onChange(of: model.visibleLinkIDs) { model.ensureVisibleItems() }
    // 裏の回の確定や AI の変更で受信と提案が変わったら、提案タブの選択と居場所を付け直す。
    .onChange(of: model.automation.store.automations) { model.automation.reconcile() }
    .onChange(of: model.automation.store.proposals) { model.automation.reconcile() }
  }

  private var divider: some View {
    Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
  }

  /// 開いている絞り込みのメニューを重ねる。メニューの外のクリックはメニューを閉じるだけで、下へは届かない。
  @ViewBuilder private func filterMenu(_ anchors: [TaskPaletteFilterKind: Anchor<CGRect>])
    -> some View
  {
    if let kind = model.openFilterMenu, let anchor = anchors[kind] {
      TaskPaletteFilterMenuLayer(model: model, kind: kind, anchor: anchor)
        .id(kind)
    }
  }

  private var header: some View {
    HStack(spacing: Theme.Space.bar) {
      input
      TaskPaletteSegments(
        segments: [
          .init(
            title: l10n.string(.taskPaletteTabTasks), count: model.counts.undone,
            selected: model.visibleTab == .tasks, action: { model.setTab(.tasks) }),
          .init(
            title: "GitHub", count: model.gitHubCount, selected: model.visibleTab == .github,
            action: { model.setTab(.github) }),
          .init(
            title: l10n.string(.taskPaletteTabAutomation), count: model.automation.openCount,
            selected: model.visibleTab == .automation, action: { model.setTab(.automation) }),
        ], font: Font.theme.chrome, height: 20, selectedFill: Color.theme.surfaceInk.opacity(0.08)
      )
      .fixedSize()
    }
    .padding(.horizontal, Theme.Space.beat)
    .frame(height: Self.headerHeight)
  }

  /// ❯＋入力欄。打っている間（入力の行き先がある間）は箱に淡い地を敷き、右端に「↵ タスクに追加」「⌘↵ agent に
  /// 任せる」を出す。「↵」は入力の行き先を選んでいる間だけ光る。
  private var input: some View {
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
      if model.addTitle != nil {
        HStack(spacing: Theme.Space.beat) {
          TaskPaletteInputAction(
            key: "↵", label: l10n.string(.taskPaletteAddToTasks), lit: model.selectedID == .add,
            action: { model.tapRow(.add) })
          TaskPaletteInputAction(
            key: "⌘↵", label: l10n.string(.taskPaletteHandToAgent), lit: false,
            action: { model.askWithQuery() })
        }
        .fixedSize()
        .padding(.leading, Theme.Space.step)
      }
    }
    .padding(.horizontal, Theme.Space.step)
    .frame(height: Self.inputHeight)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(model.addTitle != nil ? Color.theme.surfaceInk.opacity(0.04) : .clear)
    )
  }

  private var placeholderKey: L10nKey {
    switch model.visibleTab {
    case .tasks: .taskPalettePlaceholder
    case .github: .taskPaletteGitHubPlaceholder
    case .automation: .taskPaletteAutomationPlaceholder
    }
  }

  /// ヘッダーの高さ。⌘⇧S のヘッダー（上下 16 ＋ 14pt の 1 行）と同じ。札の組はこの中に収まる。
  private static let headerHeight: CGFloat = 48
  /// 入力欄の背景の高さ（打っている間に地を敷く範囲）。
  private static let inputHeight: CGFloat = 34
}

/// 絞り込みのメニューを、開いた時点のドロップダウンの直下に置き、カードの下端の手前までに収める。開いている間は
/// 位置を動かさない——値をオンにすると表記が伸びてドロップダウンが折り返すので、追うとメニューが押した場所から
/// 逃げ、続けて選ぶクリックがメニューの外に当たって閉じてしまう。
private struct TaskPaletteFilterMenuLayer: View {
  @Bindable var model: TaskPaletteModel
  let kind: TaskPaletteFilterKind
  let anchor: Anchor<CGRect>
  @State private var pinned: CGPoint?

  var body: some View {
    GeometryReader { proxy in
      let chip = proxy[anchor]
      let origin = pinned ?? CGPoint(x: chip.minX, y: chip.maxY + Theme.Space.tick)
      ZStack(alignment: .topLeading) {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture { model.closeFilterMenu() }
        TaskPaletteFilterMenu(
          model: model, kind: kind,
          maxHeight: max(0, proxy.size.height - origin.y - Theme.Space.beat)
        )
        .offset(x: origin.x, y: origin.y)
      }
      .onAppear { pinned = origin }
    }
  }
}

/// 入力欄のキーの案内（「↵ タスクに追加」「⌘↵ agent に任せる」）。キーは枠で囲み、光っている間は accent の
/// 枠。クリックで効く。焦点は取らない。
struct TaskPaletteInputAction: View {
  let key: String
  let label: String
  let lit: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Theme.Space.note) {
        Text(key)
          .foregroundStyle(lit ? Color.theme.accentBright : Color.theme.textSecondary)
          .padding(.horizontal, Theme.Space.tick)
          .frame(minWidth: 18, minHeight: 18)
          .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
              .strokeBorder(
                lit ? Color.theme.accentPrimary : Color.theme.surface2,
                lineWidth: Theme.Stroke.hairline)
          )
        Text(label).foregroundStyle(lit ? Color.theme.textPrimary : Color.theme.textSecondary)
      }
      .font(Font.theme.chrome)
      .lineLimit(1)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
  }
}

/// 切り替えの札の組（ヘッダーのタブ、右の欄の選択式の値）。焦点は取らない——クリックで入力欄から
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
