import AppKit
import UniformTypeIdentifiers

/// 設定パレット（Cmd+,）の提示と、単一代入の適用・生成 conf 再反映の配線。
/// overlay 提示一般（WindowController+Palette）から、設定を適用するという別の関心を分離する。
extension WindowController {
  /// Cmd+,。設定パレットを開く（既に開いていれば再フォーカス）。
  func showSettingsPalette() {
    if model.overlay == .settingsPalette {
      model.settingsPalette?.focus()
      return
    }
    let values = ScopedSettingsValues(
      scope: .global,  // 開始は global スコープ
      global: settingsStore.global,
      override: current.settingsOverride ?? SettingsLayer())
    let p = SettingsPaletteModel(
      values: values,
      fontNames: FontCatalog.names(),
      allFontNames: FontCatalog.allNames(),  // タブタイトルフォント用（等幅制限なし）
      agents: agentLauncher.detectedCommands,  // 検出済みのみ（起動パレットと同じ検出結果）
      localization: localization,
      update: updateState,  // アップデートセクション（状態カード・トグル・今すぐ確認）
      cmdTapPermissionGranted: { CmdDoubleTapMonitor.globalMonitoringPermitted })
    p.onApply = { [weak self] change, scope in self?.applySetting(change, scope: scope) }
    // グローバル ⌘⌘ の権限状態行 → System Settings（プライバシーとセキュリティ › アクセシビリティ）。
    p.onOpenAccessibilitySettings = {
      guard
        let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
      else { return }
      NSWorkspace.shared.open(url)
    }
    // 言語行（descriptor 非経由）: ストア更新→メインメニュー再構築→preferredLanguage 永続化を束ねる。
    p.onSelectLanguage = { [weak self] language in
      guard let self else { return }
      self.localization.language = language
      self.onLanguageChanged?()
      AppStatePersistence.update { $0.preferredLanguage = language.rawValue }
    }
    // 通知音の試聴（サブパレットの行移動と root の音量行が共有する 1 経路）。nil は「なし」行だけで、
    // 鳴っている音を止めるだけ。案・音量ともパレットが見せているスコープの実効値で届くので、
    // ここは再生層へ渡すだけ（別の解決を持ち込まない）。
    // 「通知音のオン/オフ」が off でも鳴らす——off のまま案も音量も決め直せないと詰む。
    p.onPreviewSound = { [weak self] source, event, volume in
      guard let self else { return }
      guard let source else {
        self.soundPlayer.stopPreview()
        return
      }
      self.soundPlayer.play(source, event: event, volume: volume)
    }
    // 手持ちの音声ファイルを選ばせる。パネルは modal なのでパレットは焦点を失う——閉じた後に
    // 必ず取り戻す（`focus()` だけでは去りゆくパネルの teardown に負けることがある）。
    p.pickSoundFile = { [weak self] in
      let panel = NSOpenPanel()
      panel.allowsMultipleSelection = false
      panel.canChooseDirectories = false
      panel.allowedContentTypes = [.audio]
      let chosen = panel.runModal() == .OK ? panel.url : nil
      self?.model.settingsPalette?.focus()
      self?.reconfirmFocusNextTick()
      return chosen
    }
    // 取り込み（デコード→10 秒打ち切り→正規化→`sounds/` へ保存）。値の保存と GC は `onApply` 側。
    p.importSoundFile = { SoundFileImporter.importFile(at: $0) }
    p.onDismiss = { [weak self] in self?.dismissPalette() }
    model.settingsPalette = p
    model.overlay = .settingsPalette
    p.focus()
    reconfirmFocusNextTick()  // 別 overlay からの遷移で去りゆくカードの teardown に勝つ
  }

  /// 単一代入を、スコープに応じ global（settings.json）か workspace 上書き層へ保存し、実効設定で生成 conf を
  /// 再生成してライブ反映する（reload は applyActiveWorkspaceConfig が畳み込む）。設定パレット（onApply）・
  /// control `config_set`・AgentLauncher の default 設定が共用する（全設定が同じ 1 経路）。
  ///
  /// `target` は workspace スコープの書込先（省略時はアクティブ WS）。`Workspace` は参照型のため
  /// 非アクティブ WS でも `settingsOverride` を in-place で書ける。永続（scheduleSave）は常に、
  /// ライブ反映（applyActiveWorkspaceConfig）は global か対象がアクティブ WS の時だけ——非アクティブ
  /// WS の上書きは次回 activate 時に `current.settingsOverride` を読んで効く。
  func applySetting(
    _ change: SettingChange, scope: SettingsScope, target: Workspace? = nil
  ) {
    let target = target ?? current
    switch scope {
    case .global:
      settingsStore.applyGlobal(change)  // in-memory SSOT 変異＋即 save（書込 gate）
    case .workspace:
      var override = target.settingsOverride ?? SettingsLayer()
      override.apply(change)
      target.settingsOverride = override.isEmpty ? nil : override  // 空は上書き無しへ畳む
      scheduleSave()  // workspaces.json へ永続化（再起動越し復元）
    }
    if scope == .global || target === current { applyActiveWorkspaceConfig() }
    // カスタム音源の参照集合が変わったので、参照されなくなったファイルを回収する
    // （順序は「新ファイルを書く → ここで設定値を保存 → GC」。パレット・`orb config`・control が共有）。
    if SettingsRegistry.customSoundSourceIDs.contains(change.id) { collectCustomSoundGarbage() }
  }

  /// ドメインA のライブ反映（hard reload）を trailing debounce で 1 回へ畳む。reloadConfig は
  /// 現在の gui.conf を読み直すだけで状態を持たないため、連続変更を最後の 1 回に集約して安全。
  func scheduleConfigReload() {
    pendingConfigReload?.cancel()
    // surface アルファ更新（reloadConfig）・NSWindow 透過再適用（syncWindowOpacity）・背景ブラー再適用
    // （syncWindowBlur）を同一 tick で揃える。syncWindowBlur は libghostty が更新後の config を読むため
    // 必ず reloadConfig の後に呼ぶ。
    let work = DispatchWorkItem { [weak self] in
      Ghostty.shared.reloadConfig()
      self?.syncWindowOpacity()
      self?.syncWindowBlur()
    }
    pendingConfigReload = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
  }
}
