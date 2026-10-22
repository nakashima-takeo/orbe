import AppKit

/// 行の中身（字組みした文字とボタン）を組む。中身の同一性（`key`）が変わったときだけ呼ぶ。
extension ScmRowView {
  static func key(_ item: ScmLayout.Item, _ language: Language) -> String {
    switch item {
    case .header(let section, let count, let isOpen, let bulk):
      "h\(section)\(count)\(isOpen)\(bulk.canStageAll)\(bulk.canDiscardAll)\(language)"
    case .file(let section, let file):
      "f\(section)\(file.path)\u{0}\(file.badge)\(file.existsInWorkingTree)\(file.canStage)"
        + "\(file.canDiscard)\(language)"
    }
  }

  /// VoiceOver に渡す中身の文字列。
  static func label(_ item: ScmLayout.Item, _ language: Language) -> String {
    switch item {
    case .header(let section, let count, _, _): "\(title(section, language)), \(count)"
    case .file(_, let file): file.path
    }
  }

  static func content(_ item: ScmLayout.Item, _ language: Language, _ emoji: NSFont?) -> Content {
    switch item {
    case .header(let section, let count, let isOpen, let bulk):
      .header(header(section, count: count, isOpen: isOpen, bulk: bulk, language))
    case .file(let section, let file): .file(self.file(section, file, language, emoji))
    }
  }

  private static func title(_ section: ScmSection, _ language: Language) -> String {
    switch section {
    case .staged: L10n.string(.editorScmStaged, language)
    case .changes: L10n.string(.editorScmChanges, language)
    }
  }

  /// 子の見出し: 「ステージされている変更」はすべて解除、「変更」はすべて破棄・すべてステージ。すべて破棄・
  /// すべてステージは、入る行が無ければ押せない姿で置く（すべて解除の見出しは、行が 0 なら出ない）。
  private static func header(
    _ section: ScmSection, count: Int, isOpen: Bool, bulk: ScmLayout.Bulk, _ language: Language
  ) -> Header {
    let button = { (control: ScmControl, glyph: ScmGlyphShape, enabled: Bool, help: L10nKey) in
      Button(control: control, glyph: glyph, isEnabled: enabled, help: L10n.string(help, language))
    }
    let buttons: [Button] =
      switch section {
      case .staged: [button(.unstageAll, .minus, true, .editorScmUnstageAll)]
      case .changes:
        [
          button(.discardAll, .discard, bulk.canDiscardAll, .editorScmDiscardAll),
          button(.stageAll, .plus, bulk.canStageAll, .editorScmStageAll),
        ]
      }
    return Header(
      isOpen: isOpen,
      label: TextLine(title(section, language), Theme.Typography.editorScmSection),
      count: TextLine(count.formatted(), Theme.Typography.editorScmCount),
      buttons: buttons)
  }

  /// ファイル行: ステージ済みは ファイルを開く・ステージを解除、変更は ファイルを開く・変更を破棄・ステージ。作業ツリーに無い
  /// ファイルの「ファイルを開く」と、git が何も変えない「変更を破棄」「ステージ」は押せない姿で置く（ボタンの位置は行どうし
  /// で揃う）。
  private static func file(
    _ section: ScmSection, _ file: ScmChanges.File, _ language: Language, _ emoji: NSFont?
  ) -> File {
    let button = { (control: ScmControl, glyph: ScmGlyphShape, enabled: Bool, help: L10nKey) in
      Button(control: control, glyph: glyph, isEnabled: enabled, help: L10n.string(help, language))
    }
    let open = button(.openFile, .openFile, file.existsInWorkingTree, .editorScmOpenFile)
    let buttons =
      section == .staged
      ? [open, button(.unstage, .minus, true, .editorScmUnstage)]
      : [
        open,
        button(.discard, .discard, file.canDiscard, .editorScmDiscard),
        button(.stage, .plus, file.canStage, .editorScmStage),
      ]
    let name = (file.path as NSString).lastPathComponent
    let chip = FileChip.resolve(URL(fileURLWithPath: name))
    return File(
      chip: chip,
      chipText: TextLine(
        chip.glyph,
        Theme.Typography.editorChip(size: chip.fontSize(for: Theme.Layout.editorScmChip))),
      name: TextLine(name, Theme.Typography.editorScmFile, glyphs: .chrome(emoji: emoji)),
      directory: TextLine(
        (file.path as NSString).deletingLastPathComponent, Theme.Typography.editorScmDirectory,
        glyphs: .chrome(emoji: emoji)),
      badge: TextLine(file.badge.label, Theme.Typography.editorBadge), badgeKind: file.badge,
      buttons: buttons)
  }
}

extension GitStatus.Divergence {
  /// `↑N ↓M`（0 の側は出さない）。
  var arrows: String {
    [ahead > 0 ? "↑\(ahead)" : nil, behind > 0 ? "↓\(behind)" : nil].compactMap { $0 }
      .joined(separator: " ")
  }
}
