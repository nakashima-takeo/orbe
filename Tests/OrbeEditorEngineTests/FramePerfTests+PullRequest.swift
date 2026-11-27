import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest
import os

@testable import OrbeEditorEngine

/// PR の diff の構成の面の計測（`FramePerfTests` と同じ場で、`ORBE_EDITOR_PERF=1` のときだけ走る）。1MB の文書に、8 行
/// ごとの周期（6 行の文脈・3 行の削除の差し込み・2 行の追加）を置き、4 周期のうち 3 周期の行を印を出せる行にし、約 1000 行
/// ごとにスレッドの形の絵の差し込みを置いて、PR の diff と同じ表示の構成（コメントの印つき）で開く。スクロール（インライン・
/// 並列）はポインタを面の上に置いたまま流す。ポインタを動かす場面は、止まった面で、行をまたぐ速さの移動を実機の刻みで流す。
/// 打鍵は、同じ並びの絵の差し込みの入力欄に打つ。関門は印を持たない diff の場面と同じ（1 コマの CPU の p99 2ms 未満・描画
/// スレッド自身が落とすコマ 0・止まっている間の起床 0・移動と打鍵 1 回の main の仕事 p99 1ms・打鍵→present の中央値
/// 12.5ms と p95 17ms）。壊れると、PR の diff でスクロールのコマが落ち、ポインタを動かすと main が詰まり、返信の欄に打った字が
/// 遅れて出る。構成は `wraps` で折り返す面にもできる。
extension FramePerfTests {
  func testPullRequestDiffInline() throws {
    try measurePullRequestInline(wraps: false)
  }

  func testPullRequestDiffSideBySide() throws {
    try measurePullRequestSide(wraps: false)
  }

  func testPointerMovesOverAPullRequestDiff() throws {
    try measurePointerMoves(wraps: false)
  }

  func testTypingIntoAZoneFieldOfAPullRequestDiff() throws {
    try measurePullRequestFieldTyping(wraps: false)
  }

  /// 面の上に置いておくポインタ（本文の区画の中ほど）。
  static let pointerSpot = CGPoint(x: 300, y: 300)

  /// インラインの PR の diff をポインタを面の上に置いたままスクロールする（`measure` の場面と関門）。
  func measurePullRequestInline(wraps: Bool) throws {
    let old = try open(
      Self.swiftSource(bytes: 1_000_000).replacingOccurrences(of: "Item", with: "Old"))
    let source = DocumentRowSource(old.document)
    _ = try measure(
      label: "1MB pr inline", text: Self.swiftSource(bytes: 1_000_000), wraps: wraps,
      pointer: Self.pointerSpot
    ) { opened in
      opened.surface.setPresentation(Self.pullRequestPresentation(columns: 2, wraps: wraps))
      opened.surface.setRows(
        Self.pullRequestInlineRows(lineCount: opened.document.text.lineCount, source: source))
      opened.surface.isEditable = false
    }
  }

  /// 並列の PR の diff を、右の面の上にポインタを置いたまま、左右それぞれに指を流してスクロールする。
  func measurePullRequestSide(wraps: Bool) throws {
    let text = Self.swiftSource(bytes: 1_000_000)
    let left = try attach(text.replacingOccurrences(of: "Item", with: "Old"), wraps: wraps)
    let right = try attach(text, wraps: wraps, pointer: Self.pointerSpot)
    let rows = Self.pullRequestSideRows(lineCount: right.document.text.lineCount)
    for (opened, laid) in [(left, rows.left), (right, rows.right)] {
      opened.surface.setPresentation(Self.pullRequestPresentation(columns: 1, wraps: wraps))
      opened.surface.setRows(laid)
      opened.surface.isEditable = false
    }
    left.surface.shareScroll(with: right.surface)
    waitUntilIdle(left.surface)
    waitUntilIdle(right.surface)
    print("PERF-FRAMES 1MB pr side lines", right.document.text.lineCount)
    for loaded in [false, true] {
      let name = loaded ? "main-load" : "no-load"
      if loaded { startLoad() }
      for driven in [left, right] {
        reset(left.surface)
        reset(right.surface)
        let main =
          (runDrag([driven.surface], seconds: 3, speed: 2400)
          + runFlick(driven.surface, peak: 6000)).sorted()
        waitUntilIdle(left.surface)
        waitUntilIdle(right.surface)
        let side = driven.surface === left.surface ? "driven-left" : "driven-right"
        report("1MB pr side left", "\(name) \(side)", totals(left.surface))
        report("1MB pr side right", "\(name) \(side)", totals(right.surface))
        print(
          "PERF-FRAMES 1MB pr side", name, side, "scroll event main CPU p50",
          Self.ms(Self.quantile(main, 0.5)), "p99", Self.ms(Self.quantile(main, 0.99)))
        XCTAssertEqual(left.surface.scrollPosition, right.surface.scrollPosition, "2 面は同じ位置")
      }
      load?.invalidate()
      load = nil
    }
    let ticks = driver.ticks(right.surface.id)
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    let wakes = driver.ticks(right.surface.id) - ticks
    print("PERF-FRAMES 1MB pr side idle-wakes/s", wakes)
    XCTAssertEqual(wakes, 0, "止まっている間は描画スレッドを起こさない")
  }

  /// 止まったインラインの PR の diff の上で、ポインタを 1 回 3pt ずつ（6 回に 1 回ほど行をまたぐ）、実機の刻み（約 5.7ms）で
  /// 上下に動かす。移動 1 回の main の仕事（行が変わった回・変わらない回）と、1 コマの CPU を関門にかける。
  func measurePointerMoves(wraps: Bool) throws {
    let old = try open(
      Self.swiftSource(bytes: 1_000_000).replacingOccurrences(of: "Item", with: "Old"))
    let source = DocumentRowSource(old.document)
    let opened = try attach(
      Self.swiftSource(bytes: 1_000_000), wraps: wraps, pointer: Self.pointerSpot)
    let surface = opened.surface
    surface.setPresentation(Self.pullRequestPresentation(columns: 2, wraps: wraps))
    surface.setRows(
      Self.pullRequestInlineRows(lineCount: opened.document.text.lineCount, source: source))
    surface.isEditable = false
    surface.scroll(to: RowPosition(line: opened.document.text.lineCount / 2))
    waitUntilIdle(surface)
    let window = try XCTUnwrap(pointerWindows.last)
    var points: [CGPoint] = []
    var y: CGFloat = 40
    var step: CGFloat = 3
    while points.count < Int(3 / 0.0057) {
      points.append(CGPoint(x: Self.pointerSpot.x, y: y))
      if y + step > 560 || y + step < 40 { step = -step }
      y += step
    }
    reset(surface)
    let moves = movePointer(surface, window, through: points)
    waitUntilIdle(surface)
    report("1MB pr pointer", "moves", totals(surface))
    let changed = moves.filter(\.changed).map(\.cpu).sorted()
    let same = moves.filter { !$0.changed }.map(\.cpu).sorted()
    let all = moves.map(\.cpu).sorted()
    print(
      "PERF-FRAMES 1MB pr pointer move main CPU p50", Self.ms(Self.quantile(all, 0.5)), "p99",
      Self.ms(Self.quantile(all, 0.99)), "/ row changed", changed.count, "p50",
      Self.ms(Self.quantile(changed, 0.5)), "p99", Self.ms(Self.quantile(changed, 0.99)),
      "/ same row", same.count, "p50", Self.ms(Self.quantile(same, 0.5)), "p99",
      Self.ms(Self.quantile(same, 0.99)))
    XCTAssertGreaterThan(changed.count, 0, "前提: ポインタの下の行が変わった")
    XCTAssertLessThanOrEqual(Self.quantile(all, 0.99), 1, "ポインタの移動 1 回の main の仕事")
  }

  /// 移動 1 回の main の仕事（秒）と、その移動でポインタの下の印の行が変わったか。
  struct PointerMove {
    var cpu: Double
    var changed: Bool
  }

  /// 窓 `window` のポインタを点の列 `points`（面の view の座標）へ実機の刻みで動かし、面の view へ移動の出来事を渡す。
  func movePointer(
    _ surface: MetalTextSurface, _ window: PointerWindow, through points: [CGPoint]
  ) -> [PointerMove] {
    let done = DispatchSemaphore(value: 0)
    let target = Transfer(value: surface)
    let windowTarget = Transfer(value: window)
    let moves = OSAllocatedUnfairLock(initialState: [PointerMove]())
    let thread = Thread {
      let start = CACurrentMediaTime()
      for (k, point) in points.enumerated() {
        while CACurrentMediaTime() < start + Double(k) * 0.0057 { usleep(200) }
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            let surface = target.value
            let window = windowTarget.value
            let windowPoint = surface.textView.convert(point, to: nil)
            window.pointer = windowPoint
            guard
              let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: windowPoint, modifierFlags: [],
                timestamp: CACurrentMediaTime(), windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0)
            else { return }
            let before = Self.hoveredMarkRow(surface)
            let began = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            surface.textView.mouseMoved(with: event)
            let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began) / 1e9
            let changed = Self.hoveredMarkRow(surface) != before
            moves.withLock { $0.append(PointerMove(cpu: cpu, changed: changed)) }
          }
        }
      }
      done.signal()
    }
    thread.qualityOfService = .userInteractive
    thread.start()
    while done.wait(timeout: .now()) == .timedOut {
      RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    return moves.withLock { $0 }
  }

  /// PR の diff の並びの中ほどのスレッドの返信の入力欄に打つ（`gateFieldStrokes` の関門）。
  func measurePullRequestFieldTyping(wraps: Bool) throws {
    let old = try open(
      Self.swiftSource(bytes: 1_000_000).replacingOccurrences(of: "Item", with: "Old"))
    let source = DocumentRowSource(old.document)
    let opened = try attach(Self.swiftSource(bytes: 1_000_000), wraps: wraps)
    let surface = opened.surface
    let field = ZoneTextField(id: "perf-reply", style: ThreadZone.fieldStyle())
    let thread = ThreadZone(comment: "打つ返信。", field: field)
    thread.surface = surface
    let lineCount = opened.document.text.lineCount
    let middle = lineCount / 2 / 8 * 8 + 2
    var rows = Self.pullRequestInlineRows(lineCount: lineCount, source: source)
    rows.insertions.insert(
      RowInsertion(line: middle, content: .zone(thread)),
      at: rows.insertions.firstIndex { $0.line > middle } ?? rows.insertions.count)
    surface.setPresentation(Self.pullRequestPresentation(columns: 2, wraps: wraps))
    surface.setRows(rows)
    surface.isEditable = false
    surface.updateFocus(true)
    surface.focus(field)
    surface.reveal(
      NSRange(location: opened.document.text.lineStart(middle), length: 0), policy: .center)
    gateFieldStrokes(surface, label: "zone-field 1MB pr")
    XCTAssertEqual(field.text.length, 120, "打鍵は入力欄に入る")
  }

  /// 周期 `period`（8 行ごと）が属するハンクの番号（4 周期のうち 3 周期が 1 つのハンクをなす。4 周期目は印を出せない）。nil
  /// なら印を出せない周期。
  static func hunk(ofPeriod period: Int) -> Int? {
    period % 4 == 3 ? nil : period / 4
  }

  /// スレッドの絵の差し込みを置く周期（約 1000 行ごと）か。
  static func threaded(_ period: Int) -> Bool { period % 125 == 1 }

  // MARK: - PR の diff の構成（製品の PR の構成と同じ作り）

  /// diff の構成（→ `diffPresentation`）に、行の頭のコメントの印と、行の上書き（0 はスレッドのある行、1 は書いている範囲）を
  /// 足したもの。
  static func pullRequestPresentation(columns: Int, wraps: Bool) -> SurfacePresentation {
    var presentation = diffPresentation(columns: columns)
    presentation.lineOverrides = [
      LineOverride(background: threadGround),
      LineOverride(background: draftGround, markColor: .systemPurple),
    ]
    presentation.leadingMark = pullRequestMark
    presentation.wraps = wraps
    return presentation
  }

  static let threadGround = NSColor(srgbRed: 0.56, green: 0.41, blue: 0.94, alpha: 0.14)
  static let draftGround = NSColor(srgbRed: 0.56, green: 0.41, blue: 0.94, alpha: 0.22)

  /// 製品と同じ寸法の印（頭の列 24・線 3・＋ 16×16）。
  static let pullRequestMark = LeadingMark(
    width: 24, lineWidth: 3,
    lineColor: NSColor(srgbRed: 0.56, green: 0.41, blue: 0.94, alpha: 0.55),
    size: CGSize(width: 16, height: 16),
    image: plusImage(size: 16, ground: .systemPurple, glyph: .white), dragOverride: 1)

  /// 角丸の地（無ければ透明）に ＋ を描いた絵。
  static func plusImage(size: CGFloat, ground: NSColor?, glyph: NSColor) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
      if let ground {
        ground.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
      }
      let path = NSBezierPath()
      path.move(to: CGPoint(x: rect.midX, y: rect.minY + 3))
      path.line(to: CGPoint(x: rect.midX, y: rect.maxY - 3))
      path.move(to: CGPoint(x: rect.minX + 3, y: rect.midY))
      path.line(to: CGPoint(x: rect.maxX - 3, y: rect.midY))
      path.lineWidth = 1.5
      glyph.setStroke()
      path.stroke()
      return true
    }
  }

  /// 8 行ごとに、6 行の文脈の区間と、出どころの 3 行を指す削除の差し込みと、2 行の追加の区間（→ `inlineRows`）。印を出せる
  /// 周期（→ `hunk(ofPeriod:)`。`oneHunk` なら全部の周期を 1 つのハンクにする）の行と削除行はハンクの番号を印の組にし、
  /// スレッドを置く周期は、頭の行をスレッドのある行の上書きにし、その下にスレッドの絵の差し込みを置く。
  static func pullRequestInlineRows(
    lineCount: Int, source: DocumentRowSource, oneHunk: Bool = false
  ) -> SurfaceRows {
    var insertions: [RowInsertion] = []
    var spans: [LineSpan] = []
    var old = 0
    let last = source.rowSourceContent.text.lineCount - 1
    for (period, start) in stride(from: 0, to: lineCount - 8, by: 8).enumerated() {
      let group = oneHunk ? 0 : hunk(ofPeriod: period)
      if threaded(period) {
        spans.append(
          LineSpan(line: start, otherNumber: old + 1, markGroup: group, override: 0))
        spans.append(LineSpan(line: start + 1, otherNumber: old + 2, markGroup: group))
        insertions.append(
          RowInsertion(
            line: start + 1,
            content: .zone(ThreadZone(comment: "スレッド \(period) の本文。幅で折り返す。"))))
      } else {
        spans.append(LineSpan(line: start, otherNumber: old + 1, markGroup: group))
      }
      old += 6
      let removed = (0..<3).map {
        InsertedLine(line: min(old + $0, last), style: 1, markGroup: group)
      }
      insertions.append(RowInsertion(line: start + 6, content: .lines(removed)))
      old += 3
      spans.append(LineSpan(line: start + 6, style: 0, markGroup: group))
    }
    return SurfaceRows(insertions: insertions, spans: spans, source: source)
  }

  /// 並列の左右——12 行ごとの周期の 6 行目から 3 行の詰め物を、左は奇数、右は偶数の周期に置き（→ `paddedRows`）、4 周期の
  /// うち 3 周期の行をハンクの番号を印の組にした行にする。スレッドを置く周期は、右の頭の行をスレッドのある行の上書きにして下に
  /// スレッドの絵の差し込みを、左の同じ所に相手と同じ高さの空きを置く。
  static func pullRequestSideRows(lineCount: Int) -> (left: SurfaceRows, right: SurfaceRows) {
    let pads = (0..<3).map { _ in InsertedLine(style: 2) }
    var left = SurfaceRows()
    var right = SurfaceRows()
    for (period, start) in stride(from: 0, to: lineCount - 12, by: 12).enumerated() {
      let group = hunk(ofPeriod: period)
      let pad = RowInsertion(line: start + 6, content: .lines(pads))
      if threaded(period) {
        let zone = ThreadZone(comment: "スレッド \(period) の本文。幅で折り返す。")
        right.spans.append(LineSpan(line: start, markGroup: group, override: 0))
        right.spans.append(LineSpan(line: start + 1, markGroup: group))
        right.insertions.append(RowInsertion(line: start + 1, content: .zone(zone)))
        left.insertions.append(RowInsertion(line: start + 1, content: .gap(zone)))
      } else {
        right.spans.append(LineSpan(line: start, markGroup: group))
      }
      left.spans.append(LineSpan(line: start, markGroup: group))
      if period % 2 == 0 { right.insertions.append(pad) } else { left.insertions.append(pad) }
    }
    return (left, right)
  }

  /// ポインタの下で印を出している行（無ければ nil）。
  static func hoveredMarkRow(_ surface: MetalTextSurface) -> LeadingMarkRow? {
    surface.leadingMarkHover?.row
  }
}
