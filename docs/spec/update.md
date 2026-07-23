---
title: アプリ内アップデート（現状）
description: Sparkle 2 によるアプリ内アップデート — サイレント確認 → 自動DL＋署名検証 → 再起動待ちトースト（一度だけ）→ 終了時 or 即時適用。UI は自前 3 面（トースト・変更内容シート・設定›アップデート）で標準 Sparkle UI は不使用。appcast は GitHub Releases 最新リリースのアセット
updated: 2026-07-22
---

Sparkle 2 を SPM 依存として組み込み、`Sparkle.framework` を `.app` の `Contents/Frameworks` に同梱する。UI は Sparkle 標準のものを使わず、自前のユーザードライバが状態モデル（UI の唯一の情報源）へ写像し、3 面（トースト・変更内容シート・設定パレットの「アップデート」セクション）がそれだけを読む。

## フロー（既定・全トグルオン）

サイレント確認 → 自動ダウンロード＋検証（EdDSA とコード署名。Sparkle が実施）→ **再起動待ちになった瞬間に一度だけ**右下トースト → 「今すぐ再起動」＝即時適用＆再起動 / 放置・✕・「閉じる」＝終了時に自動適用。確認中・ダウンロード中・失敗は通知せず、設定の状態カードにだけ現れる。トーストは 1 バージョンにつき一度だけで、**明示的に閉じるまで残る**（✕・「今すぐ再起動」・「変更内容」でシートを開くと閉じる。時間では消えない——適用の機会は再起動/終了時で、起動しっぱなしの端末では時限通知が役目を果たさないため）。

## UI 3 面

- **トースト（右下・非モーダル）**: 「アップデートの準備ができました」＋バージョン＋「今すぐ再起動」「変更内容」＋✕。モーダル overlay とは独立の層で、パレット表示中はパレットが前。
- **変更内容シート（中央モーダル）**: トーストと設定の「変更内容」が同じここへ着地する。見出し「vX.Y.Z の変更内容」・日付とサイズ・リリースノート（appcast description の Markdown を見出し＝分類・箇条書き＝項目で描画）・「Developer ID 署名と公証を検証済み」行・「再起動して更新」「閉じる」。scrim タップ / Esc / 閉じるは同じ着地（終了時適用のまま）。↵ は「再起動して更新」。設定パレットから開いた場合は閉じるとパレットへ戻る。
- **設定›アップデート**（[settings-palette](settings-palette.md)）: 状態カード（確認中 / ダウンロード中（進捗と受信量）/ 最新です / 失敗（再試行）/ 適用待ちの 5 状態）＋現在バージョンと最終確認時刻＋トグル 3 種＋「今すぐ確認」。Single Source of Truth——トーストを見逃しても状態はここに残る。

App メニューに「更新を確認…」があり、設定の「今すぐ確認」と同一導線（設定パレットのアップデートセクションを開いて確認を走らせ、結果は状態カードに現れる）。

## トグル 3 種（既定は全オン）

- **自動でアップデートを確認** / **自動でダウンロード**: Sparkle の設定に直結（UserDefaults 永続）。標準の初回許可プロンプトは出さない（Info.plist で自動確認を既定オンに宣言）。
- **終了時に自動で適用**: Orbe 側設定（UserDefaults 永続）。Sparkle では「自動DLで staged された更新は終了時に必ず入る」ため、オフのときは自動 staging 自体を止め（実効の自動DL＝自動DL∧終了時適用）、ダウンロード・検証後は「今すぐ再起動」を押したときだけ適用する。
- 全オフ＝通知ゼロ・完全手動（背景確認で見つかっても静観し、「今すぐ確認」だけが表へ出す）。

## 配信と鍵

- appcast URL は固定: `https://github.com/nakashima-takeo/orbe/releases/latest/download/appcast.xml`（最新リリースのアセットを指す安定 URL）。**リリースには zip と appcast.xml を必ず同じアセット群として上げる**——欠くと全クライアントの更新確認が 404 になる（手順は release スキル）。
- `scripts/release-app.sh` が公証・staple 後に EdDSA 署名つき appcast.xml を生成する（最新 1 項目のみ・delta 無し。リリースノートは `ORBE_RELEASE_NOTES` で渡した Markdown を description へ埋め込む）。
- EdDSA 秘密鍵はリポジトリに入れない（リリース元 Mac のログイン Keychain 保管）。公開鍵だけを Info.plist に持つ。
- バージョン比較は `CFBundleVersion`（リリースごと整数 +1）。semver 文字列にしない——既存の "1" より小さく比較され自動更新が壊れるため。

## 起動ゲート

- release ビルド: 常に update サイクルを開始する。
- dev ビルド（`ORBE_RELEASE` 未定義）: defaults / 起動引数の `SUFeedURL` 上書きがあるときだけ開始する（dev・sandbox インスタンスが GitHub へ確認に行かない。localhost の appcast でテスト可能——ATS は loopback 許可済み）。defaults で上書きする際のドメインは dev の bundle id `dev.orbe.app.dev`。
- `.app` 以外（テスト・素の `swift build` バイナリ）: 常に不活性。

Sparkle の帰属は `NOTICE`＋`licenses/sparkle-LICENSE.txt`（[licensing](licensing.md)）。
