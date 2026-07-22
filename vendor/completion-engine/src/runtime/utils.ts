// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
//
// inshellisense `src/runtime/utils.ts` の trim・改変版。
// シェル実行（buildExecuteShellCommand / spawn）とパス検証（fs/path/os）の node 依存を、
// Swift 注入のネイティブ関数（src/native/exec）へ置き換える。引用・エスケープ系の純ロジックは残す。
import { CommandToken } from "./parser.js";
import { getPathSeparator, Shell } from "../utils/shell.js";
import { accessDir, executeShellCommand, homedir } from "../native/exec.js";
import { posixBasename, posixDirname, posixIsAbsolute, posixJoin } from "../utils/path.js";

// Orbe は zsh のみ。空白エスケープは `\`。
export const getShellWhitespaceEscapeChar = (_shell: Shell): string => "\\";

// バックスラッシュエスケープを免れる文字。ここに**無い** ASCII は全て `\` を前置する。
// 列挙するのは危険な文字ではなく安全な文字のほう——危険側を列挙すると必ず漏れるため。
// 非 ASCII（U+0080 以降）は zsh では通常の文字なのでそのまま通す。
// `~` を除外していないのは、先頭の `~` をホーム展開として残すため（パス補完の前提）。
const unescapedPathChar = /[A-Za-z0-9_\-./~,:@+=]/;

// 補完候補をユーザーのバッファへ挿入するときのエスケープ。挿入後の行はユーザー自身のシェルが
// 解釈するので、パスが 1 語のリテラルとして読まれる形にする。parser 側が `\ ` を解いて
// 生の token を返す（unescapeSpaceTokens）ため、ここへ来る値は常に未エスケープ。
export const escapePath = (value: string | undefined, _shell: Shell): string | undefined => {
  if (value == null) return value;
  let escaped = "";
  for (const char of value) {
    const isSafe = char.codePointAt(0)! >= 0x80 || unescapedPathChar.test(char);
    escaped += isSafe ? char : `\\${char}`;
  }
  return escaped;
};

// figspec の generator が呼ぶシェル実行（Swift 経由）。
export const buildExecuteShellCommand = (_timeout?: number, _signal?: AbortSignal) => executeShellCommand;

const isHomedir = (p: string) => p.startsWith("~");

// パス補完で token がディレクトリを指すとき、列挙すべき cwd を解決する。
// fs アクセスは native の accessDir 経由。
export const resolveCwd = async (
  cmdToken: CommandToken | undefined,
  cwd: string,
  shell: Shell,
  signal?: AbortSignal,
): Promise<{ cwd: string; pathy: boolean; complete: boolean }> => {
  if (cmdToken == null || cmdToken.complete) return { cwd, pathy: false, complete: false };
  const { token: rawToken, isQuoted: tokenQuoted } = cmdToken;
  const sep = getPathSeparator(shell);
  const escapedToken = !tokenQuoted ? rawToken.replaceAll(" ", "\\ ") : rawToken;
  if (escapedToken === "~") return { cwd: homedir(), pathy: true, complete: false };
  if (escapedToken === `~${sep}`) return { cwd: homedir(), pathy: true, complete: true };
  if (!escapedToken.includes(sep)) return { cwd, pathy: false, complete: false };
  const tokenComplete = escapedToken.endsWith(sep);
  const trimmedToken = escapedToken.endsWith(sep) ? escapedToken : posixDirname(escapedToken);
  const token = trimmedToken;
  const resolvedCwd = posixIsAbsolute(token) ? token : isHomedir(token) ? token.replace("~", homedir()) : posixJoin(cwd, token);
  try {
    signal?.throwIfAborted();
    await accessDir(resolvedCwd);
    return { cwd: resolvedCwd, pathy: true, complete: tokenComplete };
  } catch {
    const baselessCwd = resolvedCwd.substring(0, resolvedCwd.length - posixBasename(resolvedCwd).length);
    try {
      signal?.throwIfAborted();
      await accessDir(baselessCwd);
      return { cwd: baselessCwd, pathy: true, complete: tokenComplete };
    } catch {
      /* empty */
    }
    return { cwd, pathy: false, complete: false };
  }
};
