import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 試しの場の並列の型（→ `EditorRowsTrialTests`）。
extension EditorRowsTrialTests {
  // MARK: - 並列の型

  func sideBySide() throws {
    let (window, _) = try showSide()
    defer { window.orderOut(nil) }
    runShownWindow(for: Double(environment["ORBE_EDITOR_ROWS_SECONDS"] ?? "") ?? 180)
  }

  /// 並列の合成の型: 右の面と左の面のそれぞれの上へ、窓の出来事の配り（`NSWindow.sendEvent`。点の下の view を引いて配る
  /// ——人の操作と同じ道）でマウスのホイールとトラックパッドの指のドラッグとはじきを流し（はじきの momentum は始まりを
  /// 受けた面へ直接渡す）、両面の描画スレッドが最後に描いた位置を読み比べる。ホイールは、もう一方の面だけが刻みごとに描き直している（構文の色の到着・つまみの現れ消えと同じく、
  /// その面の材料だけが変わる）間にも回す。`ORBE_EDITOR_ROWS_SCREEN` で窓を出す画面を選べる。
  func sideSynthetic() throws {
    let (window, surfaces) = try showSide()
    defer { window.orderOut(nil) }
    let press = { (window.contentView as? SideBySideView)?.press() }
    let fling = { (index: Int) in
      self.scroll(surfaces[index].view, drag: 0.4, speed: 2000)
      let momentum = self.scroll(surfaces[index].view, flick: 3000)
      print("[rows-trial] side momentum events delivered: \(momentum)")
      XCTAssertGreaterThan(momentum, 0, "はじきの momentum が面に届いた")
    }
    let steps: [SideStep] = [
      SideStep(name: "wheel right") { self.wheel(surfaces[1].view, lines: -5, times: 6) },
      SideStep(name: "wheel left") { self.wheel(surfaces[0].view, lines: -5, times: 6) },
      SideStep(name: "right busy, wheel left") { self.wheel(surfaces[0], busy: surfaces[1]) },
      SideStep(name: "left busy, wheel right") { self.wheel(surfaces[1], busy: surfaces[0]) },
      SideStep(name: "trackpad right") { fling(1) },
      SideStep(name: "trackpad left") { fling(0) },
      SideStep(name: "trackpad left after click") {
        self.click(surfaces[0].view)
        fling(0)
      },
      SideStep(name: "trackpad right after toggle") {
        press()
        self.runShownWindow(for: 0.3)
        fling(1)
      },
      SideStep(name: "wheel left after toggle") {
        press()
        self.runShownWindow(for: 0.3)
        self.wheel(surfaces[0].view, lines: -5, times: 6)
      },
    ]
    for step in steps {
      runShownWindow(for: 0.3)
      let before = drawnPositions(surfaces)
      step.run()
      runShownWindow(for: 1.2)
      let after = drawnPositions(surfaces)
      print("[rows-trial] side \(step.name): before \(before) after \(after)")
      XCTAssertNotEqual(after[1].y, before[1].y, "\(step.name): 右の面が動く")
      XCTAssertNotEqual(after[0].y, before[0].y, "\(step.name): 左の面が動く")
      XCTAssertEqual(after[0], after[1], "\(step.name): 止まった後、両面は同じ位置を描いている")
    }
  }

  /// `busy` の面だけが刻みごとに描き直している間に、`surface` の上でホイールを 1 目盛りずつ 6 回回す。
  private func wheel(_ surface: MetalTextSurface, busy: MetalTextSurface) {
    for _ in 0..<6 {
      let until = CACurrentMediaTime() + 0.25
      var k = 0
      while CACurrentMediaTime() < until {
        k += 1
        busy.setLinkPointer(k % 2 == 0 ? CGPoint(x: 5, y: 5) : nil)
        runShownWindow(for: 0.004)
        if k == 20 { wheel(surface.view, lines: -1, times: 1) }
      }
    }
    busy.setLinkPointer(nil)
  }

  /// マウスのホイール（行単位・段なし）を `times` 回、30ms おきに窓の配りへ通す。
  fileprivate func wheel(_ view: NSView, lines: Int32, times: Int) {
    guard let window = view.window else { return }
    for _ in 0..<times {
      guard
        let event = CGEvent(
          scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0,
          wheel3: 0)
      else { continue }
      let point = view.centerInWindow
      event.location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
      event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
      if let scroll = NSEvent(cgEvent: event) { window.sendEvent(scroll) }
      runShownWindow(for: 0.03)
    }
  }

  fileprivate func click(_ view: NSView) {
    guard let window = view.window else { return }
    let point = view.centerInWindow
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      if let event = NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: CACurrentMediaTime(),
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
      {
        window.sendEvent(event)
      }
    }
  }

  /// 面の描画スレッドが最後に描いたコマの位置。
  fileprivate func drawnPositions(_ surfaces: [MetalTextSurface]) -> [SIMD2<Double>] {
    let ids = surfaces.map(\.id)
    return RenderThread.shared.performAndWait { renderer in
      ids.map { renderer.slot($0)?.drawnPosition ?? SIMD2(-1, -1) }
    }
  }

  /// 並列の 2 面の窓を前面に出す。
  fileprivate func showSide() throws -> (NSWindow, [MetalTextSurface]) {
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
    if let index = Int(environment["ORBE_EDITOR_ROWS_SCREEN"] ?? ""),
      NSScreen.screens.indices.contains(index)
    {
      let screen = NSScreen.screens[index].visibleFrame
      window.setFrameOrigin(NSPoint(x: screen.minX + 60, y: screen.minY + 60))
    }
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
    runShownWindow(for: 0.5)
    print(
      "[rows-trial] window \(window.frame) screen \(String(describing: window.screen?.localizedName))"
    )
    let documents = panes.map(\.document)
    addTeardownBlock { _ = documents }
    return (window, panes.map(\.surface))
  }

  /// 200KB の Swift の 2 版——17 行ごとに 1 行を 2 行に書き換え、29 行ごとに 1 行を消し、23 行ごとに 3 行を足したもの。
  fileprivate static func sideSample() -> DiffRowsSample {
    let lines = swiftSource().components(separatedBy: "\n").dropLast()
    var rows: [DiffRowsSample.Row] = []
    for (index, line) in lines.enumerated() {
      if index % 17 == 5 {
        rows += [.removed(line), .added(line + " // changed"), .added("    // split \(index)")]
      } else if index % 29 == 7 {
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
}

/// 並列の合成の型の手順 1 つ——名前と、流す操作。
private struct SideStep {
  let name: String
  let run: () -> Void
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

  /// 「並びを置き直す」を押す。
  func press() { button.performClick(nil) }

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
