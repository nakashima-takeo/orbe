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
/// 並列の型（`ORBE_EDITOR_ROWS_MODE=side`）: 200KB の文書の 2 版（旧版から行を消し、新版に行を足したもの）を、並列の
/// diff の 2 面（番号 1 列・追加 / 削除の地と字・詰め物）に開き、スクロールを共にさせて窓に並べる。窓の下の「並びを置き
/// 直す」は、両面の先頭に詰め物の行を同じ周で足す・外す。見るのは、どちらの面で速く・はじいて・端で弾ませても 2 面が
/// 1 枚の紙として動くか・置き直しで跳ねないか。
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
    if environment["ORBE_EDITOR_ROWS_MODE"] == "side" { return try sideBySide() }
    let window = try show(Self.swiftSource()).window
    defer { window.orderOut(nil) }
    runShownWindow(for: Double(environment["ORBE_EDITOR_ROWS_SECONDS"] ?? "") ?? 180)
  }

  // MARK: - 並列の型

  private func sideBySide() throws {
    let sample = Self.sideSample()
    let registry = LanguageRegistry(
      queriesRoot: Bundle(for: Self.self).bundleURL.deletingLastPathComponent())
    let panes = try [("old.swift", sample.old), ("new.swift", sample.new)].map { name, text in
      let url = try caseFile(name, text)
      let surface = MetalTextSurface(
        style: DiffRowsSample.style(trailing: 8), omittedLabel: { "+\($0)" })
      let document = EditorDocument(
        url: url, contents: try EditorDocument.read(url), surface: surface, registry: registry)
      XCTAssertTrue(document.waitUntilCaughtUp(timeout: 60))
      return (surface: surface, document: document)
    }
    let window = OrbeWindow(
      contentRect: NSRect(x: 120, y: 120, width: 1200, height: 800),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "並列の試しの場"
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    let rows = [sample.side(.old), sample.side(.new)]
    let toggle = SideRowsToggle(surfaces: panes.map(\.surface), rows: rows)
    window.contentView = SideBySideView(surfaces: panes.map(\.surface), toggle: toggle)
    for (pane, rows) in zip(panes, rows) {
      pane.surface.setPresentation(DiffRowsSample.sidePresentation)
      pane.surface.setRows(rows)
      pane.surface.isEditable = false
    }
    panes[0].surface.shareScroll(with: panes[1].surface)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.makeFirstResponder(panes[1].surface.responder)
    defer { window.orderOut(nil) }
    runShownWindow(for: Double(environment["ORBE_EDITOR_ROWS_SECONDS"] ?? "") ?? 180)
  }

  /// 200KB の Swift の 2 版——17 行ごとに 2 行を消し、23 行ごとに 3 行を足したもの。
  private static func sideSample() -> DiffRowsSample {
    let lines = swiftSource().components(separatedBy: "\n").dropLast()
    var rows: [DiffRowsSample.Row] = []
    for (index, line) in lines.enumerated() {
      if index % 17 == 5 {
        rows.append(.removed(line))
      } else {
        rows.append(.same(line))
      }
      if index % 23 == 11 {
        rows += (0..<3).map { .added("    // added \(index)-\($0)") }
      }
    }
    return DiffRowsSample(rows: rows)
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

/// 並列の型の窓の中身——2 面を左右に並べ（間に 1px の区切り）、下に「並びを置き直す」を置く。
@MainActor
private final class SideBySideView: NSView {
  private let surfaces: [MetalTextSurface]
  private let separator = NSView()
  private let button: NSButton
  private let toggle: SideRowsToggle
  private static let strip: CGFloat = 36

  init(surfaces: [MetalTextSurface], toggle: SideRowsToggle) {
    self.surfaces = surfaces
    self.toggle = toggle
    button = NSButton(title: "並びを置き直す", target: toggle, action: #selector(SideRowsToggle.toggle))
    super.init(frame: .zero)
    wantsLayer = true
    separator.wantsLayer = true
    for surface in surfaces { addSubview(surface.view) }
    addSubview(separator)
    addSubview(button)
  }

  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = Theme.Color.bgBase.cgColor
      separator.layer?.backgroundColor = DiffRowsSample.hairline.cgColor
    }
    let height = max(0, bounds.height - Self.strip)
    let each = (bounds.width - 1) / 2
    for (index, surface) in surfaces.enumerated() {
      surface.view.frame = NSRect(x: CGFloat(index) * (each + 1), y: 0, width: each, height: height)
    }
    separator.frame = NSRect(x: each, y: 0, width: 1, height: height)
    button.sizeToFit()
    button.frame.origin = NSPoint(x: 12, y: height + (Self.strip - button.frame.height) / 2)
  }
}

/// 両面の先頭（行 1 の前）に詰め物の行を 6 行、同じ周で足す・外す。
@MainActor
private final class SideRowsToggle: NSObject {
  private let surfaces: [MetalTextSurface]
  private let rows: [SurfaceRows]
  private var padded = false

  init(surfaces: [MetalTextSurface], rows: [SurfaceRows]) {
    self.surfaces = surfaces
    self.rows = rows
  }

  @objc func toggle() {
    padded.toggle()
    let pads = (0..<6).map { _ in InsertedLine("", style: DiffRowsSample.pad) }
    for (surface, base) in zip(surfaces, rows) {
      var next = base
      if padded { next.insertions.insert(RowInsertion(line: 1, content: .lines(pads)), at: 0) }
      surface.setRows(next)
    }
  }
}
