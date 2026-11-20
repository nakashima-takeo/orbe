import Foundation
import OrbeEditorCore

/// 行を追う欄の置き場所——欄の絵の差し込みと、欄を置く側と行、その行を数えた両端（diff の両端と両側の本文）。新しいコメントの
/// 欄と、返信の書きかけを持ったまま今の diff に置けなくなったスレッドが使う。
///
/// diff の両端（マージベースか PR の先頭のコミット）が替わると、行を新しい両端へ移す。移し方は、行を数えた両端のその側の
/// 本文と新しい両端のその側の本文の行差分で、行が変更区間の外にあれば区間の増減の分だけずらした行へ、変更区間の中（書き換えられた・
/// 消された行）にあれば「行が無くなった」とする（GitHub が push の後にスレッドの行を新しい版へ付け替え、変わった行のスレッドを
/// 古い版のものとするのと同じ考え方）。移した行に印を出せないとき（diff の区間の外）も行が無くなったとする。行が無くなった欄は
/// 閉じずに、変更区間の中ならその区間の新しい側の終わりの行の下に、印を出せないだけなら移した行の下に置き、書きかけを残す
/// （`isGone`）。移し始めてから、移した行に印を出せるかを確かめ終えるまでは `isMoving` が立ち、絵の差し込みの
/// `isLineMoving` にも写す（書き込みのボタンを押せない姿にする）。
@MainActor
final class PrCommentPlacement {
  let zone: PrCommentZone
  let version: DiffRows.Version
  /// 欄を置く行（その側の版の行。0 始まり）。
  private(set) var line: Int
  /// 行を数えた diff の両端と、そのときの両側の本文。
  private(set) var ends: PullRequestState.DiffEnds
  private(set) var basis: EditorDiff.SideTexts
  /// 新しい版へ行を移す行差分を裏で取っている。
  private(set) var isComputing = false
  /// 行が今の版に無い（書き換えられた・消された・印を出せない）。一度無くなった行は戻らない。
  private(set) var isGone = false
  /// 行を移し始めてから、移した行に印を出せるかを確かめ終えるまで。
  private(set) var isMoving = false {
    didSet { zone.isLineMoving = isMoving }
  }

  init(
    zone: PrCommentZone, version: DiffRows.Version, line: Int, ends: PullRequestState.DiffEnds,
    basis: EditorDiff.SideTexts
  ) {
    self.zone = zone
    self.version = version
    self.line = line
    self.ends = ends
    self.basis = basis
  }

  /// 行を移し終え、印を出せるかも確かめ終えた（裏の仕事が残っていない）。
  var isSettled: Bool { !isMoving }

  /// diff が両端 `ends`（両側の本文 `shown`）を見せている今に合わせる——行を数えた両端と違えば、行を移している最中でない限り
  /// 移し始め（移し終えたら `done` を呼ぶ）、同じ両端なら、印を出せる行 `commentable`（求め終えていれば）で移した行を
  /// 確かめる。行を移している間は、次の両端が来ても新しく移し始めない（移し終えた後の `done` からの呼び直しで追う）。
  func follow(
    _ ends: PullRequestState.DiffEnds, shown: EditorDiff.SideTexts,
    commentable: (old: [Range<Int>], new: [Range<Int>])?, done: @escaping () -> Void
  ) {
    if ends != self.ends {
      if !isComputing { move(to: ends, shown: shown, done: done) }
    } else if let commentable {
      settle(commentable: commentable)
    }
  }

  /// 行を、diff の両端 `ends` の版（両側の本文 `shown`）へ移す。行差分は本文の大きさに比例するので裏で取る。
  private func move(
    to ends: PullRequestState.DiffEnds, shown: EditorDiff.SideTexts, done: @escaping () -> Void
  ) {
    isComputing = true
    isMoving = true
    let (from, to) = version == .old ? (basis.old, shown.old) : (basis.new, shown.new)
    let line = line
    let limit = EditorDiff.hunkLimit
    Task.detached(priority: .userInitiated) { [weak self] in
      let target = Self.target(of: line, from: from, to: to, limit: limit)
      await MainActor.run { [weak self] in
        guard let self else { return }
        isComputing = false
        self.ends = ends
        basis = shown
        self.line = target.line
        zone.line = target.line + 1
        if target.isGone {
          isGone = true
          isMoving = false
        }
        done()
      }
    }
  }

  /// 移した行が、印を出せる行（側ごとの 0 始まりの半開区間）`commentable` の外なら、行が無くなったとする。確かめ終えたら、
  /// 移している姿を下ろす。行差分を取っている間は何もしない。
  private func settle(commentable: (old: [Range<Int>], new: [Range<Int>])) {
    guard isMoving, !isComputing else { return }
    isMoving = false
    if !DiffRows.contains(version == .old ? commentable.old : commentable.new, line) {
      isGone = true
    }
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
