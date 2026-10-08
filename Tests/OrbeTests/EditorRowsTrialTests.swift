import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 区画を人が判定する試しの場（`scripts/preview-editor-rows.sh`）。`ORBE_EDITOR_ROWS_TRIAL=1` のときだけ走り、通常の
/// `swift test` と CI では skip。製品の機能・設定・制御 API には何も足さない。
///
/// 人が触る型（既定）: ミニマップを出さない構成の 200KB の文書に、30 行ごとに試しのスレッドの区画（見本 D 節の構成。
/// ボタンのホバーと押下で見た目が変わり、返信の入力欄に打てる）と、13 行ごとに文書に無い行を差し込み、窓を画面に出して
/// `ORBE_EDITOR_ROWS_SECONDS` 秒（既定 180）前面に置く。見るのは、区画が本文の空きから離れて見えないか・窓の幅を変えた
/// とき区画の高さが中身に合うか・入力欄の日本語と候補窓・スクロール中の焦点・区画の文の選択とコピー・ボタンのホバー。
///
/// 合成の型（`ORBE_EDITOR_ROWS_MODE=synthetic`）: 区画の上下に印の行（全角の塗りの字）を置いた文書で、合成のはじき
/// （6000pt/s）と端の弾みを流しながら、窓が画面に出したコマを ScreenCaptureKit で受け、コマごとに区画の枠線の行と、上下の
/// 印の行の字の画素の距離を引く。区画が本文と同じコマに描かれていれば、距離はどのコマでも同じ（±1 画素）。受けたコマを
/// 連番の PNG と、並べた 1 枚に書き出す（`.preview/flows/rows-trial/`）。
///
/// テストは `NSApp.run` を回さないので、待つ間はアプリの出来事を配る（→ `runShownWindow`）。配らないと、窓が見えている
/// 知らせも人の入力も面に届かず、面は本文を描かない。アプリと同じメインメニュー（`MainMenu`）を据える——⌘A ⌘C ⌘X ⌘V
/// ⌘Z ⌘⇧Z は編集メニューの key equivalent が first responder へ配るので、無いと人がアプリと同じ操作を試せない。
/// 窓は主窓と同じ `OrbeWindow` にし、キーが窓を通る道をアプリと揃える。
@MainActor
final class EditorRowsTrialTests: OrbeTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  /// 試しのスレッドを置く間隔（行）。
  private static let zoneEvery = 30

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(environment["ORBE_EDITOR_ROWS_TRIAL"] == "1", "ORBE_EDITOR_ROWS_TRIAL=1 で走る")
    NSApplication.shared.setActivationPolicy(.accessory)
    let replaced = NSApp.mainMenu
    addTeardownBlock { MainActor.assumeIsolated { NSApp.mainMenu = replaced } }
    let main = MainMenu.build(appName: "Orbe", language: .ja)
    NSApp.mainMenu = main
    NSApp.servicesMenu = MainMenu.servicesMenu(of: main)
  }

  func testTrial() throws {
    if environment["ORBE_EDITOR_ROWS_MODE"] == "synthetic" { return try synthetic() }
    let window = try show(Self.swiftSource()).window
    defer { window.orderOut(nil) }
    runShownWindow(for: Double(environment["ORBE_EDITOR_ROWS_SECONDS"] ?? "") ?? 180)
  }

  // MARK: - 合成の型

  private func synthetic() throws {
    let shown = try show(Self.markedSource())
    let (window, surface) = (shown.window, shown.surface)
    defer { window.orderOut(nil) }
    surface.scroll(toFirstLine: 20)
    runShownWindow(for: 0.5)
    let scale = window.backingScaleFactor
    let left = surface.surfaceLayout.text.minX
    // 面の view の点 → 受けるコマ（窓の枠全体。上が原点）の画素。
    let image = { (x: CGFloat, y: CGFloat) -> (Int, Int) in
      let point = surface.view.convert(NSPoint(x: x, y: y), to: nil)
      return (Int(point.x * scale), Int((window.frame.height - point.y) * scale))
    }
    let box = try XCTUnwrap(
      surface.zones.values.first?.picture.elements.lazy.compactMap { element -> ZoneBox? in
        guard case .box(let box) = element else { return nil }
        return box
      }.first, "前提: 試しのスレッドの枠の箱")
    let recorder = WindowRecorder(
      strokeX: image(left + 4, 0).0, markerX: image(left + 30, 0).0,
      top: image(0, surface.config.topInset + 8).1,
      boxHeight: Int((box.frame.height * scale).rounded()), output: try outputDirectory())
    let started = expectation(description: "窓のコマを受け始める")
    var failure: Error?
    Task {
      do { try await recorder.start(window) } catch { failure = error }
      started.fulfill()
    }
    wait(for: [started], timeout: 10)
    if let failure { throw failure }
    runShownWindow(for: 0.3)
    scroll(surface.view, flick: 6000)
    runShownWindow(for: 1.6)
    scroll(surface.view, drag: 0.4, speed: -9000)
    scroll(surface.view, flick: -6000)
    runShownWindow(for: 1.6)
    let stopped = expectation(description: "コマを受け終える")
    Task {
      await recorder.stop()
      stopped.fulfill()
    }
    wait(for: [stopped], timeout: 10)
    let report = recorder.finish()
    print("[rows-trial] frames \(report.frames), measured zones \(report.above.count)")
    print(
      "[rows-trial] gap above px \(report.range(report.above)), below px \(report.range(report.below))"
    )
    print("[rows-trial] wrote \(report.sheet?.path ?? "-")")
    XCTAssertGreaterThan(report.frames, 30, "前提: スクロールの間のコマを受けた")
    XCTAssertGreaterThan(report.above.count, 30, "前提: 区画の枠線と上下の印の行を引けた")
    XCTAssertLessThanOrEqual(
      (report.above.max() ?? 0) - (report.above.min() ?? 0), 2,
      "区画の上端と上の行の距離は、どのコマでも同じ（区画が本文と同じコマに描かれる）")
    XCTAssertLessThanOrEqual(
      (report.below.max() ?? 0) - (report.below.min() ?? 0), 2,
      "区画の下端と下の行の距離は、どのコマでも同じ")
    XCTAssertGreaterThan(report.above.min() ?? 0, 0, "区画が上の行の字に重ならない")
    XCTAssertGreaterThan(report.below.min() ?? 0, 0, "区画が下の行の字に重ならない")
  }

  private func outputDirectory() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent(".preview/flows/rows-trial", isDirectory: true)
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  // MARK: - 窓

  /// 前面に出した窓と、その面。
  private struct Shown {
    let window: NSWindow
    let surface: MetalTextSurface
  }

  /// 1200×800 の動かせる窓に `text` を開き、差し込みを置いて前面に出す。
  private func show(_ text: String) throws -> Shown {
    let queries = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let tab = TerminalTab(
      cwd: TestScratch.caseDir.path,
      editorSurfaces: EditorSurfaces(queriesRoot: queries))
    let window = OrbeWindow(
      contentRect: NSRect(x: 120, y: 120, width: 1200, height: 800),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "区画の試しの場"
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = tab.view
    tab.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    let document = try tab.editor.open(try caseFile("trial.swift", text), as: .pinned)
    let surface = try engine(document)
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 60))
    surface.setPresentation(SurfacePresentation(showsMinimap: false))
    let (insertions, threads) = insertions(lineCount: document.text.lineCount)
    for thread in threads { thread.surface = surface }
    surface.setRows(SurfaceRows(insertions: insertions))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.makeFirstResponder(surface.responder)
    runShownWindow(for: 0.5)
    XCTAssertTrue(surface.material.read().visible, "前提: 窓が見えていると面が知っている")
    return Shown(window: window, surface: surface)
  }

  /// 30 行ごとの試しのスレッドと、13 行ごとの文書に無い行 2 行（区画と同じ境には置かない）。
  private func insertions(lineCount: Int) -> ([RowInsertion], [SampleThreadZone]) {
    var result: [RowInsertion] = []
    var threads: [SampleThreadZone] = []
    for line in 1..<lineCount {
      if line % 13 == 0, line % Self.zoneEvery != 0 {
        result.append(
          RowInsertion(
            line: line,
            content: .lines([InsertedLine("-   removed line \(line)"), InsertedLine("-   // gone")])
          ))
      }
      if line % Self.zoneEvery == 0 {
        let thread = SampleThreadZone.sample(line: line, id: "reply-\(line)")
        threads.append(thread)
        result.append(RowInsertion(line: line, content: .zone(thread)))
      }
    }
    return (result, threads)
  }

  /// 200KB の Swift（人が触る型）。
  private static func swiftSource() -> String {
    EditorTypingPerfTests.swiftSource(bytes: 200_000)
  }

  /// 区画の上下の行を印の行（全角の塗りの字）にした文書（合成の型）。字の画素の上端と下端が行ごとに変わらない。
  private static func markedSource() -> String {
    (0..<3000).map { line in
      line % zoneEvery == zoneEvery - 1 || (line % zoneEvery == 0 && line > 0)
        ? String(repeating: "\u{2588}", count: 12) : "let value\(line) = compute(\(line)) // filler"
    }.joined(separator: "\n") + "\n"
  }

  // MARK: - 合成のスクロール

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
      while CACurrentMediaTime() < start + planned.at { runShownWindow(for: 0.001) }
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
