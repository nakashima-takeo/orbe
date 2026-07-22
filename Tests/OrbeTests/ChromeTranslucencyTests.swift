import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// chrome 各面へ配る背景透過/ブラー値の導出（`ChromeTranslucency.resolve`）の検証。
/// 窓透過判定（`shouldBeTranslucent`）と同じ材料から effectiveOpacity/translucent/blur を畳む純関数。
final class ChromeTranslucencyTests: XCTestCase {

  /// 透過時（percent<100・非フルスクリーン）は effectiveOpacity=percent/100・translucent=true。
  func testTranslucentScalesOpacityByPercent() {
    let r = ChromeTranslucency.resolve(percent: 60, isFullScreen: false, blur: false)
    XCTAssertEqual(r.effectiveOpacity, 0.6, accuracy: 0.0001, "60% → 0.6 へスケール")
    XCTAssertTrue(r.translucent, "60%・非フルスクリーン → 透過")
    XCTAssertFalse(r.blur, "blur=false はそのまま false")
  }

  /// 透過かつ blur=true は blur を通す（すりガラス）。
  func testTranslucentPassesBlurThrough() {
    let r = ChromeTranslucency.resolve(percent: 20, isFullScreen: false, blur: true)
    XCTAssertEqual(r.effectiveOpacity, 0.2, accuracy: 0.0001, "下端 20% → 0.2")
    XCTAssertTrue(r.translucent)
    XCTAssertTrue(r.blur, "透過中の blur=true はすりガラスとして通る")
  }

  /// 100%（不透明希望）は effectiveOpacity=1・translucent=false・blur は無効化。
  /// libghostty が opaque で blur を早期 return するのと同じゲートを chrome も共有する。
  func testOpaqueCollapsesToOneAndDisablesBlur() {
    let r = ChromeTranslucency.resolve(percent: 100, isFullScreen: false, blur: true)
    XCTAssertEqual(r.effectiveOpacity, 1, "100% → 不透明（1.0）")
    XCTAssertFalse(r.translucent, "100% → 非透過")
    XCTAssertFalse(r.blur, "不透明時は blur 希望でも false へ畳む")
  }

  /// フルスクリーンは percent に関わらず不透明（背後にデスクトップが無く透過が無意味）。
  func testFullScreenIsAlwaysOpaque() {
    let r = ChromeTranslucency.resolve(percent: 60, isFullScreen: true, blur: true)
    XCTAssertEqual(r.effectiveOpacity, 1, "フルスクリーン → 不透明")
    XCTAssertFalse(r.translucent)
    XCTAssertFalse(r.blur, "フルスクリーンは blur も無効")
  }

  /// ホルダーの `update` が純関数と同じ結果を状態へ反映する（Environment 経由で各面が読む値）。
  func testUpdateAppliesResolvedState() {
    let t = ChromeTranslucency()
    t.update(percent: 80, isFullScreen: false, blur: true)
    XCTAssertEqual(t.effectiveOpacity, 0.8, accuracy: 0.0001)
    XCTAssertTrue(t.translucent)
    XCTAssertTrue(t.blur)

    t.update(percent: 100, isFullScreen: false, blur: true)
    XCTAssertEqual(t.effectiveOpacity, 1)
    XCTAssertFalse(t.translucent)
    XCTAssertFalse(t.blur)
  }

  // MARK: - 各面が塗る backstop（baseFill / additiveBase）の後方互換ゲート

  /// 不透明時、EditorPane 等が敷く `baseFill` は不透明 bgBase を保ち、
  /// StatusRow が敷く追加 `additiveBase` は clear（=最背面 BackgroundGlow の暖色 glow を透かす現行）。
  /// この非対称（置換 backstop は不透明・追加 backstop は clear）が後方互換の要——
  /// additiveBase の `translucent ?` ゲートを外すと不透明時に StatusRow が glow を覆い隠す退行になる。
  func testOpaqueKeepsBaseFillOpaqueButAdditiveBaseClear() {
    let t = ChromeTranslucency()  // 既定＝不透明（effectiveOpacity=1・translucent=false）
    XCTAssertEqual(alpha(t.baseFill), 1, accuracy: 0.0001, "不透明時 baseFill は不透明 bgBase")
    XCTAssertEqual(alpha(t.additiveBase), 0, accuracy: 0.0001, "不透明時 additiveBase は clear")
  }

  /// 透過時、両 backstop とも effectiveOpacity で等しく薄まる（端末面と同濃度の均一 veil）。
  func testTranslucentScalesBothFillsEqually() {
    let t = ChromeTranslucency()
    t.update(percent: 60, isFullScreen: false, blur: false)
    XCTAssertEqual(alpha(t.baseFill), 0.6, accuracy: 0.0001, "透過 60% → baseFill は 0.6 へ")
    XCTAssertEqual(alpha(t.additiveBase), 0.6, accuracy: 0.0001, "透過時 additiveBase も同濃度 0.6")
  }

  /// SwiftUI Color の実効アルファ（bgBase の基底 α=1 なので `.opacity(x)` は x に等しい）。
  private func alpha(_ color: Color) -> CGFloat { NSColor(color).alphaComponent }
}
