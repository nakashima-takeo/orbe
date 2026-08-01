import Foundation

/// 選択行だけを適用するパッチを unified diff として再構成する。
enum PatchBuilder {

  /// 選択行（LineRef）だけを反映したパッチを再構成する。
  /// 変更を1つも含まない場合・isBinary・rename（oldPath != newPath）・hunks 空は nil。
  static func build(diff: FileDiff, selection: Set<LineRef>, direction: PatchDirection) -> String? {
    guard !diff.isBinary, !diff.isRenamed, !diff.hunks.isEmpty else { return nil }

    var hunkTexts: [String] = []
    var delta = 0  // 出力済み hunk の (newCount - oldCount) 累積
    var oldTotal = 0
    var newTotal = 0

    for (h, hunk) in diff.hunks.enumerated() {
      guard let kept = normalize(hunk, at: h, selection: selection, direction: direction)
      else { continue }

      let oldCount = kept.filter { $0.kind != .added }.count
      let newCount = kept.filter { $0.kind != .removed }.count
      // index 側に一致すべき側の開始番号は元 hunk を保持し、反対側は累積デルタで導出する。
      // count == 0 の側は「直前行」を指す慣習に合わせて 1 ずらす。
      let oldStart: Int
      let newStart: Int
      switch direction {
      case .stage:
        oldStart = hunk.oldStart
        let position = oldCount > 0 ? oldStart : oldStart + 1
        newStart = newCount > 0 ? position + delta : position + delta - 1
      case .unstage:
        newStart = hunk.newStart
        let position = newCount > 0 ? newStart : newStart + 1
        oldStart = oldCount > 0 ? position - delta : position - delta - 1
      }
      delta += newCount - oldCount
      oldTotal += oldCount
      newTotal += newCount

      var text = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
      if !hunk.sectionHeading.isEmpty { text += " \(hunk.sectionHeading)" }
      for line in kept {
        text += "\n\(prefix(line.kind))\(line.text)"
        if line.noNewlineAtEnd { text += "\n\\ No newline at end of file" }
      }
      hunkTexts.append(text)
    }
    guard !hunkTexts.isEmpty else { return nil }

    return header(diff: diff, oldTotal: oldTotal, newTotal: newTotal)
      + hunkTexts.joined(separator: "\n") + "\n"
  }

  // MARK: - 正規化

  /// 1 hunk を方向別の規則で変換する。選択変更を含まなければ nil。
  /// - stage: 非選択 removed → context（index に実在し残る）／非選択 added → 落とす
  /// - unstage: 非選択 added → context（index に実在し残る）／非選択 removed → 落とす
  private static func normalize(
    _ hunk: Hunk, at h: Int, selection: Set<LineRef>, direction: PatchDirection
  ) -> [DiffLine]? {
    var kept: [DiffLine] = []
    var hasChange = false
    for (l, line) in hunk.lines.enumerated() {
      if line.kind == .context || selection.contains(LineRef(h, l)) {
        kept.append(line)
        hasChange = hasChange || line.kind != .context
        continue
      }
      let toContext = direction == .stage ? line.kind == .removed : line.kind == .added
      if toContext {
        kept.append(
          DiffLine(
            kind: .context, text: line.text, noNewlineAtEnd: line.noNewlineAtEnd,
            oldLine: line.oldLine, newLine: line.newLine))
      }
    }
    return hasChange ? kept : nil
  }

  // MARK: - ヘッダ

  /// 変換後に /dev/null 側へ行が残った場合（削除の部分 stage・新規の部分 unstage）は
  /// 通常の変更として出力する。空のままなら new/deleted file ヘッダを付ける。
  private static func header(diff: FileDiff, oldTotal: Int, newTotal: Int) -> String {
    let path = diff.newPath ?? diff.oldPath ?? "?"
    var lines = ["diff --git a/\(path) b/\(path)"]
    if diff.oldPath == nil, oldTotal == 0 {
      lines.append("new file mode \(diff.newMode ?? "100644")")
      lines.append("--- /dev/null")
    } else {
      lines.append("--- a/\(path)")
    }
    if diff.newPath == nil, newTotal == 0 {
      lines.insert("deleted file mode \(diff.oldMode ?? "100644")", at: 1)
      lines.append("+++ /dev/null")
    } else {
      lines.append("+++ b/\(path)")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func prefix(_ kind: DiffLine.Kind) -> String {
    switch kind {
    case .context: return " "
    case .removed: return "-"
    case .added: return "+"
    }
  }
}
