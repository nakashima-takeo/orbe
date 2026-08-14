import XCTest

@testable import OrbeSound
@testable import orbe_sound

/// Scratch エントリの整合性。壊れると resolve / board が黙って別の音へ化ける・そのカードだけ
/// 鳴らない・無音や破裂音が聴き比べに載る——制作ループの判断材料が静かに狂う。
/// Scratch は頻繁に編集する前提のファイルなので、規約はエントリを足すたびここが自動で守る。
final class ScratchTests: XCTestCase {

  /// カタログ名と衝突しない（resolve はカタログを優先するので、衝突した scratch には一生届かない。
  /// `sound-cli-contract` が優先順そのものを固定しない根拠もこの不変条件）。
  func testEntryNamesDoNotShadowCatalogNames() {
    let catalog = Set(NotificationSound.allCases.map(\.rawValue))
    for entry in Scratch.entries {
      XCTAssertFalse(catalog.contains(entry.name), "\(entry.name) はカタログ名に隠れて届かない")
    }
  }

  /// 名前は互いに一意で、ファイル名・URL・HTML 属性へ無加工で埋め込める字種だけを使う
  /// （board は名前をエスケープせず data-src / data-name / <name>.wav に流す）。
  func testEntryNamesAreUniqueAndSafeForFileURLAndHTML() {
    let names = Scratch.entries.map(\.name)
    XCTAssertEqual(Set(names).count, names.count, "名前が重複している: \(names)")
    for name in names {
      XCTAssertNotNil(
        name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression),
        "board / WAV / URL を壊し得る名前: \(name)")
    }
  }

  /// 全エントリが有限・非無音・非クリップで合成される（カタログ側の同名の網の scratch 版）。
  func testEntriesRenderFiniteAndUnclipped() {
    for entry in Scratch.entries {
      let samples = SoundRenderer.render(
        program: entry.program, volume: 100, sampleRate: 8000, seedKey: entry.name)
      var peak: Float = 0
      var finite = true
      for sample in samples {
        if !sample.isFinite { finite = false }
        peak = max(peak, abs(sample))
      }
      XCTAssertTrue(finite, "\(entry.name) に NaN / Inf")
      XCTAssertGreaterThan(peak, 0.001, "\(entry.name) が無音")
      XCTAssertLessThanOrEqual(peak, 1, "\(entry.name) がクリップ")
    }
  }
}
