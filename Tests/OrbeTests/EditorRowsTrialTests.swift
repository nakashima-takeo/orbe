import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 区画の追従を人が判定する試しの場（`scripts/preview-editor-rows.sh`）。`ORBE_EDITOR_ROWS_TRIAL=1` のときだけ走り、
/// 通常の `swift test` と CI では skip。製品の機能・設定・制御 API には何も足さない。
///
/// ミニマップを出さない構成の 200KB の文書に、30 行ごとの区画（PR のスレッドに近い試しの view）と 13 行ごとの文書に無い
/// 行を差し込み、窓を画面に出して前面に置く。`ORBE_EDITOR_ROWS_MODE=synthetic` なら合成の速いスクロール（ドラッグ・
/// はじき・端での弾み）を繰り返し流し（何度でも同じ動きで見返せる）、そうでなければ `ORBE_EDITOR_ROWS_SECONDS` 秒（既定
/// 180）そのまま置いて、人がトラックパッドで触る。見るのは、区画の枠が本文の行から離れて見えないか・窓の幅を変えたとき区画の
/// 高さが中身に合うか・区画の入力欄に日本語を打てるか。
@MainActor
final class EditorRowsTrialTests: OrbeTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(environment["ORBE_EDITOR_ROWS_TRIAL"] == "1", "ORBE_EDITOR_ROWS_TRIAL=1 で走る")
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  func testTrial() throws {
    let (window, surface) = try show()
    defer { window.orderOut(nil) }
    if environment["ORBE_EDITOR_ROWS_MODE"] == "synthetic" {
      for _ in 0..<3 {
        scroll(surface.view, drag: 2, speed: 2400)
        scroll(surface.view, flick: 6000)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        scroll(surface.view, drag: 2, speed: -2400)
        scroll(surface.view, flick: -6000)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
      }
    } else {
      let seconds = Double(environment["ORBE_EDITOR_ROWS_SECONDS"] ?? "") ?? 180
      RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
  }

  /// 1200×800 の動かせる窓に 200KB の Swift を開き、差し込みを置いて前面に出す。
  private func show() throws -> (NSWindow, MetalTextSurface) {
    let queries = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: queries))
    let window = NSWindow(
      contentRect: NSRect(x: 120, y: 120, width: 1200, height: 800),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "区画の試しの場"
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = tab.view
    tab.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    let document = try tab.editor.open(
      try caseFile("trial.swift", EditorTypingPerfTests.swiftSource(bytes: 200_000)), as: .pinned)
    let surface = try engine(document)
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 60))
    surface.setPresentation(SurfacePresentation(showsMinimap: false))
    surface.setRows(SurfaceRows(insertions: insertions(lineCount: document.text.lineCount)))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.makeFirstResponder(surface.responder)
    return (window, surface)
  }

  /// 30 行ごとの区画と、13 行ごとの文書に無い行 2 行（同じ境なら区画が下）。
  private func insertions(lineCount: Int) -> [RowInsertion] {
    var result: [RowInsertion] = []
    for line in 1..<lineCount {
      if line % 13 == 0 {
        result.append(
          RowInsertion(
            line: line,
            content: .lines([InsertedLine("-   removed line \(line)"), InsertedLine("-   // gone")])
          ))
      }
      if line % 30 == 0 {
        let view = SampleZoneView(
          title: "行 \(line + 1) · 試しのスレッド",
          message: "スクロールしても、この枠の上下の線は本文の行の境から離れない。窓の幅を変えると、文が"
            + "折り返し直されて高さが変わる。入力欄には日本語を打てる。")
        result.append(RowInsertion(line: line, content: .zone(view)))
      }
    }
    return result
  }

  /// 指を一定の速さ（pt/秒。正は下へ送る）で `seconds` 秒動かす。
  private func scroll(_ view: NSView, drag seconds: Double, speed: Double) {
    let step = 0.0057
    var events = [Planned(at: 0, phase: 1)]
    for k in 1...Int(seconds / step) {
      events.append(Planned(at: Double(k) * step, phase: 2, dy: -speed * step))
    }
    events.append(Planned(at: seconds + step, phase: 4))
    feed(view, events)
  }

  /// はじく: 80ms で速さ `peak`（pt/秒）まで上げて離し、OS の momentum の出来事（0.95 倍ずつ落ちる列）が続く。
  private func scroll(_ view: NSView, flick peak: Double) {
    let step = 0.0057
    var events = [Planned(at: 0, phase: 1)]
    let ramp = Int(0.08 / step)
    for k in 1...ramp {
      events.append(
        Planned(at: Double(k) * step, phase: 2, dy: -peak * Double(k) / Double(ramp) * step))
    }
    var t = Double(ramp + 1) * step
    events.append(Planned(at: t, phase: 4))
    var d = -peak * step
    events.append(Planned(at: t, momentum: 1, dy: d))
    while abs(d) > 0.5 {
      t += step
      d *= 0.95
      events.append(Planned(at: t, momentum: 2, dy: d))
    }
    events.append(Planned(at: t + step, momentum: 3))
    feed(view, events)
  }

  /// 合成のスクロールの出来事（`phase`・`momentum` は CGEvent の段の値）を実時間で面の入口へ流す。
  private func feed(_ view: NSView, _ events: [Planned]) {
    let start = CACurrentMediaTime()
    for planned in events {
      while CACurrentMediaTime() < start + planned.at {
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
      }
      guard
        let event = CGEvent(
          scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(planned.dy),
          wheel2: 0, wheel3: 0)
      else { continue }
      event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      event.setIntegerValueField(.scrollWheelEventScrollPhase, value: planned.phase)
      event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: planned.momentum)
      event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: planned.dy)
      event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: planned.dy)
      event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
      if let scroll = NSEvent(cgEvent: event) { view.scrollWheel(with: scroll) }
    }
  }
}

/// 合成するスクロールの出来事（`phase`・`momentum` は CGEvent の段の値）。
private struct Planned {
  var at: Double
  var phase: Int64 = 0
  var momentum: Int64 = 0
  var dy: Double = 0
}
