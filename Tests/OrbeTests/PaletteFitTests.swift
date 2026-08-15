import AppKit
import OrbeSound
import SwiftUI
import XCTest

@testable import Orbe

/// 「パレットの器は窓に収まる」という契約の検証。4 段で押さえる:
///
/// 1. **逆算そのもの**（`PaletteOverlay.layout` / `PaletteCard.listMaxHeight`）を代数で。
///    高窓・中窓・低窓・chrome ちょうど・退化域・単調性を、描画に依らず固定する。
/// 2. **プローブの被覆**——本番が引く chrome（プローブを当てたスロットの和）が、実描画で測った
///    chrome そのものと一致すること。ここが代数と実体の唯一の接合で、覆い漏れたスロットがあれば
///    そのぶんだけ本番はリストを過大に取る。代数からは原理的に届かない。
/// 3. **実測 chrome を通した鎖**——2 の値を 1 の逆算へ通し、「窓 → 余白 → カード上限 → リスト上限
///    → カード高」が窓を超えないことを面ごとに確かめる。
/// 4. **実描画で内容ぶんに止まること**——窓が余ってもカードが提案された高さまで伸びない。
///
/// カード全体の `.frame(maxHeight:)` は ideal を上限で**丸めた**値を `fittingSize` に返すため、
/// 内側が上限を超えていても実描画の高さは常に上限どおりに見える（丸めではなく切り取りになる）。
/// 超過の有無は 2＋3 で押さえ、切り取られていない見え方は gallery の `palette_fit_*` が撮る。
/// ビュー階層を歩いて実 frame を拾う方向へは行かない（脆く、腐る）。
@MainActor
final class PaletteFitTests: OrbeTestCase {
  private var windows: [NSWindow] = []

  /// 代数の検証に使う chrome。逆算は chrome の**値に依らず**成り立つので実測値である必要はない
  /// （実測は面ごとに違う——設定 root / フォント / 改名が 84、通知音が 143）。ただし下の窓高の
  /// 並びは「窓が chrome ＋ 余白 82 を割る」領域を狙って選んであるので、ここを動かすなら一緒に動かす。
  private let sampleChrome: CGFloat = 83

  override func tearDown() {
    windows.forEach { $0.orderOut(nil) }
    windows.removeAll()
    super.tearDown()
  }

  // MARK: - 1. 逆算の代数

  /// 窓に余裕があるうちは上 66 / 下 16 に張り付く。
  func testLayoutKeepsAnchorWhenWindowIsTall() {
    let layout = PaletteOverlay.layout(windowHeight: 600, chromeHeight: sampleChrome)
    XCTAssertEqual(layout.top, 66, accuracy: 0.001, "上端アンカーは定位置")
    XCTAssertEqual(layout.bottom, 16, accuracy: 0.001, "下余白は bar")
    XCTAssertEqual(layout.maxHeight, 600 - 82, accuracy: 0.001, "カードは窓 − 余白")
  }

  /// 窓が chrome ＋ 余白を割ると、上下が**同じ比率で**詰まる（片側だけ潰れない）。
  func testLayoutYieldsMarginsProportionally() {
    let chrome = sampleChrome
    for windowHeight in [CGFloat(160), 140, 120, 100, 90] {
      let layout = PaletteOverlay.layout(windowHeight: windowHeight, chromeHeight: chrome)
      XCTAssertEqual(
        layout.top / layout.bottom, 66 / 16, accuracy: 0.001,
        "窓 \(windowHeight): 余白は 66:16 の比を保つ")
      XCTAssertEqual(
        layout.maxHeight, chrome, accuracy: 0.001,
        "窓 \(windowHeight): カードは chrome を下回らない")
    }
  }

  /// 窓がちょうど chrome のとき余白はゼロ、カードは窓いっぱい。
  func testLayoutAtChromeExactly() {
    let layout = PaletteOverlay.layout(windowHeight: sampleChrome, chromeHeight: sampleChrome)
    XCTAssertEqual(layout.top, 0, accuracy: 0.001)
    XCTAssertEqual(layout.bottom, 0, accuracy: 0.001)
    XCTAssertEqual(layout.maxHeight, sampleChrome, accuracy: 0.001)
  }

  /// 退化域（窓が chrome すら入らない）。余白は無く、上限は窓高そのもの——負値は出ない。
  func testLayoutDegeneratesToWindowHeight() {
    for windowHeight in [CGFloat(60), 20, 0] {
      let layout = PaletteOverlay.layout(windowHeight: windowHeight, chromeHeight: sampleChrome)
      XCTAssertEqual(layout.top, 0, accuracy: 0.001)
      XCTAssertEqual(layout.bottom, 0, accuracy: 0.001)
      XCTAssertEqual(layout.maxHeight, windowHeight, accuracy: 0.001)
      XCTAssertGreaterThanOrEqual(layout.maxHeight, 0, "上限は負にならない")
    }
  }

  /// 窓を高くして上限が縮むことは無い（連続なドラッグでカードが跳ねない）。
  func testLayoutIsMonotonicInWindowHeight() {
    var previous: CGFloat = -1
    for height in stride(from: CGFloat(0), through: 700, by: 5) {
      let layout = PaletteOverlay.layout(windowHeight: height, chromeHeight: sampleChrome)
      XCTAssertGreaterThanOrEqual(layout.maxHeight, previous - 0.001, "窓高 \(height) で上限が縮んだ")
      XCTAssertLessThanOrEqual(layout.maxHeight, height, "上限は窓を超えない")
      previous = layout.maxHeight
    }
  }

  /// スクロール域の上限は「見た目の cap」と「窓の残り − 帯の余白」の小さい方。負にはならない。
  func testListMaxHeightTakesSmallerOfCapAndRemainder() {
    let band = PaletteCard.listPadding * 2
    let chrome = sampleChrome
    XCTAssertEqual(
      PaletteCard.listMaxHeight(maxHeight: 520, chromeHeight: chrome), PaletteCard.capHeight,
      "余裕がある窓では見た目の cap が効く")
    XCTAssertEqual(
      PaletteCard.listMaxHeight(maxHeight: 200, chromeHeight: chrome), 200 - chrome - band,
      "低い窓では残りが効く")
    XCTAssertEqual(
      PaletteCard.listMaxHeight(maxHeight: chrome + band, chromeHeight: chrome), 0,
      "帯の余白しか残らなければリストは消える")
    XCTAssertEqual(
      PaletteCard.listMaxHeight(maxHeight: chrome, chromeHeight: chrome), 0,
      "chrome ちょうどでリストは消える")
    XCTAssertEqual(
      PaletteCard.listMaxHeight(maxHeight: chrome / 2, chromeHeight: chrome), 0,
      "退化域でも負にならない")
  }

  // MARK: - 2. プローブの被覆（代数と実体の接合）

  /// 本番が `maxHeight` から引く chrome は**プローブを当てたスロットの和**（`ChromeHeightKey` の
  /// 遡上値）で、行を落として測った実描画高＝chrome そのものとは別経路で出る。両者が一致しなければ、
  /// 覆い漏れたスロットのぶんだけ本番はリストを過大に取り、カードが窓を突き抜ける。
  /// 下の代数（3）は chrome の値を所与として組むので、この一致だけは直接見るしかない。
  func testChromeProbeCoversEveryChromeSlot() {
    for (name, model) in fitCases() {
      let probed = probedChromeHeight(model)
      XCTAssertEqual(
        probed, measuredChromeHeight(model), accuracy: 1,
        "\(name): プローブが chrome を測り漏らしている（本番はこの差だけリストを過大に取る）")
    }
  }

  // MARK: - 3. 実測 chrome を通した鎖

  /// 面ごとに chrome を実描画で測り、窓高 → 余白 → カード上限 → リスト上限 → カード高を組み上げて、
  /// **ヘッダとヒントが入る限りカードが窓を超えない**ことを確かめる。面は 通知音（最も背が高い＝
  /// セグメント＋一文＋多数行・cap 到達）・フォント（cap 未満でハグ）・設定 root（cap 到達）・
  /// 改名（行ゼロ＝chrome だけ）。
  /// chrome すら入らない窓は器の側で救う対象ではない（＝退化域）ので、そこではカードが chrome の
  /// ままであること（それ以上は縮まないこと）だけを確かめる。
  func testCardFitsWindowForEveryFace() {
    for (name, model) in fitCases() {
      let chrome = measuredChromeHeight(model)
      XCTAssertGreaterThan(chrome, 0, "\(name): chrome が測れていない")
      for windowHeight in stride(from: CGFloat(60), through: 800, by: 10) {
        let layout = PaletteOverlay.layout(windowHeight: windowHeight, chromeHeight: chrome)
        let card = cardHeight(chromeHeight: chrome, maxHeight: layout.maxHeight)
        guard windowHeight >= chrome else {
          XCTAssertEqual(
            card, chrome, accuracy: 0.001,
            "\(name) / 窓 \(windowHeight): 退化域ではカードは chrome のまま（窓が切る）")
          continue
        }
        XCTAssertLessThanOrEqual(
          card + layout.top + layout.bottom, windowHeight + 0.001,
          "\(name) / 窓 \(windowHeight): カード \(card) ＋ 余白が窓を突き抜けた")
        XCTAssertLessThanOrEqual(
          card, layout.maxHeight + 0.001, "\(name) / 窓 \(windowHeight): カードが上限を超えた")
      }
    }
  }

  /// 窓が chrome ＋ 余白を割っても chrome は縮まない＝縮むのは行リストだけ。
  func testOnlyTheListShrinks() {
    for (name, model) in fitCases() {
      let chrome = measuredChromeHeight(model)
      let floor = PaletteOverlay.layout(windowHeight: chrome + 4, chromeHeight: chrome)
      XCTAssertEqual(
        cardHeight(chromeHeight: chrome, maxHeight: floor.maxHeight), chrome, accuracy: 0.001,
        "\(name): 退化域の手前ではヘッダとヒントだけが残る（chrome 実測 \(chrome)）")
    }
  }

  // MARK: - 4. 実描画で内容ぶんに止まること

  /// 窓が余ってもカードは提案された高さまで伸びず、**内容ぶんで止まる**。
  /// 面ごとの天井は「chrome ＋ リスト上限 ＋ 帯の余白」——リストがどれだけ長くてもここで頭打ちに
  /// なるので、実測がこれを超えていたらカードは中身ではなく窓に合わせて伸びている。
  func testCardStopsAtContentWhenWindowIsGenerous() {
    for (name, model) in fitCases() {
      let ceiling =
        measuredChromeHeight(model) + PaletteCard.capHeight + PaletteCard.listPadding * 2
      let height = renderedHeight(model, maxHeight: 2000)
      XCTAssertGreaterThan(height, 0, "\(name): 潰れた")
      XCTAssertLessThanOrEqual(
        height, ceiling + 0.001, "\(name): 内容を超えて伸びた（実測 \(height) / 天井 \(ceiling)）")
    }
  }

  // MARK: - 補助

  /// カード高の組み立て（実描画の逆——`fittingSize` は上限で丸めた値しか返さないため、
  /// 「超過していないか」はここで組んで確かめる）。リストの取り分が 0 なら帯ごと畳む。
  private func cardHeight(chromeHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
    let list = PaletteCard.listMaxHeight(maxHeight: maxHeight, chromeHeight: chromeHeight)
    return list > 0 ? chromeHeight + list + PaletteCard.listPadding * 2 : chromeHeight
  }

  /// 面の chrome 高の実測。行を落とせばカードは chrome そのものになる（リスト帯は行ゼロで描かれない）。
  private func measuredChromeHeight(_ model: PaletteModel) -> CGFloat {
    let rows = model.rows
    model.rows = []
    defer { model.rows = rows }
    return renderedHeight(model, maxHeight: 2000)
  }

  /// カードから遡上する `ChromeHeightKey` の合算値＝**本番が `maxHeight` から引く chrome**。
  /// `.onPreferenceChange` はカード自身が読んでも伝播を止めないので、外から重ねて掴める
  /// （`PaletteOverlay` が overlay 側で受け取っているのと同じ性質）。
  private func probedChromeHeight(_ model: PaletteModel) -> CGFloat {
    let box = ChromeProbeBox()
    _ = renderedHeight(
      PaletteCard(model: model, maxHeight: 2000)
        .onPreferenceChange(ChromeHeightKey.self) { box.value = $0 },
      maxHeight: 2000)
    return box.value
  }

  /// preference の遡上値をビューの外へ持ち出す箱。
  @MainActor private final class ChromeProbeBox {
    var value: CGFloat = -1
  }

  /// 検証に使う面。`maxHeight` を絞ったときの振る舞いが面の構成（セグメント・一文・行数）で変わるため、
  /// 背の高い順に代表を並べる。
  private func fitCases() -> [(String, PaletteModel)] {
    [
      ("sound", settingsModel { drill($0, into: "通知音") }),
      ("font", settingsModel { drill($0, into: "フォント ") }),
      ("settings_root", settingsModel { _ in }),
      ("rename", renameModel()),
    ]
  }

  /// 面へは行ラベルで潜る（添字だと設定行が 1 本増えただけで別の面を測り始め、テストが黙って嘘をつく）。
  private func drill(_ settings: SettingsPaletteModel, into labelPrefix: String) {
    guard let index = settings.render.rows.firstIndex(where: { $0.label.hasPrefix(labelPrefix) })
    else { return XCTFail("設定 root に「\(labelPrefix)」で始まる行が無い") }
    settings.render.selected = index
    settings.render.onActivate()
  }

  private func settingsModel(_ configure: (SettingsPaletteModel) -> Void) -> PaletteModel {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = 14
    global[SettingKeys.backgroundOpacity] = 90
    global[SettingKeys.backgroundBlur] = false
    global[SettingKeys.cursorStyleBlink] = false
    global[SettingKeys.defaultAgent] = "claude"
    global[SettingKeys.notificationSound] = NotificationSound.glass
    let settings = SettingsPaletteModel(
      values: ScopedSettingsValues(global: global),
      fontNames: ["Menlo", "Monaco", "SF Mono", "JetBrainsMono Nerd Font Mono"],
      agents: ["claude", "codex", "agy"],
      localization: LocalizationStore(language: .ja))
    settings.schedulePreviewEnd = { _, _ in }
    configure(settings)
    return settings.render
  }

  /// 行ゼロの面（入力欄だけのプロンプト）。リストを縮める余地が最初から無い最小の器。
  private func renameModel() -> PaletteModel {
    let model = PaletteModel()
    model.fieldVisible = true
    model.query = "infra-experiments"
    model.hint = "↵ 確定   esc 取消"
    return model
  }

  /// カードを実描画し、上限で丸めた高さを返す（`.frame(maxHeight:)` は ideal を上限で丸める）。
  private func renderedHeight(_ model: PaletteModel, maxHeight: CGFloat) -> CGFloat {
    renderedHeight(PaletteCard(model: model, maxHeight: maxHeight), maxHeight: maxHeight)
  }

  private func renderedHeight(_ card: some View, maxHeight: CGFloat) -> CGFloat {
    let host = NSHostingView(rootView: card.frame(width: 560))
    host.frame = NSRect(x: 0, y: 0, width: 560, height: maxHeight)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    windows.append(window)
    host.layoutSubtreeIfNeeded()
    // chrome の実測が preference で遡上し、リスト上限へ反映されるまで 1 パス回す。
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
  }
}
