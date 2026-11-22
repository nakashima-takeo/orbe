import XCTest

@testable import Orbe

/// gallery・flow が左の列の一覧の行をクリックする入口。製品のクリックと同じく、行を選んで diff を開く——一覧の選択だけを書き換えると、
/// エディター面の本体（diff を出す場所）には前に開いた diff が残り、一覧で選んだ行と本体の diff が食い違う。
extension ScmPanel {
  /// 行 `id` をクリックする（ファイル行なら選んで diff を開く）。
  func click(_ id: ScmRowID) {
    guard let row = layout.index[id] else { return XCTFail("クリックする行が一覧に無い: \(id)") }
    click(row, in: layout)
  }
}

extension PrPanel {
  /// 行 `id` をクリックする（ファイル行なら選んで PR の diff を開く）。
  func click(_ id: PrRowID) {
    guard let row = layout.index[id] else { return XCTFail("クリックする行が一覧に無い: \(id)") }
    click(row, in: layout)
  }
}

extension EditorPaneView {
  /// 本体に `path` の diff が出ていて、撮ってよい状態になった——中身を読み終え（`content`）、最初の変更区間への位置決めを
  /// 済ませ（`placement`）、行差分の計算の待ちも無い（`pending`）。表示できない diff は、理由が決まった時点で撮ってよい。
  func showsDiff(of path: String) -> Bool {
    guard let diff, diff.id.path == path else { return false }
    if case .unavailable = diff.content { return true }
    return diff.content == .ready && diff.placement == .placed && !diff.pending
  }
}
