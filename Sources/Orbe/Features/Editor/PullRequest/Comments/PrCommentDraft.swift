import Foundation
import OrbeEditorCore

/// 新しいコメントの欄 1 つ——欄の絵の差し込みと、欄を置く側と行、その行を数えた版（PR の先頭のコミットと両側の本文）。
///
/// PR に push があって diff が見せる版が替わると、行を新しい版へ移す。移し方は、行を数えた版の本文と新しい版の本文の
/// 行差分で、行が変更区間の外にあれば区間の増減の分だけずらした行へ、変更区間の中（書き換えられた・消された行）にあれば
/// 「行が無くなった」とする（GitHub が push の後にスレッドの行を新しい版へ付け替え、変わった行のスレッドを古い版のものとする
/// のと同じ考え方）。移した行に印を出せないとき（diff の区間の外）も行が無くなったとする。行が無くなった欄は閉じずに、
/// その区間の新しい側の終わりの行の下に置き、書きかけを残す（絵の差し込みの `isLineGone`）。
@MainActor
final class PrCommentDraft {
  let zone: PrCommentZone
  let version: DiffRows.Version
  /// 欄を置く行（その側の版の行。0 始まり）。
  private(set) var line: Int
  /// 行を数えた PR の先頭のコミットと、そのときの両側の本文。
  private(set) var head: String
  private(set) var basis: EditorDiff.SideTexts
  /// 新しい版へ行を移す計算を裏でしている。
  private(set) var isMoving = false
  /// 新しい版へ移した行に印を出せるかを、まだ確かめていない。
  private var awaitsCheck = false

  init(
    zone: PrCommentZone, version: DiffRows.Version, line: Int, head: String,
    basis: EditorDiff.SideTexts
  ) {
    self.zone = zone
    self.version = version
    self.line = line
    self.head = head
    self.basis = basis
  }

  /// 行を、PR の先頭のコミット `head` の版（両側の本文 `shown`）へ移す。行差分は本文の大きさに比例するので裏で取り、移し
  /// 終えたら `done` を呼ぶ。
  func move(
    to head: String, shown: EditorDiff.SideTexts, limit: LineDiff.Limit, done: @escaping () -> Void
  ) {
    isMoving = true
    let (from, to) = version == .old ? (basis.old, shown.old) : (basis.new, shown.new)
    let line = line
    Task.detached(priority: .userInitiated) { [weak self] in
      let target = Self.target(of: line, from: from, to: to, limit: limit)
      await MainActor.run { [weak self] in
        guard let self else { return }
        isMoving = false
        self.head = head
        basis = shown
        self.line = target.line
        zone.line = target.line + 1
        if target.isGone { zone.isLineGone = true } else { awaitsCheck = true }
        done()
      }
    }
  }

  /// 移した行が、印を出せる行（側ごとの 0 始まりの半開区間）`commentable` の外なら、行が無くなったとする。
  func settle(commentable: (old: [Range<Int>], new: [Range<Int>])) {
    guard awaitsCheck else { return }
    awaitsCheck = false
    if !DiffRows.contains(version == .old ? commentable.old : commentable.new, line) {
      zone.isLineGone = true
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
