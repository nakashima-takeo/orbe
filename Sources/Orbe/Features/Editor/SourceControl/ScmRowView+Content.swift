import AppKit

/// 行の中身（字組みした文字とボタン）を組む。中身の同一性（`key`）が変わったときだけ呼ぶ。
extension ScmRowView {
  static func key(_ item: ScmLayout.Item, _ language: Language) -> String {
    switch item {
    case .header(let section, let count, let isOpen): "h\(section)\(count)\(isOpen)\(language)"
    case .file(let section, let file):
      "f\(section)\(file.path)\u{0}\(file.badge)\(file.existsInWorkingTree)\(language)"
    case .branch(let branch):
      "b\(branch.label)\u{0}\(branch.divergence?.arrows ?? "")"
    case .commit(let commit, let isFirst, let isLast):
      "c\(commit.oid)\(commit.isPushed)\(isFirst)\(isLast)\(commit.localBranches)\(commit.remoteBranches)"
    case .more: "m\(language)"
    }
  }

  /// VoiceOver に渡す中身の文字列。
  static func label(_ item: ScmLayout.Item, _ language: Language) -> String {
    switch item {
    case .header(let section, let count, _):
      section == .graph ? title(section, language) : "\(title(section, language)), \(count)"
    case .file(_, let file): file.path
    case .branch(let branch): branch.label
    case .commit(let commit, _, _): commit.subject
    case .more: L10n.string(.editorScmShowMore, language)
    }
  }

  static func content(_ item: ScmLayout.Item, _ language: Language, _ emoji: NSFont?) -> Content {
    switch item {
    case .header(let section, let count, let isOpen):
      .header(header(section, count: count, isOpen: isOpen, language))
    case .file(let section, let file): .file(self.file(section, file, language, emoji))
    case .branch(let branch):
      .branch(
        Branch(
          name: TextLine(
            branch.label, Theme.Typography.editorScmBranch, glyphs: .chrome(emoji: emoji)),
          divergence: branch.divergence.map(\.arrows).flatMap {
            $0.isEmpty ? nil : TextLine($0, Theme.Typography.editorScmBranch)
          }))
    case .commit(let commit, let isFirst, let isLast):
      .commit(
        Commit(
          subject: TextLine(
            commit.subject, Theme.Typography.editorScmCommit, glyphs: .chrome(emoji: emoji)),
          isPushed: commit.isPushed, isFirst: isFirst, isLast: isLast,
          refs: commit.localBranches.map { (TextLine($0, Theme.Typography.editorScmRef), true) }
            + commit.remoteBranches.map { (TextLine($0, Theme.Typography.editorScmRef), false) }))
    case .more:
      .more(TextLine(L10n.string(.editorScmShowMore, language), Theme.Typography.editorScmMore))
    }
  }

  private static func title(_ section: ScmSection, _ language: Language) -> String {
    switch section {
    case .staged: L10n.string(.editorScmStaged, language)
    case .changes: L10n.string(.editorScmChanges, language)
    case .graph: L10n.string(.editorScmGraph, language)
    }
  }

  /// 区分見出し: 「ステージされている変更」はすべて解除、「変更」はすべて破棄・すべてステージ、グラフは再読込。
  private static func header(
    _ section: ScmSection, count: Int, isOpen: Bool, _ language: Language
  ) -> Header {
    let button = { (control: ScmControl, glyph: ScmGlyphShape, help: L10nKey) in
      Button(control: control, glyph: glyph, isEnabled: true, help: L10n.string(help, language))
    }
    let buttons: [Button] =
      switch section {
      case .staged: [button(.unstageAll, .minus, .editorScmUnstageAll)]
      case .changes:
        [
          button(.discardAll, .discard, .editorScmDiscardAll),
          button(.stageAll, .plus, .editorScmStageAll),
        ]
      case .graph: [button(.refreshGraph, .refresh, .editorScmRefresh)]
      }
    return Header(
      section: section, isOpen: isOpen,
      label: TextLine(title(section, language), Theme.Typography.editorScmSection),
      count: section == .graph ? nil : TextLine(count.formatted(), Theme.Typography.editorScmCount),
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
