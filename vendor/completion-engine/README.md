# Orbe completion engine

`app/completion-engine.js`（commit する prebuilt バンドル）の生成元。Orbe の補完候補は
JavaScriptCore に埋め込んだこのバンドルが算出する（`Sources/Orbe/Completion/CompletionEngine.swift`）。

## 構成

- inshellisense `src/runtime/` を **trim・改変して vendor**（live fork / submodule にしない）。
  parser / suggestion / generator / template の純ロジックのみを使い、`isterm`（node-pty・
  @xterm/headless）・CLI・シェル統合は取り込まない。
- generator/template のシェル実行・ファイル操作は JS から切り離し、Swift 注入の native 関数へ置換する。
  責務分界 = **JS=解析と postProcess / Swift=ファイル操作とシェル実行**。
  - `__orbe_access(path)` / `__orbe_readdir(dir)` … `FileManager` 直。ディレクトリ名は外部から
    与えられる文字列なので、**シェルのコマンド行に載せない**（載せると引用を一段誤るだけで
    `$(…)` が展開され任意コード実行になる）。上流も `fs.access` / `fs.readdir` を使う。
  - `__orbe_exec(command, cwd)` … cwd 付き `zsh -c`・login PATH・2s 上限・stdout のみ。
    figspec の generator が任意コマンドを走らせる仕様のときだけ使う。引数は単一引用で包む。
- spec は **@withfig/autocomplete の prebuilt build から curated subset のみ**を静的 import する。

```
src/
  engine.ts            エントリ（host が __orbe_run() で同期駆動。__orbe_result に JSON）
  runtime/             inshellisense src/runtime の trim・改変
  utils/               trim 版（shell/path/unicode/log/config）
  native/exec.ts       __orbe_exec / readdir / accessDir のアダプタ
  specs/index.ts       curated spec registry
build.mjs              esbuild 設定（curated specs を 1 ファイルへ束ねる）
```

## curated spec（39 コマンド）

git, npm, pnpm, yarn, docker, docker-compose, cargo, go, kubectl, brew, gh, make,
python, pip, node, ssh, curl, tar, systemctl, ls, cd, cat, rm, cp, mv, kill, grep,
find, chmod, code, deno, mkdir, xcodebuild, volta, open, touch, source, claude, codex

`claude`・`codex` は上流に無い自家最小 spec（`src/specs/` 直置き・実 CLI の `--help` 実測由来）。
追加するには `src/specs/index.ts` に import を足して再生成するだけ（lazy-load 全網羅は段階外）。

## 再生成手順

```bash
cd vendor/completion-engine
npm ci          # esbuild の postinstall を許可: npm approve-scripts esbuild
node build.mjs  # → app/completion-engine.js を更新
git add ../../app/completion-engine.js
```

`.app` ビルド（`scripts/build-app.sh`）はこの prebuilt commit に依存し、Node は不要。

## 上流 pin（再現性）

再生成時はこの SHA から取得・差分確認する:

- inshellisense: `9c7f5fd1cf674f95605cb476814ace27df1aa224`
  （`src/runtime/{model,parser,suggestion,generator,template,runtime,utils}.ts`・
  `src/utils/{unicode,shell}.ts` 由来。上流の著作権ヘッダは各ファイル冒頭に保持する）
- @withfig/autocomplete: npm `2.692.3`（prebuilt specs。git `aef52acff84c45edde61ae610cc2c964802b9a38`）
- @fig/autocomplete-generators: npm `2.4.0`

ライセンス原本はリポジトリ root の `licenses/`、由来は root の `NOTICE` に明記（共に MIT）。
