---
name: sandbox-run
description: Orbe の新ビルドを、本物の Orbe を止めずに「隔離した使い捨てインスタンス」として起こし、動作を確かめて必ず片付ける。ship の実機確認から呼ばれるほか、手元の変更を本物を止めず試したい時、自動化スキルが制御 API で無人駆動したい時に使う。「実機確認」「隔離インスタンスで動作確認」「使い捨てで試す」などの時に使う。
---

# sandbox-run — 隔離した使い捨て Orbe で動作を確かめる

Orbe の新ビルドを、本物の Orbe（常用の workspaces・control.sock）に**一切触れず**、`ORBE_STATE_DIR` で隔離した使い捨てインスタンスとして起こして動作を確かめる。claude 自身が検証対象の Orbe 内で動いていても、**本物を止めずに新ビルドを検証できる**のが要。確かめ終えたら使い捨てインスタンスは必ず消す。

二モードで使う（呼び出し目的で排他分岐）:
- **承認モード（既定）**: 人間が触って承認する。ship の実機確認、手元の変更を試したい時。
- **無人モード**: 承認ゲートを飛ばし、隔離インスタンスの control.sock を渡して制御 API で駆動する。自動化スキル（機械検証の Agent 等）向け。

## 常時効くレンズ（全モード共通）

- **本物に絶対触れない ― ① state 隔離。** 起動は必ず `ORBE_STATE_DIR="$(mktemp -d)"` を付ける（workspaces・control.sock がそのディレクトリ直下へ隔離される）。付け忘れると常用環境を汚す。**`mktemp -d` より深い場所を選ばない**——control.sock は AF_UNIX の `sun_path` 104 バイト上限を超えると**警告も出さずに無効化される**（socket が作られないだけ）。症状は「補完が出ない」「制御 API に繋がらない」という遠い場所に出て、アプリのバグに見える。
- **本物に絶対触れない ― ② 環境隔離。** 継承した親 Orbe の ghostty **リソースポインタ系**（`GHOSTTY_RESOURCES_DIR`・`TERMINFO`・`GHOSTTY_BIN_DIR` ほか。非網羅の代表）を起動時に断つ。**`ORBE_STATE_DIR` は Orbe の state しか隔離せず、プロセス環境は素通りする**——sandbox-run は多くが Orbe の端末内から起動され、その子が親の env を継ぐと新ビルドの ghostty が**旧 `/Applications` バンドルの資産を名前解決**する（chrome は新色・端末だけ旧色という偽描画になり、実機確認が phantom バグに化ける）。断てば新ビルドは自バンドルを解決する。何が継がれているかは `env | grep -i GHOSTTY` で確かめて落とす。
- **`open` は使わない。** `open` は起動中のインスタンスを前面化するだけで新ビルドに入れ替わらない。バイナリを直接叩く（`<app>/Contents/MacOS/Orbe`）。**DMG から起こすときはマウント先を指定する**（`hdiutil attach <dmg> -mountpoint <dir> -nobrowse`）——自動命名は同名ボリュームが既にあると `/Volumes/Orbe 1` へ逃げるので、古い DMG が張りっぱなしのとき別バージョンを起こす。
- **使い捨ては必ず片付ける。** 承認・NG・失敗のいずれで終わっても、手順2 で控えた PID を kill し、その state dir を消す。

## 手順

```mermaid
flowchart TD
    A[1. 起こす対象を決める] --> B[2. ORBE_STATE_DIR で隔離起動]
    B --> S[3. 煙探知を 1 本通す]
    S --> M{モード}
    M -->|承認 既定| C[4a. 触りどころ・build-id を提示<br/>AskUserQuestion で承認]
    M -->|無人| D[4b. control.sock を渡し制御 API で駆動]
    C --> E[5. 片付け]
    D --> E
```

1. **起こす対象を決める。** 既定は `./scripts/build-app.sh` でビルドした `./build/Orbe.app`（前提不足＝フル Xcode 未導入・zig 失敗などでの失敗は出力メッセージ〔`docs/guides/build.md` 参照〕に従う）。呼び出し元が別のバンドルを渡したときはそれを使う（公証済み DMG 内の `Orbe.app` など）。**対象の build-id を控える**（`/usr/libexec/PlistBuddy -c "Print :OrbeBuildID" <app>/Contents/Info.plist`）。
2. **隔離起動する。** 継承した ghostty のリソースポインタ系 env を断って起こす（レンズ②）:
   `env -u GHOSTTY_RESOURCES_DIR -u GHOSTTY_BIN_DIR -u TERMINFO ORBE_STATE_DIR="$(mktemp -d)" <app>/Contents/MacOS/Orbe &`
   `env | grep -i GHOSTTY` で他のリソースポインタ系が残っていればそれも `-u` で足す。この state dir と PID を控える（片付けに使う）。隔離インスタンスは自前の control.sock（`$ORBE_STATE_DIR/control.sock`）を持つ。
3. **煙探知を 1 本通す（両モード共通）。** `.app` の起動経路と `AppDelegate` の配線は `swift test` の守備範囲外なので、機械的に確かめる場所はここしかない。人間に見せる前に死んだバンドルを弾く意味もあるので、承認モードでも飛ばさない。
   - **必ず手順2 で控えた state dir の sock へ直接投げる。** 手元の Orbe MCP ツール（`mcp__orbe__*`）は `ORBE_STATE_DIR` を持たず**常用インスタンス**に繋がる。使うと利用者の実ペインに目印が打ち込まれたうえ、起こしたバンドルについて何も測らないまま緑になる。素の JSON-RPC で足りる:
     `printf '{"jsonrpc":"2.0","id":1,"method":"list_panes","params":{}}\n' | nc -U "$ORBE_STATE_DIR/control.sock"`
   - まず `$ORBE_STATE_DIR/control.sock` が現れるまで待つ（最大 10 秒）。GUI の起動から `ControlServer` が bind するまでには実時間があるので、待たずに叩くと健全なバンドルを不合格にする。最後まで現れなければ起動経路が `ControlServer` を張っていないということなので失敗。
   - `list_panes` でペインを取り、`send_text` に `echo L4D""ONE_<id>` を送る（`<id>` は毎回ランダム。目印の途中に**空のダブルクォート 2 つ**を挟む）。続けて `send_key enter` を送り、`get_pane_text` に連結形 `L4DONE_<id>` が現れるまで**最大 15 秒**ポーリングする。
   - 目印をコマンド行の中で 2 つのリテラルに割るのが要点で、連結形はシェルが引用符除去を**評価した**出力にしか現れない。入力行がそのまま描き返されても目印にはならないので、実 `.app` ＝利用者の rc とテーマが走る環境でも判定が揺れない。
   - 15 秒で出なければ、起こしたバンドルは制御 API から駆動できていない。駆動も承認も始めず、失敗として呼び出し側へ返す。
4. モードで分岐:
   - **承認モード（既定）**: 今回の変更が**どこに現れ・何を触って見るか**と、画面 chrome の **build-id が手順1 で控えた値か**を短く提示する（人間目視が必須の条件があればここで渡す）。`AskUserQuestion` で承認を問う。**この承認が後続（確定・マージ等）の許可**。NG・指摘があれば呼び出し側へ差し戻す。
   - **無人モード**: `$ORBE_STATE_DIR/control.sock` を呼び出し側へ渡し、制御 API で駆動して確かめる。
5. **片付ける。** 隔離インスタンスを kill し、state dir を消す。承認・NG・失敗のいずれでも必ず行う。

## Orbe の契約（このスキルが依存するもの）

- **`ORBE_STATE_DIR`**: 非空ならその直下へ workspaces・control.sock を隔離する（`StateDir` / `OrbePaths`）。全実行体（GUI・`orb` CLI・MCP）が同一解決を共有し、`orb`/`orbe-mcp` は `ORBE_STATE_DIR` 併用時に継承 `ORBE_SOCK` を無視する（隔離インスタンス操作が実 Orbe へ逸れない）。
- **`./scripts/build-app.sh`**: `./build/Orbe.app` を生成し、末尾に build-id を出す。
- **build-id**: `build-app.sh` が git 短縮 SHA を `Info.plist` の `OrbeBuildID` に刻み、chrome（`StatusRowView`）が表示する。**バンドルの同一性を名乗る唯一の値**——バージョン文字列も bundle ID も、版が違っても同じ値を取りうる。
- **`GHOSTTY_RESOURCES_DIR`（継承 env）**: ghostty が theme・shell-integration・terminfo を名前解決する起点。**Orbe が子プロセスへ export する**ため、Orbe 端末内から起こした sandbox は放置すると親（＝旧 `/Applications`）バンドルを解決する。unset すれば ghostty は実行体（＝新バンドル）から自己解決する。
- **control.sock**: `$ORBE_STATE_DIR/control.sock`。隔離インスタンスを制御 API で駆動する口。
