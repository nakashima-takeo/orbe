import AppKit
import SwiftUI

/// タスク画面のカード本体。ヘッダー（❯＋入力欄・タブ・範囲）＋本体（左に一覧・右に詳細。GitHub タブは空）
/// ＋フッター（主な操作の 1 行・キーヒント）。焦点の行き先（入力欄 / 詳細の項目 / 詳細の編集欄）はモデルの
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
        Group {
          switch model.tab {
          case .tasks:
            HStack(spacing: 0) {
              TaskPaletteList(model: model)
              Rectangle().fill(Color.theme.surface1).frame(width: Theme.Stroke.hairline)
              TaskPaletteDetail(model: model, focus: $focus)
                .frame(width: detailWidth)
            }
          case .github:
            Color.clear
          }
        }
        .frame(maxHeight: .infinity)
        divider
        TaskPaletteFooter(model: model)
      }
    }
    // 詳細の項目に居る間はカードの器がキーを受ける。入力欄・編集欄に焦点がある間は、そこが先に受けて
    // 握らなかったキーだけがここへ来るので、器側は詳細の項目に居るときしか握らない。
    .focusable()
    .focusEffectDisabled()
    .focused($focus, equals: .card)
    .onKeyPress { model.handleCardKey($0) }
    .simultaneousGesture(TapGesture().onEnded { model.focus() })
    .onChange(of: model.focusToken, initial: true) { focus = model.focusTarget }
    // agent の変更を含む列の変化を、描画の外で付け直しへ届ける。
    .onChange(of: model.store.tasks) { model.reconcile() }
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
          l10n.string(
            model.tab == .tasks ? .taskPalettePlaceholder : .taskPaletteGitHubPlaceholder),
          showWhenEmpty: model.query.isEmpty, focused: focus == .field, font: Font.theme.title,
          color: Color.theme.textMuted
        )
        .onSubmit { model.submit() }
        .onKeyPress { model.handleFieldKey($0, composing: Self.isComposing) }
        .padding(.leading, Theme.Space.step + Theme.Space.hair)
      Spacer(minLength: Theme.Space.step)
      HStack(spacing: Theme.Space.beat) {
        TaskPaletteSegments(
          segments: [
            .init(
              title: l10n.string(.taskPaletteTabTasks), count: model.counts.scoped,
              selected: model.tab == .tasks, action: { model.setTab(.tasks) }),
            .init(
              title: "GitHub", count: nil, selected: model.tab == .github,
              action: { model.setTab(.github) }),
          ], font: Font.theme.code, height: 26, selectedFill: Color.theme.surfaceInk.opacity(0.08))
        TaskPaletteSegments(
          segments: [
            .init(
              title: l10n.string(.taskPaletteScopeAll), count: model.counts.all,
              selected: model.scope == .all, action: { model.setScope(.all) }),
            .init(
              title: model.workspaces.opened.name, count: model.counts.opened,
              selected: model.scope == .opened, action: { model.setScope(.opened) }),
          ], font: Font.theme.code, height: 26, selectedFill: Color.theme.tintAccent)
      }
      .fixedSize()
    }
    .padding(.leading, Theme.Space.phrase)
    .padding(.trailing, Theme.Space.span)
    .frame(height: 56)
  }

  /// 焦点を持つ入力欄の field editor に未確定の文字（日本語入力の変換中）があるか。キーを受けた時点で
  /// 直接確かめる（`imePlaceholder` の監視と同じ情報源）。
  static var isComposing: Bool {
    (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
  }
}

/// 切り替えの札の組（ヘッダーのタブ・範囲、詳細の選択式の値）。焦点は取らない——クリックで入力欄から
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
          .padding(.horizontal, Theme.Space.beat)
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
    .padding(3)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Color.theme.surfaceInk.opacity(0.04)))
  }
}
