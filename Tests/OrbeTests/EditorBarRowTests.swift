import AppKit
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 上のバーの行（`EditorBarRow`）に、実物の部品を置いたときの置き方——右寄せの部品は右端に詰まり、落とした部品は行の枠の外へ
/// 出て押下も受けず、幅が変わっても部品は作り直されない。右端のボタンは、自分の枠と、消えたことを知らせる。今の項目の名前は、
/// 読める下限より狭くならない。
///
/// 壊れると何が起きるか: 狭い窓で、右端の主な操作のボタンが落ちる・右端から離れる。落とした部品が行の中に描かれて、ほかの
/// 部品と重なる。見えない札が、バーの右端の押下を受けて働く。窓の幅を変えるたびに、バーの入力欄（ファイル内検索の欄）が
/// 作り直され、フォーカスと変換中の文字が消える。消えたボタンの枠が残り、そこを押してもポップアップが閉じない。名前が消える
/// まで縮み、中ほどの札が消えた途端に名前が戻る。
@MainActor
final class EditorBarRowTests: OrbeTestCase {
  /// 部品の枠（`EditorBarRoot.space` の座標）の記録。
  private final class Frames {
    var byName: [String: CGRect] = [:]
    /// 右端のボタンが知らせた枠（ボタンの印ごと。消えたと知らせたボタンは除く）。
    var actions: [UUID: CGRect] = [:]
  }

  /// 押された回数。
  private final class Presses {
    var count = 0
  }

  /// 行に出す右端のボタンの名前（nil なら出さない）。名前ごとに別のボタン。
  @Observable final class Shown {
    var title: String? = "コミット"
  }

  /// 行を描いた窓（OS の表示の並びに入れない）。行の幅は `width(_:)` で替える。
  private struct Hosted {
    let host: NSView
    let frames: Frames

    /// 行（と窓）の幅を `width` にして置き直し、枠の知らせを受け取る。
    @MainActor func width(_ width: CGFloat) {
      host.window?.setContentSize(NSSize(width: width, height: Theme.Layout.editorBar))
      host.frame = NSRect(x: 0, y: 0, width: width, height: Theme.Layout.editorBar)
      host.layoutSubtreeIfNeeded()
      nextTurn()
    }

    @MainActor subscript(name: String) -> CGRect { frames.byName[name] ?? .null }
  }

  private func host<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> Hosted {
    let frames = Frames()
    let host = NSHostingView(
      rootView: EditorBarRow(content: content)
        .environment(\.editorBarActionFrame) { id, frame in
          frames.byName["action"] = frame
          frames.actions[id] = frame
        }
        .onPreferenceChange(ProbeFrames.self) { frames.byName.merge($0) { $1 } }
        .environment(\.localization, LocalizationStore(language: .ja)))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: Theme.Layout.editorBar),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    holdUntilTestEnds(window)
    return Hosted(host: host, frames: frames)
  }

  /// 右端の主な操作のボタンは、ほかの部品が落ちても落ちず、添え書きを譲って行の右端に残る。落とした部品は行の枠の外に
  /// 置かれる。落とさない部品の最小の幅の和が行の幅を越えたときだけ、ボタンは左の部品に続いて置かれ、右端で切れる。
  func testTheActionButtonStaysAtTheTrailingEdgeAfterTheOtherPartsYield() {
    let leadWidth: CGFloat = 100
    let hosted = host {
      Color.clear.frame(width: leadWidth).probe("lead")
      Color.clear.frame(width: 200).probe("chip").editorBarPart(drops: .chip)
      Color.clear.frame(width: 150).probe("hint").editorBarPart(.trailing, drops: .hint)
      EditorBarActionButton(
        title: "コミット", help: "コミット", action: {},
        detail: { Text("ステージ済み +125 −3") })
    }
    // 行の部品は、左 8・右 12 の余白の内側に置かれる。
    func trailingEdge(_ width: CGFloat) -> CGFloat { width - 12 }

    hosted.width(2000)
    XCTAssertEqual(hosted["action"].maxX, trailingEdge(2000), accuracy: 1, "広ければ右端")
    XCTAssertLessThan(hosted["chip"].maxX, trailingEdge(2000), "広ければ札は行の中")
    XCTAssertLessThan(hosted["hint"].maxX, hosted["action"].minX, "広ければ案内はボタンの左")
    let wide = hosted["action"].width

    hosted.width(50)
    let narrow = hosted["action"].width
    XCTAssertLessThan(narrow, wide, "狭ければ添え書きを譲る")
    XCTAssertGreaterThan(narrow, 0)
    // ボタンの部品は、ボタンの左に 12 の余白（案内との間）を持つ。
    let lead = Theme.Layout.editorBarActionLead
    XCTAssertEqual(
      hosted["action"].minX, hosted["lead"].maxX + 6 + 6 + lead, accuracy: 1,
      "落とさない部品が行に収まらなければ、ボタンは左の部品に続く（部品の間隔と、左寄せと右寄せの間の隙間）")
    XCTAssertGreaterThan(hosted["action"].maxX, trailingEdge(50), "右端で切れる")

    // 落とさない部品（左の部品とボタン）と間隔の和に、10 の余りを足した幅。余りには札も案内も入らない。
    let tight = 8 + leadWidth + 6 + lead + narrow + 6 + 10 + 12
    hosted.width(tight)
    XCTAssertEqual(hosted["action"].maxX, trailingEdge(tight), accuracy: 1, "札が落ちてもボタンは右端")
    XCTAssertEqual(hosted["action"].width, narrow, accuracy: 1)
    XCTAssertGreaterThanOrEqual(hosted["chip"].minX, trailingEdge(tight), "落とした札は行の枠の外")
    XCTAssertGreaterThanOrEqual(hosted["hint"].minX, trailingEdge(tight), "落とした案内は行の枠の外")
  }

  /// 行の幅が変わり、ほかの部品が落ちたり戻ったりしても、伸び縮みする部品の view は作り直されない。
  func testAPartKeepsItsViewWhileTheBarWidthChanges() throws {
    let counter = ProbeField.Counter()
    let hosted = host {
      ProbeField(counter: counter)
        .frame(minWidth: 180, idealWidth: 290, maxWidth: 290)
        .editorBarPart(grows: .findField)
      Color.clear.frame(width: 150).editorBarPart(.trailing, drops: .hint)
    }
    hosted.width(1000)
    let field = try XCTUnwrap(counter.made.first)

    hosted.width(300)
    hosted.width(1000)
    XCTAssertEqual(counter.made.count, 1, "作り直されない")
    XCTAssertTrue(field.window === hosted.host.window, "同じ view が窓に残る")
  }

  /// 落とした札は、行の枠の外に在る間、押下を受けない——札が行の右の余白に掛かっていても、その部分は描かれないので押下を受けない。行の
  /// 枠の中に戻れば押せ、また落ちれば押下を受けない。
  func testADroppedChipTakesNoPressUntilItIsBackInTheRow() throws {
    let presses = Presses()
    let hosted = host {
      Color.clear.frame(width: 250)
      EditorBarChip(
        help: "ブランチを選ぶ", action: { presses.count += 1 },
        content: { Text("feat/editor-overlay") }
      )
      .probe("chip")
      .editorBarPart(drops: .chip)
    }
    let window = try XCTUnwrap(hosted.host.window)
    placeOffscreen(window)
    // 左の部品の幅 250 と間隔を引くと、札の入る幅が残らない行の幅。
    let narrow: CGFloat = 280
    func pressTheTrailingEdge() throws {
      try click(hosted.host, at: NSPoint(x: narrow - 3, y: Theme.Layout.editorBar / 2))
      flush(window)
    }

    hosted.width(narrow)
    XCTAssertGreaterThanOrEqual(hosted["chip"].minX, narrow - 12, "前提: 札は行の枠の外")
    XCTAssertLessThan(hosted["chip"].minX, narrow - 3, "前提: 押す点は、落とした札の上")
    try pressTheTrailingEdge()
    XCTAssertEqual(presses.count, 0, "落とした札は押下を受けない")

    hosted.width(800)
    let chip = hosted["chip"]
    try click(hosted.host, at: NSPoint(x: chip.midX, y: chip.midY))
    flush(window)
    XCTAssertEqual(presses.count, 1, "行の枠の中に戻れば押せる")

    hosted.width(narrow)
    try pressTheTrailingEdge()
    XCTAssertEqual(presses.count, 1, "また落ちれば押下を受けない")
  }

  /// 行の右半分に残った札も、押下を受ける。
  func testAChipKeptInTheRightHalfOfTheRowTakesPresses() throws {
    let chipPresses = Presses()
    let syncPresses = Presses()
    let hosted = host {
      Color.clear.frame(width: 500)
      EditorBarChip(
        help: "ブランチを選ぶ", action: { chipPresses.count += 1 }, content: { Text("main") }
      )
      .fixedSize()
      .probe("chip")
      .editorBarPart(drops: .chip)
      EditorBarChip(help: "同期", action: { syncPresses.count += 1 }, content: { Text("同期") })
        .fixedSize()
        .probe("sync")
    }
    let window = try XCTUnwrap(hosted.host.window)
    placeOffscreen(window)
    let width: CGFloat = 900
    hosted.width(width)
    func press(_ frame: CGRect) throws {
      try click(hosted.host, at: NSPoint(x: frame.midX, y: frame.midY))
      flush(window)
    }

    let chip = hosted["chip"]
    XCTAssertGreaterThan(chip.minX, width / 2, "前提: 札は行の右半分")
    try press(hosted["sync"])
    XCTAssertEqual(syncPresses.count, 1, "前提: 行の右半分の、落とさない札には押下が届く")
    try press(chip)
    XCTAssertEqual(chipPresses.count, 1, "行の右半分に残った、落とせる札も押せる")
  }

  /// 右端のボタンは、ボタンごとの印で自分の枠を知らせ、消えたら枠が無いことを知らせる——画面を替えてボタンが入れ替われば、
  /// 知らせた枠は今あるボタンの分だけになる。
  func testActionButtonsReportTheirFramesAndThatTheyAreGone() throws {
    let shown = Shown()
    let hosted = host {
      if let title = shown.title {
        EditorBarActionButton(title: title, help: title, action: {}).id(title)
      }
    }
    let window = try XCTUnwrap(hosted.host.window)
    hosted.width(600)
    XCTAssertEqual(hosted.frames.actions.count, 1)
    let commit = hosted.frames.actions.keys.first

    shown.title = "レビュー"
    flush(window)
    pumpMain(
      until: { hosted.frames.actions.count == 1 && hosted.frames.actions.keys.first != commit },
      "入れ替わったボタンの枠だけが残る")

    shown.title = nil
    flush(window)
    pumpMain(until: { hosted.frames.actions.isEmpty }, "ボタンが無くなれば、枠も無くなる")
  }

  private func width<V: View>(_ view: V, _ proposed: CGFloat) -> CGFloat {
    NSHostingController(rootView: view)
      .sizeThatFits(in: NSSize(width: proposed, height: Theme.Layout.editorBar)).width
  }

  /// 今の項目の名前は、渡された幅が狭くても、先頭の 1 字と「…」の幅より狭くならない。
  func testTheNameDoesNotNarrowPastItsFirstCharacterAndAnEllipsis() {
    let font = Font.theme.editorItemButtonName
    let name = EditorReadableName("AppShell.swift") { Text($0).font(font) }
    let floor = width(Text("A…").font(font).fixedSize(), .infinity)
    let full = width(Text("AppShell.swift").font(font).fixedSize(), .infinity)

    XCTAssertEqual(width(name, 0), floor, accuracy: 0.5, "下限より狭い幅では、下限の幅")
    XCTAssertEqual(width(name, full), full, accuracy: 0.5, "収まれば全体")
  }

  /// 読める下限の幅では、名前は先頭の字と「…」として描かれる（中ほどを省いて「…」だけになることはない）。
  func testAtTheFloorTheNameIsDrawnAsItsFirstCharacterAndAnEllipsis() throws {
    let font = Font.theme.editorItemButtonName
    let floor = width(Text("A…").font(font).fixedSize(), .infinity)
    func drawn<V: View>(_ view: V) throws -> Data {
      let host = NSHostingView(
        rootView: view.frame(width: floor, height: Theme.Layout.editorBar, alignment: .leading))
      host.frame = NSRect(x: 0, y: 0, width: floor, height: Theme.Layout.editorBar)
      host.appearance = NSAppearance(named: .darkAqua)
      let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = host
      holdUntilTestEnds(window)
      host.layoutSubtreeIfNeeded()
      let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      return try XCTUnwrap(rep.tiffRepresentation)
    }
    let name = try drawn(EditorReadableName("AppShell.swift") { Text($0).font(font) })
    let expected = try drawn(Text("A…").font(font).fixedSize())

    XCTAssertNotEqual(
      expected, try drawn(Text("…").font(font).fixedSize()), "前提: 描いた姿で、字の違いが見分けられる")
    XCTAssertEqual(name, expected, "先頭の字と「…」")
  }

  /// 下限の字数を渡せば、名前は先頭のその字数と「…」の幅より狭くならない。名前がその字数より短ければ、下限は名前の全体の幅。
  func testTheFloorFollowsTheGivenPrefixLengthUpToTheWholeName() {
    let font = Font.theme.editorBarChip
    let branch = EditorReadableName("feat/editor-overlay", prefixLength: 4) { Text($0).font(font) }
    let short = EditorReadableName("ab", prefixLength: 4) { Text($0).font(font) }

    XCTAssertEqual(
      width(branch, 0), width(Text("feat…").font(font).fixedSize(), .infinity), accuracy: 0.5,
      "先頭の 4 字と「…」")
    XCTAssertEqual(
      width(short, 0), width(Text("ab").font(font).fixedSize(), .infinity), accuracy: 0.5,
      "下限は名前の全体の幅を越えない")
  }
}

/// 部品の枠を `EditorBarRoot.space` の座標で知らせる。
private struct ProbeFrames: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]

  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue()) { $1 }
  }
}

extension View {
  fileprivate func probe(_ name: String) -> some View {
    background(
      GeometryReader { geometry in
        Color.clear.preference(
          key: ProbeFrames.self, value: [name: geometry.frame(in: .named(EditorBarRoot.space))])
      })
  }
}

/// 作られた view を数える入力欄の代わり。
private struct ProbeField: NSViewRepresentable {
  final class Counter {
    var made: [NSView] = []
  }

  let counter: Counter

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    counter.made.append(view)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {}
}
