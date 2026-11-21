import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 診断用（u3 のブランチには入れない）。画面外へ並べた窓へのホイールでツリーが送られない原因を切り分ける。
@MainActor
final class ZZWheelProbeTests: OrbeTestCase {
  private struct Tree {
    let pane: EditorPaneView
    let window: NSWindow
    let scroll: NSScrollView
    let document: NSView
  }

  private func log(_ s: String) { print("WHEELDIAG \(name) | \(s)") }

  private func hostTree(onscreen: Bool) throws -> Tree {
    let dir = TestScratch.caseDir
    for index in 0..<40 {
      try FileManager.default.createDirectory(
        at: dir.appendingPathComponent(String(format: "d%02d", index)),
        withIntermediateDirectories: true)
    }
    let tab = TerminalTab.alone(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 900, height: 240)
    if onscreen {
      window.setFrameOrigin(.zero)
      window.orderFront(nil)
      addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    } else {
      placeOffscreen(window)
    }
    let scroll = try XCTUnwrap(scrollView(in: tab.group.view.editor.sideHost))
    let document = try XCTUnwrap(scroll.documentView)
    pumpMain(until: { document.frame.height > scroll.documentVisibleRect.height * 2 }, "ツリーが溢れる")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
    scroll.reflectScrolledClipView(scroll.contentView)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    log(
      "screens=\(NSScreen.screens.map(\.frame)) window=\(window.frame) window.screen=\(String(describing: window.screen?.frame)) occl=\(window.occlusionState.rawValue) vis=\(window.isVisible) scroll=\(type(of: scroll)) clip=\(type(of: scroll.contentView)) minY=\(scroll.documentVisibleRect.minY)"
    )
    return Tree(pane: tab.group.view.editor, window: window, scroll: scroll, document: document)
  }

  private func measuredFlip() -> CGFloat {
    let probe = CGEvent(
      mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left)!
    return NSEvent(cgEvent: probe)!.locationInWindow.y
  }

  private func wheel(_ units: CGScrollEventUnit, _ amount: Int32, at point: NSPoint) -> NSEvent {
    let cg = CGEvent(
      scrollWheelEvent2Source: nil, units: units, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)!
    let flip = NSScreen.screens.first?.frame.height ?? 0
    cg.location = CGPoint(x: point.x, y: flip - point.y)
    let event = NSEvent(cgEvent: cg)!
    log(
      "flip=\(flip) measuredFlip=\(measuredFlip()) point=\(point) loc=\(event.locationInWindow) dy=\(event.scrollingDeltaY) precise=\(event.hasPreciseScrollingDeltas) phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue) win#=\(event.windowNumber)"
    )
    return event
  }

  private func center(_ tree: Tree) -> NSPoint {
    let frame = treeThumbFrame(tree.pane)!
    return NSPoint(x: frame.midX, y: frame.midY)
  }

  private func track(_ tree: Tree, _ label: String) {
    var samples: [String] = []
    for wait in [0.05, 0.3, 1.0, 3.0] {
      let end = Date().addingTimeInterval(wait)
      while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
      samples.append("t+\(wait)=\(tree.scroll.documentVisibleRect.minY)")
    }
    log("\(label) \(samples.joined(separator: " "))")
  }

  func testA_offscreenLineWindowSendEvent() throws {
    let tree = try hostTree(onscreen: false)
    let point = center(tree)
    let event = wheel(.line, -3, at: point)
    let hit = tree.window.contentView?.hitTest(event.locationInWindow)
    log("hit=\(String(describing: hit.map { type(of: $0) })) inScroll=\(hit?.isDescendant(of: tree.scroll) ?? false)")
    tree.window.sendEvent(event)
    track(tree, "A")
  }

  func testB_offscreenPixelWindowSendEvent() throws {
    let tree = try hostTree(onscreen: false)
    tree.window.sendEvent(wheel(.pixel, -60, at: center(tree)))
    track(tree, "B")
  }

  func testC_offscreenLineDirectScrollWheel() throws {
    let tree = try hostTree(onscreen: false)
    tree.scroll.scrollWheel(with: wheel(.line, -3, at: center(tree)))
    track(tree, "C")
  }

  func testD_offscreenPixelDirectScrollWheel() throws {
    let tree = try hostTree(onscreen: false)
    tree.scroll.scrollWheel(with: wheel(.pixel, -60, at: center(tree)))
    track(tree, "D")
  }

  func testE_onscreenLineWindowSendEvent() throws {
    let tree = try hostTree(onscreen: true)
    let point = center(tree)
    let event = wheel(.line, -3, at: point)
    let hit = tree.window.contentView?.hitTest(event.locationInWindow)
    log("hit=\(String(describing: hit.map { type(of: $0) })) inScroll=\(hit?.isDescendant(of: tree.scroll) ?? false)")
    tree.window.sendEvent(event)
    track(tree, "E")
  }

  func testF_onscreenPixelWindowSendEvent() throws {
    let tree = try hostTree(onscreen: true)
    tree.window.sendEvent(wheel(.pixel, -60, at: center(tree)))
    track(tree, "F")
  }

  func testG_offscreenLineViaNSApp() throws {
    let tree = try hostTree(onscreen: false)
    NSApp.sendEvent(wheel(.line, -3, at: center(tree)))
    track(tree, "G")
  }
}
