import Foundation
import OrbeEditorCore

/// 行を追う欄の置き場所——欄の絵の差し込みと、欄の起点（書きかけの欄の位置。書き換えない）と、起点から diff が見せている
/// 両端へ導いた行。新しいコメントの欄と、返信の書きかけを持ったまま今の diff に置けなくなったスレッドが使う。
///
/// diff が見せている両端（マージベースか PR の先頭のコミット）が替わるたびに、起点から行を導き直す（前に導いた行から継ぎ足さない）。
/// 導き方は、起点の両側の本文のその側と、見せている両側の本文のその側の行差分で、行が変更区間の外にあれば区間の増減の分だけ
/// ずらした行へ、変更区間の中（書き換えられた・消された行）にあれば「行が無くなった」とする（GitHub が push の後にスレッドの行を
/// 新しい版へ付け替え、変わった行のスレッドを古い版のものとするのと同じ考え方）。導いた行に印を出せないとき（diff の区間の外）も
/// 行が無くなったとする。行が無くなった欄は閉じずに、変更区間の中ならその区間の新しい側の終わりの行の下に、印を出せないだけなら
/// 導いた行の下に置き、書きかけを残す（`isGone`）。行が無くなったかも導くたびに決め直すので、後の版で行が戻れば欄も戻る。導き
/// 始めてから、導いた行に印を出せるかを確かめ終えるまでは `isMoving` が立ち、絵の差し込みの `isLineMoving` にも写す（書き込みの
/// ボタンを押せない姿にする）。導いている間、欄は前に導いた行（初めは起点の行）の下に出たまま。
@MainActor
final class PrCommentPlacement {
  let zone: PrCommentZone
  /// 欄の起点（書き換えない）。
  let origin: PullRequestState.CommentSpot
  let version: DiffRows.Version
  /// 欄を置く行（その側の版の行。0 始まり）。
  private(set) var line: Int
  /// `line` を導いた両端（初めは起点の両端）。
  private(set) var ends: PullRequestState.DiffEnds
  /// 起点から行差分で導いたときに、行が変更区間の中だった。
  private var isInChange = false
  /// 行差分を裏で取っている両端。
  private var computing: PullRequestState.DiffEnds?
  /// 行が今の版に無い（書き換えられた・消された・印を出せない）。
  private(set) var isGone = false
  /// 行を導き始めてから、導いた行に印を出せるかを確かめ終えるまで。
  private(set) var isMoving = true {
    didSet { zone.isLineMoving = isMoving }
  }

  /// 起点 `origin` の欄。印を出せる行だと確かめるまでは送れない姿。
  init(zone: PrCommentZone, origin: PullRequestState.CommentSpot) {
    self.zone = zone
    self.origin = origin
    version = origin.side == .old ? .old : .new
    line = origin.line
    ends = origin.ends
    zone.isLineMoving = true
  }

  /// 行を導き終え、印を出せるかも確かめ終えた（裏の仕事が残っていない）。
  var isSettled: Bool { !isMoving }

  /// diff が両端 `ends`（両側の本文 `shown`）を見せている今に合わせる——行を導いた両端と違えば、導いている最中でない限り起点から
  /// 導き始め（導き終えたら `done` を呼ぶ）、同じ両端なら、コメントできる行のまとまり `commentable`（求め終えていれば）で
  /// 導いた行を確かめる。
  /// 導いている間は、次の両端が来ても新しく導き始めない（導き終えた後の `done` からの呼び直しで追う）。
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

  /// 起点の行を、diff の両端 `ends` の版（両側の本文 `shown`）での行へ導く。行差分は本文の大きさに比例するので裏で取る。
  private func derive(
    _ ends: PullRequestState.DiffEnds, shown: EditorDiff.SideTexts, done: @escaping () -> Void
  ) {
    computing = ends
    isMoving = true
    let (from, to) =
      version == .old ? (origin.basis.old, shown.old) : (origin.basis.new, shown.new)
    let line = origin.line
    let limit = EditorDiff.hunkLimit
    Task.detached(priority: .userInitiated) { [weak self] in
      let target = Self.target(of: line, from: from, to: to, limit: limit)
      await MainActor.run { [weak self] in
        guard let self else { return }
        computing = nil
        self.ends = ends
        self.line = target.line
        zone.line = target.line + 1
        isInChange = target.isGone
        if target.isGone {
          isGone = true
          isMoving = false
        }
        done()
      }
    }
  }

  /// 導いた行が変更区間の中か、コメントできる行のまとまり `commentable` の外なら、行が無くなったとし、そうでなければ行が在る
  /// とする。確かめ終えたら、導いている姿を下ろす。行差分を取っている間は何もしない。
  private func settle(commentable: DiffRows.CommentHunks) {
    guard computing == nil else { return }
    isMoving = false
    isGone = isInChange || commentable.index(of: line, version) == nil
  }

  /// 本文 `from` の行 `line` の、本文 `to` での行。変更区間の中なら、その区間の新しい側の終わりの行（区間が新しい側に行を
  /// 持たなければその前の行）で、行は無くなったとする。どちらかの本文が無ければ、先頭の行で、行は無くなったとする。
  nonisolated static func target(of line: Int, from: String?, to: String?, limit: LineDiff.Limit)
    -> (line: Int, isGone: Bool)
  {
    guard let from, let to else { return (0, true) }
    let hunks = DiffRows.hunks(old: TextRope(from), new: TextRope(to), limit: limit)
    switch DiffRows.row(ofOld: line, hunks) {
    case .context(let moved): return (moved, false)
    case .changed(let hunk, _):
      let near = hunk.newLines.isEmpty ? hunk.newLines.lowerBound - 1 : hunk.newLines.upperBound - 1
      return (max(0, near), true)
    }
  }
}
