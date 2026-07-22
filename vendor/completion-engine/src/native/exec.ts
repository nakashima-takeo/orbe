// Swift が JSContext へ注入するネイティブ同期関数への薄いアダプタ。
// ファイルの到達確認・列挙は Swift の FileManager に直に委ね、シェルは figspec の generator が
// 任意コマンドを走らせるときだけ使う（責務分界: JS=解析と postProcess / Swift=ファイル操作とシェル実行）。

// __orbe_exec(command, cwd): 当該 cwd で `zsh -c command` を同期実行し stdout を返す
// （login PATH は env 注入・失敗/タイムアウトは空文字列）。
// __orbe_access(path): 読めるディレクトリなら true。__orbe_readdir(dir): 直下のエントリ一覧。
// __orbe_home: ホームディレクトリ絶対パス。
declare const __orbe_exec: ((command: string, cwd: string) => string) | undefined;
declare const __orbe_access: ((path: string) => boolean) | undefined;
declare const __orbe_readdir: ((dir: string) => { name: string; isDirectory: boolean }[]) | undefined;
declare const __orbe_home: string | undefined;

const callExec = (command: string, cwd: string): string =>
  typeof __orbe_exec === "function" ? __orbe_exec(command, cwd) : "";

export const homedir = (): string => (typeof __orbe_home === "string" ? __orbe_home : "~");

// シェル引数を単一引用で包む。単一引用の中では zsh は何も展開しないので、閉じ引用の打ち切り
// （`'` を `'\''` へ）だけ処理すれば任意の文字列を 1 語として安全に渡せる。
const shellQuote = (value: string): string => `'${value.replaceAll(`'`, `'\\''`)}'`;

export type ExecuteCommandOutput = { stdout: string; stderr: string; status: number };
export type ExecuteCommandInput = { command: string; args?: string[]; cwd?: string; env?: object };

// figspec の generator（script / custom）へ渡す executeShellCommand。
// args は spec とユーザーの打鍵内容に由来するため、1 語ずつ引用してから畳む。
// command は args を伴わないとき「コマンド行そのもの」として渡される契約なので引用しない
// （上流 inshellisense の escapeArgs と同じ分界）。
export const executeShellCommand = async (input: ExecuteCommandInput): Promise<ExecuteCommandOutput> => {
  const { command, args, cwd } = input;
  const full = args && args.length ? `${command} ${args.map(shellQuote).join(" ")}` : String(command);
  const stdout = callExec(full, cwd ?? homedir());
  return { stdout, stderr: "", status: 0 };
};

export type Dirent = { name: string; isFile: () => boolean; isDirectory: () => boolean };

// テンプレ（filepaths / folders）用のディレクトリ列挙（隠しファイルも含む。`.`/`..` は含まない）。
export const readdir = async (cwd: string): Promise<Dirent[]> => {
  if (typeof __orbe_readdir !== "function") return [];
  return __orbe_readdir(cwd).map((e) => ({
    name: e.name,
    isFile: () => !e.isDirectory,
    isDirectory: () => e.isDirectory,
  }));
};

// resolveCwd の到達可能性チェック（読めるディレクトリなら resolve・さもなくば throw）。
export const accessDir = async (dir: string): Promise<void> => {
  if (typeof __orbe_access !== "function" || !__orbe_access(dir)) throw new Error("not accessible");
};
