import Foundation
import OrbeEditorCore

/// 行を追う欄の置き場所——欄の絵の差し込みと、欄の起点（書きかけの欄の位置。書き換えない）と、起点から diff が見せている
/// 両端へ導いた行の範囲。新しいコメントの欄と、返信の書きかけを持ったまま今の diff に置けなくなったスレッドが使う。
///
/// diff が見せている両端（マージベースか PR の先頭のコミット）が替わるたびに、起点から範囲を導き直す（前に導いた範囲から継ぎ足さ
/// ない）。導き方は次のとおり。起点の範囲が覆う行（側ごとの区間。起点の両側の本文で出す）を、その側の起点の本文と見せている
/// 本文の行差分に掛ける。区間に掛かる変更区間が 1 つも無ければ、区間を丸ごと同じ分だけずらした範囲へ導き、1 つでも在れば（両端か
/// 間の行が書き換えられた・消された、区間の内側に行が足された）「行が無くなった」とする（GitHub が push の後にスレッドの行を
/// 新しい版へ付け替え、変わった行のスレッドを古い版のものとするのと同じ考え方）。導いた範囲の両端が、コメントできる行の同じまとまりに入らないとき
/// も行が無くなったとする。行が無くなった欄は閉じずに、終わりの行について決めた行（変更区間の中ならその区間の新しい側の終わりの
/// 行、まとまりに入らないだけなら導いた終わりの行）の下に置き、書きかけを残す（`isGone`）。行が無くなったかも導くたびに決め
/// 直すので、後の版で行が戻れば欄も戻る。導き始めてから、導いた範囲がまとまりに入るかを確かめ終えるまでは `isMoving` が立ち、
/// 絵の差し込みの `isLineMoving` にも写す（書き込みのボタンを押せない姿にする）。導いている間、欄は前に導いた範囲（初めは起点の
/// 範囲）の終わりの行の下に出たまま。
@MainActor
final class PrCommentPlacement {
  let zone: PrCommentZone
  /// 欄の起点（書き換えない）。
  let origin: PullRequestState.CommentSpot
  /// 欄を置く範囲（その側の版の行。0 始まり）。欄は終わりの行の下に置く。
  private(set) var range: DiffLineRange
  /// `range` を導いた両端（初めは起点の両端）。
  private(set) var ends: PullRequestState.DiffEnds
  /// 起点から行差分で導いたときに、範囲の行が変更区間に掛かった。
  private var isInChange = false
  /// 行差分を裏で取っている両端。
  private var computing: PullRequestState.DiffEnds?
  /// 範囲の行が今の版に無い（書き換えられた・消された・まとまりに入らない）。
  private(set) var isGone = false
  /// 範囲を導き始めてから、導いた範囲がまとまりに入るかを確かめ終えるまで。
  private(set) var isMoving = true {
    didSet { zone.isLineMoving = isMoving }
  }

  /// 起点 `origin` の欄。コメントできる行だと確かめるまでは送れない姿。
  init(zone: PrCommentZone, origin: PullRequestState.CommentSpot) {
    self.zone = zone
    self.origin = origin
    range = origin.range
    ends = origin.ends
    zone.isLineMoving = true
  }

  /// 欄を置く側（終わりの行の側）。
  var version: DiffRows.Version { range.end.version }

  /// 範囲を導き終え、まとまりに入るかも確かめ終えた（裏の仕事が残っていない）。
  var isSettled: Bool { !isMoving }

  /// diff が両端 `ends`（両側の本文 `shown`）を見せている今に合わせる——範囲を導いた両端と違えば、導いている最中でない限り起点
  /// から導き始め（導き終えたら `done` を呼ぶ）、同じ両端なら、コメントできる行のまとまり `commentable`（求め終えていれば）で
  /// 導いた範囲を確かめる。導いている間は、次の両端が来ても新しく導き始めない（導き終えた後の `done` からの呼び直しで追う）。
  func follow(
    _ ends: PullRequestState.DiffEnds, shown: EditorDiff.SideTexts,
    commentable: DiffRows.CommentHunks?, done: @escaping () -> Void
  ) {
    if ends != self.ends {
      if computing == nil { derive(ends, shown: shown, done: done) }
    } else if let commentable {
      settle(commentable: commentable)
    }
  }

  /// 起点の範囲を、diff の両端 `ends` の版（両側の本文 `shown`）での範囲へ導く。行差分は本文の大きさに比例するので裏で取る。
  private func derive(
    _ ends: PullRequestState.DiffEnds, shown: EditorDiff.SideTexts, done: @escaping () -> Void
  ) {
    computing = ends
    isMoving = true
    let (origin, limit) = (origin, EditorDiff.hunkLimit)
    Task.detached(priority: .userInitiated) { [weak self] in
      let target = Self.target(of: origin.range, from: origin.basis, to: shown, limit: limit)
      await MainActor.run { [weak self] in
        guard let self else { return }
        computing = nil
        self.ends = ends
        range = target.range
        zone.lines = GitHubLineRange(target.range)
        isInChange = target.isGone
        if target.isGone {
          isGone = true
          isMoving = false
        }
        done()
      }
    }
  }

  /// 導いた範囲の行が変更区間に掛かったか、両端がコメントできる行のまとまり `commentable` の同じまとまりに入らなければ、行が
  /// 無くなったとし、そうでなければ行が在るとする。確かめ終えたら、導いている姿を下ろす。行差分を取っている間は何もしない。
  private func settle(commentable: DiffRows.CommentHunks) {
    guard computing == nil else { return }
    isMoving = false
    isGone = isInChange || !commentable.holds(range)
  }

  /// 本文 `from`（起点の両側）の範囲 `range` の、本文 `to`（見せている両側）での範囲。範囲が覆う行（`from` の両側の行差分で
  /// 出す）を側ごとに `from` から `to` への行差分に掛け、どれかの区間に変更区間が掛かれば、行は無くなったとし、終わりの行に
  /// ついて決めた行（変更区間の中ならその区間の新しい側の終わりの行。区間が新しい側に行を持たなければその前の行）の 1 行の範囲を
  /// 返す。掛からなければ、両端を、その側のずれの分だけずらした範囲。使う側の本文が無ければ、終わりの行の側の先頭の行で、行は
  /// 無くなったとする。
  nonisolated static func target(
    of range: DiffLineRange, from: EditorDiff.SideTexts, to: EditorDiff.SideTexts,
    limit: LineDiff.Limit
  ) -> (range: DiffLineRange, isGone: Bool) {
    let end = range.end
    let one = { (line: Int) in
      DiffLineRange(start: nil, end: DiffLine(version: end.version, line: line))
    }
    let text = { (texts: EditorDiff.SideTexts, version: DiffRows.Version) in
      version == .old ? texts.old : texts.new
    }
    var covered = DiffRows.coveredLines(of: range, [])
    if range.first.version != end.version {
      guard let old = from.old, let new = from.new else { return (one(0), true) }
      covered = DiffRows.coveredLines(
        of: range, DiffRows.hunks(old: TextRope(old), new: TextRope(new), limit: limit))
    }
    var shifts: [DiffRows.Version: Int] = [:]
    var endHunks: [LineHunk] = []
    var isGone = false
    for version in [DiffRows.Version.old, .new] {
      let lines = version == .old ? covered.old : covered.new
      guard !lines.isEmpty else { continue }
      guard let before = text(from, version), let after = text(to, version) else {
        return (one(0), true)
      }
      let hunks = DiffRows.hunks(old: TextRope(before), new: TextRope(after), limit: limit)
      if version == end.version { endHunks = hunks }
      if let shift = shift(of: lines, hunks) { shifts[version] = shift } else { isGone = true }
    }
    guard !isGone else { return (one(nearest(end.line, endHunks)), true) }
    let moved = { (line: DiffLine) in
      DiffLine(version: line.version, line: line.line + (shifts[line.version] ?? 0))
    }
    return (DiffLineRange(start: range.start.map(moved), end: moved(end)), false)
  }

  /// 行の区間 `lines` を、行差分 `hunks` の新しい側へ丸ごとずらす分（区間の行に変更区間が掛かるか、区間の内側に行が足されれば
  /// nil）。
  nonisolated private static func shift(of lines: Range<Int>, _ hunks: [LineHunk]) -> Int? {
    var shift = 0
    for hunk in hunks {
      let old = hunk.oldLines
      if old.isEmpty {
        if old.lowerBound <= lines.lowerBound {
          shift += hunk.newLines.count
          continue
        }
        if old.lowerBound < lines.upperBound { return nil }
        break
      }
      if old.upperBound <= lines.lowerBound {
        shift += hunk.newLines.count - old.count
        continue
      }
      if old.lowerBound < lines.upperBound { return nil }
      break
    }
    return shift
  }

  /// 行 `line` の、行差分 `hunks` の新しい側の近くの行——変更区間の外ならずらした行、中ならその区間の新しい側の終わりの行
  /// （区間が新しい側に行を持たなければその前の行）。
  nonisolated private static func nearest(_ line: Int, _ hunks: [LineHunk]) -> Int {
    switch DiffRows.row(ofOld: line, hunks) {
    case .context(let moved): return moved
    case .changed(let hunk, _):
      let near = hunk.newLines.isEmpty ? hunk.newLines.lowerBound - 1 : hunk.newLines.upperBound - 1
      return max(0, near)
    }
  }
}
