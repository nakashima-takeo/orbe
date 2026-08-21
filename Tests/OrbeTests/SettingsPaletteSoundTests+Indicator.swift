import OrbeSound
import XCTest

@testable import Orbe

/// 試聴インジケータ（EQ）——鳴らした行の右端に出て、その音の長さぶんで畳む——と、root 音量行の試聴。
/// 「鳴らして EQ を立てる」は面に依らない 1 経路（`playPreview`）で、サブパレットの行移動と root の
/// ←/→ が同じ道を通る。ここはその 1 経路が**どちらの入口から入っても同じに見えること**を押さえる。
@MainActor
extension SettingsPaletteSoundTests {
  // MARK: - 試聴中の EQ（鳴っている行だけに出る）

  /// 鳴り終わりの予約を溜め、手で発火させる（合成長ぶん実時間を待たずに消灯を見る）。
  private func captureScheduledEnds(_ p: SettingsPaletteModel) -> () -> [() -> Void] {
    var ends: [() -> Void] = []
    p.schedulePreviewEnd = { _, fire in ends.append(fire) }
    return { ends }
  }

  /// 入場では EQ が出ず、試聴すると今いる行に出る。
  func testPreviewLightsIndicatorOnCurrentRow() {
    let p = model(sound: .preset(.glass))
    _ = captureScheduledEnds(p)
    drillIn(p)
    XCTAssertNil(p.render.rowAccessory, "入場では鳴らないので EQ も出ない")
    p.render.onDown()
    XCTAssertEqual(p.render.rowAccessory?.row, p.render.selected)
  }

  /// 解除行では鳴らないので EQ も出ない（鳴っていた EQ も畳む）。
  func testOffRowShowsNoIndicator() {
    let p = model(sound: .preset(.glass))
    _ = captureScheduledEnds(p)
    drillIn(p)
    p.render.onDown()
    XCTAssertNotNil(p.render.rowAccessory)
    p.render.selected = 0  // なし（オフ）
    XCTAssertNil(p.render.rowAccessory, "解除行では EQ を出さない")
  }

  /// 鳴り終わると EQ が消える。
  func testIndicatorClearsWhenSoundEnds() {
    let p = model(sound: .preset(.glass))
    let ends = captureScheduledEnds(p)
    drillIn(p)
    p.render.onDown()
    XCTAssertEqual(ends().count, 1)
    ends()[0]()
    XCTAssertNil(p.render.rowAccessory, "鳴り終わりで畳む")
  }

  /// 先行する消灯予約は後の試聴を消さない（↑↓ 連打で EQ が食い違わない）。
  func testStaleEndDoesNotClearLaterPreview() {
    let p = model(sound: .preset(.glass))
    let ends = captureScheduledEnds(p)
    drillIn(p)
    p.render.onDown()
    p.render.onDown()
    XCTAssertEqual(ends().count, 2)
    ends()[0]()  // 1 回目の予約が後から届く
    XCTAssertEqual(p.render.rowAccessory?.row, p.render.selected, "最後の試聴の EQ は残る")
  }

  /// 面を離れると EQ は畳まれ、予約中の消灯も無効化される。
  func testIndicatorClearsOnLeavingTheMode() {
    let p = model(sound: .preset(.glass))
    let ends = captureScheduledEnds(p)
    drillIn(p)
    p.render.onDown()
    p.render.onEscape()  // root へ
    XCTAssertNil(p.render.rowAccessory)
    ends()[0]()  // 予約が後から届いても何も起きない
    XCTAssertNil(p.render.rowAccessory)
  }

  // MARK: - root 音量行の試聴（音量は数字でなく耳で決める）

  /// ←/→ で値が動くたび、**変更後の**音量で現在の実効案の `done` が鳴る。
  func testVolumeStepPreviewsWithTheNewVolume() {
    let p = model(sound: .preset(.glass))  // 音量は既定 90
    let previews = capturePreviews(p)
    _ = captureScheduledEnds(p)
    p.render.selected = volumeRow
    _ = p.render.onRight()
    XCTAssertEqual(previews(), [Preview.synth(.glass, event: .done, volume: 95)])
  }

  /// 端でクランプされて値が動かなかった押下では鳴らさない（確かめる対象が無く、長押しで鳴り続けるだけ）。
  func testClampedStepDoesNotPreview() {
    let top = model(volume: 100)
    let topPreviews = capturePreviews(top)
    let topChanges = captureChanges(top)
    top.render.selected = volumeRow
    _ = top.render.onRight()
    XCTAssertTrue(topPreviews().isEmpty)
    XCTAssertTrue(topChanges().isEmpty, "値も書かれない（鳴るのは書けたときだけ）")

    let bottom = model(volume: 5)
    let bottomPreviews = capturePreviews(bottom)
    let bottomChanges = captureChanges(bottom)
    bottom.render.selected = volumeRow
    bottom.render.onLeft()
    XCTAssertTrue(bottomPreviews().isEmpty)
    XCTAssertTrue(bottomChanges().isEmpty)
  }

  /// 通知音のオン/オフが off でも鳴る（off のまま音量を決められないと詰む）。保持している案がそのまま鳴る。
  func testVolumeStepPreviewsEvenWhenDisabled() {
    let p = model(sound: .preset(.glass), enabled: false)
    let previews = capturePreviews(p)
    let changes = captureChanges(p)
    _ = captureScheduledEnds(p)
    p.render.selected = volumeRow
    _ = p.render.onRight()
    XCTAssertEqual(previews().last?.source, .synth(.glass))
    XCTAssertEqual(changes().map(\.id), [.notificationSoundVolume], "オン/オフは書き換えない")
  }

  /// EQ は音量行に出て、鳴り終わりで畳む（サブパレットの試聴と同じ 1 経路）。
  func testVolumeStepLightsIndicatorOnTheVolumeRow() {
    let p = model(sound: .preset(.glass))
    let ends = captureScheduledEnds(p)
    p.render.selected = volumeRow
    _ = p.render.onRight()
    XCTAssertEqual(p.render.rowAccessory?.row, volumeRow)
    XCTAssertEqual(ends().count, 1)
    ends()[0]()
    XCTAssertNil(p.render.rowAccessory, "鳴り終わりで畳む")
  }

  /// サブパレットで試聴対象を「入力待ち」にして戻っても、root が鳴らすのは `done`
  /// ——面の状態（`previewEvent`）は面をまたいで漏れない。
  func testRootPreviewIgnoresSubpalettePreviewTarget() {
    let p = model(sound: .preset(.glass))
    let previews = capturePreviews(p)
    _ = captureScheduledEnds(p)
    drillIn(p)
    XCTAssertTrue(p.render.onTab())  // 試聴対象を入力待ちへ
    p.render.onEscape()  // root へ
    p.render.selected = volumeRow
    _ = p.render.onRight()
    XCTAssertEqual(previews().last?.event, .done)
  }

  /// 絞り込みで行集合が入れ替わると EQ を畳む（EQ は行 index で位置を持つので、無関係な行を指させない）。
  func testFilteringFoldsTheIndicator() {
    let p = model(sound: .preset(.glass))
    _ = captureScheduledEnds(p)
    p.render.selected = volumeRow
    _ = p.render.onRight()
    XCTAssertNotNil(p.render.rowAccessory)
    p.render.query = "テーマ"
    p.render.onQueryChange()
    XCTAssertNil(p.render.rowAccessory)
  }
}
