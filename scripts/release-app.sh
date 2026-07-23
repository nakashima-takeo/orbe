#!/usr/bin/env bash
# Orbe.app を Developer ID で署名・公証し、配布用 DMG を作る。
# build-app.sh が自己完結バンドルを作り、こちらが配布用の署名・公証・パッケージングを担う
# （ローカル常用の ad-hoc 署名ビルドとは別）。
#
# 配布形式は DMG。zip 展開は受領者の展開ツール（unzip 等）によって framework の symlink 構造
# （Versions/Current → B）が壊れ "a sealed resource is missing or invalid" で起動不能になるため。
# ディスクイメージ内では symlink がそのまま保たれ「展開」の概念が無いのでこの問題が起きない。
# .app と DMG の両方を公証・staple する（Sparkle は DMG をマウントして .app を取り出すため
# .app 単体の staple も要る）。
#
# 事前準備（一度だけ）:
#   1. Xcode で「Developer ID Application」証明書を作成し Keychain に入れる
#   2. xcrun notarytool store-credentials orbe-notary \
#        --apple-id <Apple ID> --team-id <Team ID> --password <app用パスワード>
#
# 使い方: scripts/release-app.sh
#   環境変数で上書き可: ORBE_SIGN_ID / ORBE_NOTARY_PROFILE
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_APP="$ROOT/build/Orbe.app"     # build-app.sh の出力。開発ビルドがいつでも上書きする。
RELEASE_DIR="$ROOT/build/release"
APP="$RELEASE_DIR/Orbe.app"          # 署名・公証・staple・DMG 化は隔離したこちらに対して行う。
                                       # 公証は初回だと数時間かかることがあり、その間に BUILD_APP が
                                       # 差し替わると cdhash が変わって staple が永久に通らなくなるため。
ENTITLEMENTS="$ROOT/app/orbe.entitlements"

SIGN_ID="${ORBE_SIGN_ID:-Developer ID Application}"      # Keychain の配布用証明書
NOTARY_PROFILE="${ORBE_NOTARY_PROFILE:-orbe-notary}"   # notarytool store-credentials で作った名前

# 前提チェック（証明書が無ければ何もしないうちに止める）。
if ! security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
  echo "エラー: '$SIGN_ID' の証明書が Keychain に見つからない。Xcode で Developer ID Application を作成してください。" >&2
  exit 1
fi

# 1. 自己完結バンドルを生成し、リリース用ディレクトリへ隔離する
#    （build-app.sh は最後に ad-hoc 署名する。隔離したコピーを以降 Developer ID で署名し直す）。
#    公開ビルドは -DORBE_DEV を焼かない（「開発中の機能を有効化」トグルの未設定 default を off にする）。
export ORBE_CHANNEL=release
"$ROOT/scripts/build-app.sh"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
/usr/bin/ditto "$BUILD_APP" "$APP"   # cp -R と違い拡張属性まで正確に複製する

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

# 2. Developer ID で内側から個別署名（hardened runtime + secure timestamp）。
#    署名対象はハードコードせず、バンドル内の Mach-O を全て拾う。同梱バイナリが増えても
#    取りこぼさないため（未署名が1つでも残ると公証が Invalid で弾く）。
#    Contents/Frameworks は bundle 型 nested（XPC・Updater.app・framework 本体）を含むため
#    この flat 走査から除外し、下の bundle-aware パスで内側から署名する（flat に Mach-O 単位で
#    署名すると bundle の CodeResources 封が作られず公証が Invalid で弾く）。
echo "==> Developer ID 署名 (hardened runtime)"
while IFS= read -r bin; do
  echo "    sign: ${bin#"$APP/"}"
  codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$bin"
done < <(find "$APP/Contents" -path "$APP/Contents/Frameworks" -prune -o -type f -perm +111 \
           -exec sh -c 'file -b "$1" | grep -q "Mach-O"' _ {} \; -print)

# 2b. Contents/Frameworks の bundle-aware 署名（内側から）。各 framework について
#     ① 内包する bundle（*.xpc / *.app。Sparkle は Downloader/Installer XPC と Updater.app）
#     ② bundle 外の単体実行体（Sparkle の Autoupdate 等）
#     ③ framework 本体
#     の順で署名する。XPC の entitlements は上流の同梱値を保持する（--preserve-metadata）。
while IFS= read -r fw; do
  while IFS= read -r nested; do
    echo "    sign(bundle): ${nested#"$APP/"}"
    codesign --force --timestamp --options runtime --preserve-metadata=entitlements \
      --sign "$SIGN_ID" "$nested"
  done < <(find "$fw" \( -name "*.xpc" -o -name "*.app" \) -type d)
  #     ② の走査は nested bundle（*.xpc / *.app）を find の -prune で丸ごと除外する。
  #     以前は絶対パスに対する case "$bin" in */*.app/* で除外していたが、親バンドルの
  #     "Orbe.app/" がパスに常に含まれるため全 Mach-O が誤って除外され、Autoupdate
  #     （Versions/B/Autoupdate）が prebuilt の ad-hoc 署名のまま提出され公証 Invalid になっていた。
  while IFS= read -r bin; do
    echo "    sign: ${bin#"$APP/"}"
    codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$bin"
  done < <(find "$fw" \( -name "*.xpc" -o -name "*.app" \) -prune -o \
             -type f -perm +111 \
             -exec sh -c 'file -b "$1" | grep -q "Mach-O"' _ {} \; -print)
  echo "    sign(framework): ${fw#"$APP/"}"
  codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$fw"
done < <(find "$APP/Contents/Frameworks" -maxdepth 1 -name "*.framework" -type d 2>/dev/null)

# 最後にバンドル本体（entitlements 付き）。
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 2c. 提出前アサーション。notarytool へ上げる前に、Sparkle.framework 内の全 nested code と
#     アプリ本体が「Developer ID 署名・hardened runtime・secure timestamp」を満たすか機械検査する。
#     1つでも欠けたらその場で非ゼロ exit（1回数分〜数時間の公証を無駄撃ちしないため。
#     v0.2.0 は Autoupdate の取りこぼしを提出まで気付けず Invalid を食らった）。
assert_signed() {
  local target="$1" out rel="${1#"$APP/"}"
  out="$(codesign -dvv "$target" 2>&1)" \
    || { echo "NG 署名検査に失敗: $rel" >&2; exit 1; }
  printf '%s\n' "$out" | grep -q '^Authority=Developer ID Application' \
    || { echo "NG Developer ID 署名なし: $rel" >&2; exit 1; }
  printf '%s\n' "$out" | grep -q 'flags=[^ ]*runtime' \
    || { echo "NG hardened runtime なし: $rel" >&2; exit 1; }
  printf '%s\n' "$out" | grep -q '^Timestamp=' \
    || { echo "NG secure timestamp なし: $rel" >&2; exit 1; }
  echo "    OK: $rel"
}
echo "==> 提出前アサーション (Developer ID + runtime + timestamp)"
assert_signed "$APP"
while IFS= read -r t; do assert_signed "$t"; done < <(
  find "$APP/Contents/Frameworks" \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" \) -type d
  find "$APP/Contents" -type f -perm +111 \
    -exec sh -c 'file -b "$1" | grep -q "Mach-O"' _ {} \; -print
)

# 公証はどちらの成果物でも同じ手順（submit → status 厳格ポーリング → staple）。
# --wait は接続が切れると死ぬ。初回公証は数時間かかることがあり、その間のスリープ・ネットワーク
# 瞬断を跨いで待てる必要があるため info を自前ポーリングする。
# $1 = notarytool へ submit するパス（.app は直接出せないため zip。DMG はそのまま）。
# $2 = staple 対象（.app / .dmg）。
notarize_and_staple() {
  local submit_path="$1" staple_target="$2" rel="${2#"$RELEASE_DIR/"}"
  local submit_out sub_id info st stapled
  echo "==> 公証 submit: $rel"
  submit_out="$(xcrun notarytool submit "$submit_path" --keychain-profile "$NOTARY_PROFILE" 2>&1)"
  echo "$submit_out"
  sub_id="$(printf '%s\n' "$submit_out" | awk -F': *' '/^ *id:/{print $2; exit}')"
  [ -n "$sub_id" ] || { echo "エラー: submission id を取得できなかった: $rel" >&2; exit 1; }

  echo "==> 公証完了を待機 (id=$sub_id, $rel)"
  while :; do
    info="$(xcrun notarytool info "$sub_id" --keychain-profile "$NOTARY_PROFILE" 2>&1)" \
      || { echo "    $(date '+%H:%M:%S') info失敗（一時的?）→60s後に再試行"; sleep 60; continue; }
    st="$(printf '%s\n' "$info" | awk -F': *' '/^ *status:/{print $2}')"
    echo "    $(date '+%H:%M:%S') status=${st:-unknown}"
    case "${st:-}" in
      Accepted) break;;
      Invalid|Rejected)
        echo "エラー: 公証が通らなかった（status=${st}, $rel）。ログ:" >&2
        xcrun notarytool log "$sub_id" --keychain-profile "$NOTARY_PROFILE"
        exit 1;;
      *) sleep 60;;
    esac
  done

  # 公証チケットを添付（オフラインでも Gatekeeper が通る）。Accepted 直後はチケットが CDN に
  # 伝播しておらず "Record not found" で落ちるため、通るまで再試行する。
  echo "==> staple: $rel"
  stapled=""
  for i in $(seq 1 20); do
    if xcrun stapler staple "$staple_target"; then stapled=1; break; fi
    echo "    チケット未伝播 → 60s後に再試行 ($i/20)"
    sleep 60
  done
  [ -n "$stapled" ] || { echo "エラー: staple が完了しなかった: $rel" >&2; exit 1; }
  xcrun stapler validate "$staple_target"
}

# 3. .app を公証・staple（.app は notarytool へ直接出せないため一度 zip に固めて submit する。
#    Sparkle は DMG をマウントして .app を取り出すので、.app 単体の staple も必要）。
NOTARIZE_ZIP="$RELEASE_DIR/orbe-notarize.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
notarize_and_staple "$NOTARIZE_ZIP" "$APP"
rm -f "$NOTARIZE_ZIP"
spctl -a -vv -t exec "$APP"

# 4. 配布用 DMG を作る（read-only・圧縮）。「ドラッグでインストール」レイアウト——
#    staple 済み .app と /Applications への symlink を置く。ditto は cp -R と違い symlink・
#    拡張属性を正確に複製する。
DMG="$RELEASE_DIR/orbe-${VERSION}-macos.dmg"
DMG_STAGE="$RELEASE_DIR/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
/usr/bin/ditto "$APP" "$DMG_STAGE/Orbe.app"
ln -s /Applications "$DMG_STAGE/Applications"
echo "==> DMG 生成"
/usr/bin/hdiutil create -volname "Orbe" -srcfolder "$DMG_STAGE" \
  -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$DMG_STAGE"

# 5. DMG 自体を Developer ID で署名し、公証・staple（.app と DMG の二重公証・二重 staple）。
#    DMG は実行コードではないため hardened runtime / entitlements は不要。
echo "==> DMG 署名"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
codesign --verify --verbose=2 "$DMG"
notarize_and_staple "$DMG" "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG"

# 6. appcast.xml を生成する（Sparkle のアプリ内アップデートが読む feed。EdDSA 署名は
#    ログイン Keychain の秘密鍵で自動付与される）。最新 1 項目のみ・delta 無し（YAGNI）。
#    generate_appcast は RELEASE_DIR の DMG を拾い、enclosure が .dmg を指す appcast を作る。
#    リリースノート: ORBE_RELEASE_NOTES=<md へのパス> で渡す（DMG と同名の .md として並置すると
#    generate_appcast が description へ埋め込む。RELEASE_DIR は冒頭で作り直すため事前配置は消える）。
#    DMG と appcast.xml は必ず**同じリリースのアセット**として一緒にアップロードする——
#    SUFeedURL は releases/latest/download/appcast.xml（最新リリースのアセット）を指すため、
#    載せ忘れると全クライアントの更新確認が 404 になる。
if [ -n "${ORBE_RELEASE_NOTES:-}" ] && [ -f "$ORBE_RELEASE_NOTES" ]; then
  cp "$ORBE_RELEASE_NOTES" "$RELEASE_DIR/orbe-${VERSION}-macos.md"
fi
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/generate_appcast" ] \
  || { echo "エラー: generate_appcast が見つからない ($SPARKLE_BIN)。swift build 済みか確認せよ" >&2; exit 1; }
echo "==> appcast.xml 生成 (EdDSA 署名)"
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/nakashima-takeo/orbe/releases/download/v${VERSION}/" \
  --embed-release-notes \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  -o "$RELEASE_DIR/appcast.xml" \
  "$RELEASE_DIR"
echo "==> 完了: $DMG"
echo "==> 完了: $RELEASE_DIR/appcast.xml (DMG と同じリリースへ必ず一緒にアップロードする)"
