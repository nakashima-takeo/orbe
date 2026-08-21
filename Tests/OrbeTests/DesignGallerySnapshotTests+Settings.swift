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
    // 一覧は末尾まで送って「カスタム」行が写る状態で撮る（12 案は上に全部並んでいる）。
    // 取り込み済み＝補足に元ファイル名が出て、● と初期ハイライトもこの行に乗る。
    let settingsSound = settingsPaletteModel(
      notificationSound: .custom, customDone: importedSource)
    settingsSound.schedulePreviewEnd = { _, _ in }
    settingsSound.render.selected = 12  // 通知音行
    settingsSound.render.onActivate()  // 潜る（● はカスタム行）
    settingsSound.render.selected = 12  // 鋼へ移って試聴 → その行に EQ が点く
    settingsSound.render.selected = 13  // カスタム行へ（補足・● とともに写る）
    let soundStage = NSSize(width: 500, height: 460)
    try writePNG(
      paletteSnapshot(settingsSound.render, canvas: soundStage), size: soundStage,
      name: "palette_settings_sound.png", dir: dir)

    // カスタム設定サブ: 完了は取り込み済み・入力待ちは「（完了と同じ）」の無効行・トグルはオン。
    // 無効行が主値より弱く読めるか、フォーム面（● 無し）が一覧の面と混ざって見えないかを両 appearance で見る。
    let settingsSoundCustom = settingsPaletteModel(
      notificationSound: .custom, customDone: importedSource)
    settingsSoundCustom.schedulePreviewEnd = { _, _ in }
    settingsSoundCustom.render.selected = 12
    settingsSoundCustom.render.onActivate()  // 通知音サブ
    settingsSoundCustom.render.selected = 13  // カスタム行
    _ = settingsSoundCustom.render.onRight()  // カスタム設定サブ
    try writePNG(
      paletteSnapshot(settingsSoundCustom.render, canvas: cardSize), size: cardSize,
      name: "palette_settings_sound_custom.png", dir: dir)

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
      let sound = settingsPaletteModel(
        notificationSound: .preset(.glass), customDone: importedSource)
      sound.schedulePreviewEnd = { _, _ in }
      sound.render.selected = 12  // 通知音行
      sound.render.onActivate()  // 潜る
      try writePNG(
        paletteOverlaySnapshot(sound.render, canvas: stage), size: stage, name: "\(name).png",
        dir: dir)
    }
  }

  /// 取り込み済みカスタム音源の見本（実ファイルは要らない——行の表示に出るのはメタデータだけ）。
  private var importedSource: CustomSoundSource {
    CustomSoundSource(file: "9f2c.wav", name: "sonar-ping.mp3", duration: 1.83)
  }

  /// 設定パレット gallery 用の実モデル（flow の testSettingsPalette と同じ初期値）。
  private func settingsPaletteModel(
    overrideFontSize: Int? = nil, overrideTheme: ThemeMode? = nil,
    notificationSound: AgentSoundChoice? = nil, customDone: CustomSoundSource? = nil
  ) -> SettingsPaletteModel {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = 14
    global[SettingKeys.backgroundOpacity] = 90
    global[SettingKeys.backgroundBlur] = false
    global[SettingKeys.cursorStyleBlink] = false
    global[SettingKeys.defaultAgent] = "claude"
    global[SettingKeys.notificationSound] = notificationSound
    global[SettingKeys.notificationSoundCustomDone] = customDone
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
