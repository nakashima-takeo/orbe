import Foundation
import OrbeEditorCore

/// 頼まれたスレッドを見せる——コメントの層が置いたスレッドの絵を、その行と、押した未送信のコメントが見える位置へ送る。
extension EditorDiff {
  /// コメントの層に、見せるよう頼まれたスレッドがあり、今の並びに載せた絵があれば送る（初めての位置を決めた後だけ）。
  /// 絵の居る面で、行の上端から次の行の上端（行の下に置いたスレッドの絵を含む）までを、行を中央に置いて見せ、収まらなければ
  /// 行を上端に置く。そのうえで、押した未送信のコメントが見えていなければ、見えるところまで最小限に送る（コメントが見えている
  /// 高さより高ければ、その頭を上端に）——押したコメントを、行より優先して見せる。インラインの古い側の行は、差し込んだ削除行
  /// の位置へ直す（並列の古い側の行は、絵の居る左の面のその行）。
  func revealRequestedThread() {
    guard placement == .placed, newSurface?.viewport.visibleLines ?? 0 > 0, let comments,
      let (hunks, newSide) = currentRows, let target = comments.takeRevealTarget()
    else { return }
    let old = target.version == .old
    let lines = old ? oldSide.lines : newSide.lines
    let line = min(target.line, max(0, lines - 1))
    let inlineOld = old && presented != .side
    let row = { (line: Int) -> LineRow in
      inlineOld
        ? DiffRows.lineRow(of: DiffRows.Anchor(line: line, added: 0), hunks, side: false)
        : LineRow(line: line)
    }
    let surface = target.surface
    surface.reveal(
      from: surface.position(ofLineRow: row(line)), to: surface.position(ofLineRow: row(line + 1)),
      policy: .center)
    if let span = target.comment {
      surface.reveal(target.zone, from: span.lowerBound, to: span.upperBound, policy: .minimal)
    }
  }

  /// 利用者が diff の面を操作した（スクロール・押下・打鍵）。見せるよう頼まれたスレッドの頼みを捨てる——読んでいる最中・
  /// 返信を打っている最中に、後から置かれたスレッドへ画面を動かさない。
  func userDidInput() {
    comments?.userDidOperate()
  }
}
