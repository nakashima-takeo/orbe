import AppKit
import OrbeEditorCore

private typealias Size = Theme.Layout
private typealias Ink = Theme.Color
private typealias Fonts = Theme.Typography

/// スレッドの絵の部品——頭・コメント・本文・返信の行・失敗の文。
extension PrCommentPicture {
  /// 頭の右の押せる文言。
  private struct HeadControl {
    let control: PrCommentControl
    let key: L10nKey
    let enabled: Bool
  }

  /// 頭（高さ 26・左右の余白 12・間 8）: 左に「行 N」、右から「折りたたむ」か「展開」、「解決」か「解決を取り消す」、状態。
  /// 右の部品の左端を返す。
  @discardableResult
  static func header(
    _ thread: GitHubPullRequestReview.Thread, collapsed: Bool, in frame: CGRect, top: CGFloat,
    _ canvas: inout PrCommentCanvas
  ) -> CGFloat {
    let font = Fonts.editorPrThreadHead
    let height = Size.editorPrThreadHead
    let baseline = PrCommentStyle.baseline(top: top, height: height, font: font)
    let state = canvas.state
    canvas.label(
      lineLabel(state), font: font, color: Ink.editorText,
      x: frame.minX + 1 + Size.editorPrThreadPadX, baseline: baseline)
    var right = frame.maxX - 1 - Size.editorPrThreadPadX
    var controls = [
      HeadControl(
        control: .collapse, key: collapsed ? .editorPrThreadExpand : .editorPrThreadCollapse,
        enabled: true)
    ]
    if thread.isResolved, thread.canUnresolve {
      controls.append(
        HeadControl(
          control: .resolve, key: .editorPrThreadUnresolve,
          enabled: !state.isWriting && state.canSend))
    } else if !thread.isResolved, thread.canResolve {
      controls.append(
        HeadControl(
          control: .resolve, key: .editorPrThreadResolve,
          enabled: !state.isWriting && state.canSend))
    }
    for item in controls {
      let label = L10n.string(item.key, state.language)
      let width = PrCommentStyle.width(label, font)
      right -= width
      let hovered = item.enabled && state.hovered == item.control
      canvas.label(
        label, font: font,
        color: canvas.enabled(hovered ? Ink.editorText : Ink.textMuted, item.enabled),
        x: right, baseline: baseline)
      if item.enabled {
        canvas.button(item.control, CGRect(x: right - 2, y: top, width: width + 4, height: height))
      }
      right -= Size.editorPrThreadGap
    }
    let mono = Fonts.editorPrThreadStatus
    let monoBaseline = PrCommentStyle.baseline(top: top, height: height, font: mono)
    if thread.comments.contains(where: \.isPending) {
      let label = L10n.string(.editorPrThreadPending, state.language)
      right -= PrCommentStyle.width(label, mono)
      canvas.label(label, font: mono, color: Ink.editorCaution, x: right, baseline: monoBaseline)
      let dot = Size.editorPrThreadDot
      right -= Theme.Space.tick + dot
      canvas.elements.append(
        .box(
          ZoneBox(
            frame: CGRect(x: right, y: top + (height - dot) / 2, width: dot, height: dot),
            radius: .init(dot / 2), fill: Ink.editorCaution)))
    } else if thread.isResolved {
      let label = L10n.string(.editorPrThreadResolved, state.language)
      right -= PrCommentStyle.width(label, mono)
      canvas.label(label, font: mono, color: Ink.textMuted, x: right, baseline: monoBaseline)
    }
    return right
  }

  /// コメント 1 件（アバター 20 と中身の間 10。メタの行は字 11・行高 1.6、間 6）。本文は、組んだ本文の層 `body` をメタの行の
  /// 下に置く。高さを返す。
  static func comment(
    _ comment: GitHubPullRequestReview.Comment, _ body: PrCommentBody?, in frame: CGRect,
    top: CGFloat, _ canvas: inout PrCommentCanvas
  ) -> CGFloat {
    let size = Size.editorPrThreadAvatar
    let avatar = CGRect(
      x: frame.minX + 1 + Size.editorPrThreadPadX, y: top, width: size, height: size)
    canvas.elements.append(
      .box(ZoneBox(frame: avatar, radius: .init(size / 2), fill: Ink.editorGhost)))
    let initials = initials(comment.author)
    let avatarFont = Fonts.editorPrThreadAvatar
    canvas.label(
      initials, font: avatarFont, color: Ink.textPrimary,
      x: avatar.midX - PrCommentStyle.width(initials, avatarFont) / 2,
      baseline: PrCommentStyle.baseline(top: avatar.minY, height: size, font: avatarFont))
    let left = avatar.maxX + Size.editorPrThreadAvatarGap
    let metaHeight = Fonts.editorPrThreadHead.pointSize * Fonts.editorPrThreadBodyLineHeight
    meta(comment, at: CGPoint(x: left, y: top), height: metaHeight, &canvas)
    var y = top + metaHeight
    if let body {
      canvas.place(body, comment: comment.id, at: CGPoint(x: left, y: y))
      y += body.height
    }
    return max(size, y - top)
  }

  /// メタの行: 書いた人（11 semibold）・時刻（11 tertiary）・未送信の札（字 10・枠 1・角丸 3）。
  private static func meta(
    _ comment: GitHubPullRequestReview.Comment, at origin: CGPoint, height: CGFloat,
    _ canvas: inout PrCommentCanvas
  ) {
    let small = Fonts.editorPrThreadHead
    let baseline = PrCommentStyle.baseline(top: origin.y, height: height, font: small)
    var x = origin.x
    if let author = comment.author {
      canvas.label(
        author, font: Fonts.editorPrThreadAuthor, color: Ink.textPrimary, x: x,
        baseline: baseline)
      x += PrCommentStyle.width(author, Fonts.editorPrThreadAuthor) + Size.editorPrThreadMetaGap
    }
    let language = canvas.state.language
    let when = ElapsedText.ago(comment.createdAt, now: Date(), language: language)
    canvas.label(when, font: small, color: Ink.editorTertiary, x: x, baseline: baseline)
    x += PrCommentStyle.width(when, small) + Size.editorPrThreadMetaGap
    guard comment.isPending else { return }
    let badge = Fonts.editorPrThreadBadge
    let label = L10n.string(.editorPrThreadPending, language)
    let width = PrCommentStyle.width(label, badge) + 8 + 2
    canvas.elements.append(
      .box(
        ZoneBox(
          frame: CGRect(x: x, y: baseline - 11, width: width, height: 15), radius: 3,
          stroke: .init(color: Ink.editorPrPendingBorder, width: 1))))
    canvas.label(label, font: badge, color: Ink.editorCaution, x: x + 5, baseline: baseline)
  }

  /// 返信の行（高さ 26 と改行ごとに 1 行・左右の余白 12・間 8）: 返信欄と、右に `buttons`（左から順）。高さを返す。
  static func reply(
    _ field: ZoneTextField, buttons: [PrCommentControl], in frame: CGRect, top: CGFloat,
    _ canvas: inout PrCommentCanvas
  ) -> CGFloat {
    let lineHeight = field.style.lineHeight
    let control = Size.editorPrThreadControl
    let height = control + CGFloat(field.lineCount - 1) * lineHeight
    let writing = canvas.state.isWriting
    var right = frame.maxX - 1 - Size.editorPrThreadPadX
    for button in buttons.reversed() {
      let sends = button != .cancel
      let enabled =
        !writing && (!sends || canvas.state.canSend)
        && (button != .add || canvas.state.hasText)
      right -= self.button(button, enabled: enabled, right: right, top: top, &canvas)
      right -= Size.editorPrThreadGap
    }
    let left = frame.minX + 1 + Size.editorPrThreadPadX
    let input = CGRect(x: left, y: top, width: max(0, right - left), height: height)
    let focused = canvas.state.isFieldPrimary && !writing
    canvas.elements.append(
      .box(
        ZoneBox(
          frame: input, radius: 4, fill: EditorStyle.sunk(0.35),
          stroke: .init(
            color: canvas.enabled(
              focused ? Ink.editorPrFieldFocus : EditorStyle.hairline(0.10), !writing),
            width: 1))))
    let text = CGRect(
      x: input.minX + 1 + Size.editorPrThreadFieldPadX,
      y: input.minY + (control - lineHeight) / 2,
      width: max(0, input.width - 2 - Size.editorPrThreadFieldPadX * 2),
      height: CGFloat(field.lineCount) * lineHeight)
    let font = field.style.font
    if field.string.isEmpty {
      canvas.label(
        L10n.string(.editorPrThreadReplyPlaceholder, canvas.state.language), font: font,
        color: Ink.editorTertiary, x: text.minX,
        baseline: PrCommentStyle.baseline(top: text.minY, height: lineHeight, font: font))
    }
    if writing {
      // 書き込みの最中は入力欄を置かず（打てない）、本文を押せない姿の字で描く。
      for (row, string) in field.string.components(separatedBy: "\n").enumerated() {
        canvas.label(
          string, font: font, color: canvas.enabled(field.style.textColor, false), x: text.minX,
          baseline: PrCommentStyle.baseline(
            top: text.minY + CGFloat(row) * lineHeight, height: lineHeight, font: font))
      }
    } else {
      canvas.elements.append(.field(ZoneField(frame: text, field: field)))
    }
    return height
  }

  /// 返信の行のボタン 1 つ（高さ 26・左右の余白 10・角丸 4）を右端 `right` に置き、幅を返す。「レビューに追加」は accent の地、
  /// ほかは枠のボタン（ホバーで fill .06 の地）。
  private static func button(
    _ button: PrCommentControl, enabled: Bool, right: CGFloat, top: CGFloat,
    _ canvas: inout PrCommentCanvas
  ) -> CGFloat {
    let primary = button == .add
    let font = primary ? Fonts.editorPrThreadPrimaryButton : Fonts.editorPrThreadButton
    let label = L10n.string(buttonLabel(button), canvas.state.language)
    let width = PrCommentStyle.width(label, font) + Size.editorPrThreadButtonPadX * 2
    let rect = CGRect(
      x: right - width, y: top, width: width, height: Size.editorPrThreadControl)
    let baseline = PrCommentStyle.baseline(top: top, height: rect.height, font: font)
    if primary {
      canvas.elements.append(
        .box(ZoneBox(frame: rect, radius: 4, fill: canvas.enabled(Ink.accentPrimary, enabled))))
    } else {
      let hovered = enabled && canvas.state.hovered == button
      canvas.elements.append(
        .box(
          ZoneBox(
            frame: rect, radius: 4, fill: hovered ? EditorStyle.fill(0.06) : nil,
            stroke: .init(color: canvas.enabled(EditorStyle.hairline(0.12), enabled), width: 1))))
    }
    canvas.label(
      label, font: font,
      color: canvas.enabled(primary ? Ink.tabActiveText : Ink.editorText, enabled),
      x: rect.minX + Size.editorPrThreadButtonPadX, baseline: baseline)
    if enabled { canvas.button(button, rect) }
    return width
  }

  /// 置き場所の文（textMuted）。高さを返す（文が無ければ 0）。
  static func notice(in frame: CGRect, top: CGFloat, _ canvas: inout PrCommentCanvas) -> CGFloat {
    guard let notice = canvas.state.notice else { return 0 }
    return note(
      L10n.string(notice.key, canvas.state.language), color: Ink.textMuted, in: frame, top: top,
      &canvas)
  }

  /// 失敗の文（danger）。高さを返す（失敗が無ければ 0）。
  static func failure(in frame: CGRect, top: CGFloat, _ canvas: inout PrCommentCanvas) -> CGFloat {
    guard let failure = canvas.state.failure else { return 0 }
    return note(failure, color: Ink.danger, in: frame, top: top, &canvas)
  }

  /// 箱の下の 1 行の文（字 11・色 `color`。余白は返信の行と同じ 0 12 10）。高さを返す。
  static func note(
    _ text: String, color: NSColor, in frame: CGRect, top: CGFloat, _ canvas: inout PrCommentCanvas
  ) -> CGFloat {
    let font = Fonts.editorPrThreadHead
    let height = font.pointSize * Fonts.editorPrThreadBodyLineHeight
    let left = frame.minX + 1 + Size.editorPrThreadPadX
    canvas.label(
      truncated(text, font: font, width: frame.maxX - 1 - Size.editorPrThreadPadX - left),
      font: font, color: color, x: left,
      baseline: PrCommentStyle.baseline(top: top, height: height, font: font))
    return height + Size.editorPrThreadListPadY
  }

  private static func buttonLabel(_ control: PrCommentControl) -> L10nKey {
    switch control {
    case .add: .editorPrThreadAdd
    case .resolveReply: .editorPrThreadResolveReply
    default: .editorPrThreadCancel
    }
  }
}
