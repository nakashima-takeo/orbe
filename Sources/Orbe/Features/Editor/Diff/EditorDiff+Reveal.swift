import Foundation
import OrbeEditorCore

/// 頼まれたスレッドを見せる——コメントの層が置いたスレッドの絵を、その行と、押した未送信のコメントが見える位置へ送る。
extension EditorDiff {
  /// コメントの層に、見せるよう頼まれたスレッドがあり、置いた絵があれば送る（初めての位置を決めた後だけ）。行の上端から
  /// 次の行の上端（行の下に置いたスレッドの絵を含む）までを、行を中央に置いて見せ、収まらなければ行を上端に置く。そのうえで、
  /// 押した未送信のコメントが見えていなければ、見えるところまで最小限に送る（コメントが見えている高さより高ければ、その頭を
  /// 上端に）——押したコメントを、行より優先して見せる。古い側の行は、並びの中の位置（インラインなら差し込んだ削除行、並列
  /// なら左の面の行に揃う段）へ直す。
  func revealRequestedThread() {
    guard placement == .placed, let surface = newSurface, surface.viewport.visibleLines > 0,
      let comments, let target = comments.revealTarget(), let (hunks, newSide) = currentRows
    else { return }
    // 頼みの段を先に進める（送った見えている範囲の知らせの中で、同じ頼みをもう一度送らない）。
    comments.didReveal(target.zone)
    let old = target.version == .old
    let lines = old ? oldSide.lines : newSide.lines
    let line = min(target.line, max(0, lines - 1))
    let side = presented == .side
    let row = { (line: Int) -> LineRow in
      old
        ? DiffRows.lineRow(of: DiffRows.Anchor(line: line, added: 0), hunks, side: side)
        : LineRow(line: line)
    }
    surface.reveal(
      from: surface.position(ofLineRow: row(line)), to: surface.position(ofLineRow: row(line + 1)),
      policy: .center)
    if let span = target.comment {
      (target.zone.surface ?? surface).reveal(
        target.zone, from: span.lowerBound, to: span.upperBound, policy: .minimal)
    }
  }

  /// 利用者が diff の面を操作した（スクロール・押下・打鍵）。見せるよう頼まれたスレッドの頼みを捨てる——読んでいる最中・
  /// 返信を打っている最中に、後から置かれたスレッドへ画面を動かさない。
  func userDidInput() {
    comments?.userDidOperate()
  }
}
