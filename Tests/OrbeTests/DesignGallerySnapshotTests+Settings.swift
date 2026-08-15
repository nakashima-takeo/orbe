import OrbeSound
import SwiftUI
import XCTest

@testable import Orbe

/// 設定パレットの gallery（ファイル分割の拡張。本体の型サイズ上限を守るため +Attention / +Update と
/// 同じ分け方）。撮り方・出力先・カードの地は本体（`DesignGallerySnapshotTests`）から引き継ぐ。
extension DesignGallerySnapshotTests {

  /// 設定パレット（Cmd+,）root / テーマ / 通知音サブパレット。本物の SettingsPaletteModel が render へ
  /// 立て下げた状態を Light/Dark で撮る（遷移過程は flow の settings_palette 系が担う）。
  func renderSettingsPaletteSnapshots(dir: URL, cardSize: NSSize) throws {
    // root は WS 上書きありで撮る＝「（この WS では …）」注記（muted 補足）が主値より弱く読めるか、
    // 選択行の tint 塗りの上でも読めるかを両 appearance で見る。
    let settingsRoot = settingsPaletteModel(overrideFontSize: 16, overrideTheme: .dark)
    let rootStage = NSSize(width: 500, height: 520)
    try writePNG(
      paletteSnapshot(settingsRoot.render, canvas: rootStage), size: rootStage,
      name: "palette_settings_root.png", dir: dir)

    let settingsTheme = settingsPaletteModel()
    settingsTheme.render.selected = 5  // テーマ行
    settingsTheme.render.onActivate()  // 潜る → Auto/Dark/Light の固定3択・● が実効値 Auto
    try writePNG(
      paletteSnapshot(settingsTheme.render, canvas: cardSize), size: cardSize,
      name: "palette_settings_theme.png", dir: dir)

    // 通知音: リスト直上のセグメント（試聴対象）・鳴る条件の一文・試聴中の行の EQ。
    // EQ を画に出すため、潜った後に選択を動かして試聴を起こす（入場では鳴らない＝EQ も出ない）。
    // EQ の位相は撮影時刻で決まるが、3 本の位相差が 0/0.15/0.3 あるのでどの瞬間でも高い棒が混じり、
    // 形と色は読める（working スピナーと同じ扱い＝止めない）。一方**消灯**は撮影中に起きると EQ が
    // 画から消えるので予約を止め、点く行も音案を張って `NotificationSound.default` から独立させる。
    let settingsSound = settingsPaletteModel(notificationSound: .glass)
    settingsSound.schedulePreviewEnd = { _, _ in }
    settingsSound.render.selected = 13  // 通知音行
    settingsSound.render.onActivate()  // 潜る
    settingsSound.render.onDown()  // 試聴 → その行に EQ が点く
    let soundStage = NSSize(width: 500, height: 460)
    try writePNG(
      paletteSnapshot(settingsSound.render, canvas: soundStage), size: soundStage,
      name: "palette_settings_sound.png", dir: dir)

    try renderPaletteFitSnapshots(dir: dir)
  }

  /// 低い窓での収まり。**最も背の高い面（通知音＝セグメント＋一文＋多数行）を overlay ごと**
  /// 3 段のステージで撮り、リストだけが縮んでヘッダ・セグメント・一文・ヒントが最後まで残ることを見る。
  /// overlay を通すのは、上端アンカーが 66:16 の比を保って譲る様子がここでしか出ないため。
  /// ステージ高はこの面の chrome 実測（143）から、収まり／縮み／退化域の手前が 1 枚ずつ出るよう選ぶ。
  private func renderPaletteFitSnapshots(dir: URL) throws {
    let stages: [(name: String, stage: NSSize)] = [
      // 収まり: リストが数行残り、上端アンカーは定位置（66）のまま。
      ("palette_fit_sound_low", NSSize(width: 640, height: 360)),
      // 縮み: リストが 1 行まで詰まる。ヒントは読める。
      ("palette_fit_sound_tiny", NSSize(width: 640, height: 270)),
      // 退化域の手前: リストが消え chrome だけが残り、上下の余白が 66:16 の比のまま詰まる。
      ("palette_fit_sound_floor", NSSize(width: 640, height: 200)),
    ]
    for (name, stage) in stages {
      let sound = settingsPaletteModel(notificationSound: .glass)
      sound.schedulePreviewEnd = { _, _ in }
      sound.render.selected = 13  // 通知音行
      sound.render.onActivate()  // 潜る
      try writePNG(
        paletteOverlaySnapshot(sound.render, canvas: stage), size: stage, name: "\(name).png",
        dir: dir)
    }
  }

  /// 設定パレット gallery 用の実モデル（flow の testSettingsPalette と同じ初期値）。
  private func settingsPaletteModel(
    overrideFontSize: Int? = nil, overrideTheme: ThemeMode? = nil,
    notificationSound: NotificationSound? = nil
  ) -> SettingsPaletteModel {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = 14
    global[SettingKeys.backgroundOpacity] = 90
    global[SettingKeys.backgroundBlur] = false
    global[SettingKeys.cursorStyleBlink] = false
    global[SettingKeys.defaultAgent] = "claude"
    global[SettingKeys.notificationSound] = notificationSound
    var override = SettingsLayer()
    override[SettingKeys.fontSize] = overrideFontSize
    override[SettingKeys.theme] = overrideTheme
    return SettingsPaletteModel(
      values: ScopedSettingsValues(global: global, override: override),
      fontNames: ["Menlo", "Monaco", "SF Mono"],
      agents: ["claude", "codex", "agy"],
      localization: LocalizationStore(language: .ja))
  }
}
