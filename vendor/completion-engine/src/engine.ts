// Orbe 補完エンジンの入口。esbuild が IIFE バンドルし JSC が evaluateScript で読む。
// host（Swift）は __orbe_buffer / __orbe_cwd を JS グローバルへ置いてから __orbe_run() を
// evaluateScript で呼ぶ。complete() は全 await が同期 native（__orbe_exec）に解決するため、
// evaluateScript 後の microtask drain で __orbe_result（JSON 文字列）が確定する。
import { getSuggestions } from "./runtime/runtime.js";
import { Shell } from "./utils/shell.js";

type Choice = { name: string; description: string; insertValue?: string; type?: string };
// replaceLength: 現在トークン（activeToken）の文字数。host は accept 時 cursor-replaceLength..cursor を
// 候補の insertValue ?? name で置換する（フラグの `=` 分割・パス接頭辞は activeToken/insertValue が織込み済み）。
type EngineResult = { suggestions: Choice[]; replaceLength: number };

const empty: EngineResult = { suggestions: [], replaceLength: 0 };

const complete = async (buffer: string, cwd: string): Promise<EngineResult> => {
  const blob = await getSuggestions(buffer, cwd, Shell.Zsh);
  if (blob == null) return empty;
  const suggestions: Choice[] = blob.suggestions
    .filter((s) => s.name.length > 0)
    .map((s) => ({ name: s.name, description: s.description ?? "", insertValue: s.insertValue, type: s.type }));
  const replaceLength = blob.activeToken != null ? [...blob.activeToken.token].length : 0;
  return { suggestions, replaceLength };
};

const g = globalThis as unknown as {
  __orbe_buffer?: string;
  __orbe_cwd?: string;
  __orbe_result: string | null;
  __orbe_run: () => void;
};

g.__orbe_run = () => {
  g.__orbe_result = null;
  complete(g.__orbe_buffer ?? "", g.__orbe_cwd ?? "")
    .then((r) => {
      g.__orbe_result = JSON.stringify(r);
    })
    .catch(() => {
      g.__orbe_result = JSON.stringify(empty);
    });
};
