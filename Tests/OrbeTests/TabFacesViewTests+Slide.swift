import AppKit
import XCTest

@testable import Orbe

/// 面の動き（位置のばねで行き先へ運ぶ）のどのコマでも、見えている面は中身で覆われている——窓が透けるコマを作らない。
/// 中身の寸法を変えるのは動きの始めか終わりの 1 回だけ（端末の pty の resize とエディターの再配置を増やさない）。
///
/// 壊れると何が起きるか。隠れていく面の中身が先に幅 0 へ縮むと、縮んでいく面の全体が透けて窓の後ろが見える。縮む面の中身を
/// 先に行き先の幅へ縮めると、面が中身より広いコマで面の端が透ける。
extension TabFacesViewTests {
  private static let editorOnly = FaceLayout(editorRatio: 1, focus: .editor)
  private static let split = FaceLayout(editorRatio: 0.5, focus: .editor)

  /// 窓に載せた器（動きは窓に付いているときだけ起きる）。
  func hostedInWindow(_ faces: FaceLayout) -> (TerminalTab, NSWindow) {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 1012, height: 400)),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let tab = TerminalTab(cwd: "/tmp")
    tab.setFaces(faces, animated: false)
    window.contentView = tab.view
    tab.view.layoutSubtreeIfNeeded()
    addTeardownBlock { @MainActor in window.contentView = nil }
    return (tab, window)
  }

  /// 見えている面のうち、中身に覆われていない面積（2x のデバイス px）。
  private func uncoveredPixels(_ view: TabFacesView) -> CGFloat {
    [view.editor, view.terminal as NSView].reduce(0) { sum, content in
      guard let face = content.superview, !face.isHidden else { return sum }
      let covered = face.bounds.intersection(content.frame)
      let area = face.bounds.width * face.bounds.height
      let inside = covered.isNull ? 0 : covered.width * covered.height
      return sum + (area - inside) * 4
    }
  }

  /// 動きを始めて（`trigger`）、止まるまでのコマを刻み、各コマの覆われていない面積と中身の寸法が変わった回数を測る。
  private func measureSlide(
    from: FaceLayout, to: FaceLayout, trigger: (TerminalTab) -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let (tab, _) = hostedInWindow(from)
    let view = tab.view
    var editorSizes = [view.editor.frame.size]
    var terminalSizes = [tab.surface.bounds.size]
    func record() {
      if editorSizes.last != view.editor.frame.size { editorSizes.append(view.editor.frame.size) }
      if terminalSizes.last != tab.surface.bounds.size {
        terminalSizes.append(tab.surface.bounds.size)
      }
    }
    trigger(tab)
    XCTAssertEqual(tab.faces, to, "前提: 行き先の配置", file: file, line: line)
    XCTAssertTrue(view.isAnimating, "前提: 動きが始まっている", file: file, line: line)
    var worst: CGFloat = uncoveredPixels(view)
    record()
    var frames = 0
    while view.isAnimating, frames < 600 {
      view.tick(dt: 1.0 / 120)
      worst = max(worst, uncoveredPixels(view))
      record()
      frames += 1
    }
    XCTAssertFalse(view.isAnimating, "動きが止まらない", file: file, line: line)
    let label = "\(from.editorRatio)→\(to.editorRatio)"
    // 動きの途中の面は端数の位置に置かれるので、面積の引き算に浮動小数の誤差が残る。1 デバイス px 未満は覆われている。
    XCTAssertLessThan(worst, 1, "\(label): 中身に覆われていない面が見える", file: file, line: line)
    XCTAssertLessThanOrEqual(
      editorSizes.count - 1, 1, "\(label): エディターの寸法の変更 \(editorSizes)", file: file, line: line)
    XCTAssertLessThanOrEqual(
      terminalSizes.count - 1, 1, "\(label): 端末の寸法の変更 \(terminalSizes)", file: file, line: line)
    XCTAssertEqual(view.projection, FaceGeometry.resolve(to, size: view.bounds.size).projection)
  }

  /// エディター全面・分割・端末だけの間の 6 方向（配置を写す口から）。
  func testEverySlideFrameKeepsTheVisibleFacesCovered() {
    let layouts = [Self.editorOnly, Self.split, FaceLayout.terminalOnly]
    for from in layouts {
      for to in layouts where to != from {
        measureSlide(from: from, to: to) { $0.setFaces(to, animated: true) }
      }
    }
  }

  /// 継ぎ目を押して起こす動きも同じ口を通る（分割から焦点側の全面へ）。
  func testHandleClickSlideKeepsTheFacesCovered() {
    measureSlide(from: Self.split, to: Self.editorOnly) {
      $0.view.handle.onGrab?($0.view.handle.frame.midX)
      $0.view.handle.onClick?()
    }
  }
}
