import AppKit
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 上のバーの行（`EditorBarRow`）に、実物の部品を置いたときの置き方——右寄せの部品は右端に詰まり、落とした部品は行の枠の外へ
/// 出て、幅が変わっても部品は作り直されない。今の項目の名前は、読める下限より狭くならない。
///
/// 壊れると何が起きるか: 狭い窓で、右端の主な操作のボタンが落ちる・右端から離れる。落とした部品が行の中に描かれて、ほかの
/// 部品と重なる。窓の幅を変えるたびに、バーの入力欄（ファイル内検索の欄）が作り直され、フォーカスと変換中の文字が消える。
/// 名前が消えるまで縮み、中ほどの札が消えた途端に名前が戻る。
@MainActor
final class EditorBarRowTests: OrbeTestCase {
  /// 部品の枠（`EditorBarRoot.space` の座標）の記録。
  private final class Frames {
    var byName: [String: CGRect] = [:]
  }

  /// 行を描いた窓（OS の表示の並びに入れない）。行の幅は `width(_:)` で替える。
  private struct Hosted {
    let host: NSView
    let frames: Frames

    /// 行の幅を `width` にして置き直し、枠の知らせを受け取る。
    @MainActor func width(_ width: CGFloat) {
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
        .environment(\.editorBarActionFrame) { frames.byName["action"] = $0 }
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

  /// 今の項目の名前は、渡された幅が狭くても、先頭の 1 字と「…」の幅より狭くならない。
  func testTheNameDoesNotNarrowPastItsFirstCharacterAndAnEllipsis() {
    func width<V: View>(_ view: V, _ proposed: CGFloat) -> CGFloat {
      NSHostingController(rootView: view)
        .sizeThatFits(in: NSSize(width: proposed, height: Theme.Layout.editorBar)).width
    }
    let font = Font.theme.editorItemButtonName
    let name = EditorReadableName("AppShell.swift") { Text($0).font(font) }
    let floor = width(Text("A…").font(font).fixedSize(), .infinity)
    let full = width(Text("AppShell.swift").font(font).fixedSize(), .infinity)

    XCTAssertEqual(width(name, 0), floor, accuracy: 0.5, "下限より狭い幅では、下限の幅")
    XCTAssertEqual(width(name, full), full, accuracy: 0.5, "収まれば全体")
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
