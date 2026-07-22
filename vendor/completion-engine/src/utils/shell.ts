// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
//
// inshellisense `src/utils/shell.ts` の trim 版。Orbe は zsh のみ・macOS のみなので
// runtime が参照するパス区切りヘルパと Shell 列挙だけを残す（init/plugin/win32/git-bash は除外）。
import { posixDirname } from "./path.js";

export enum Shell {
  Zsh = "zsh",
}

const sep = "/";

export const getPathSeparator = (_shell: Shell) => sep;

export const removePathSeparator = (dir: string) => (dir.endsWith("/") ? dir.slice(0, -1) : dir);

export const addPathSeparator = (dir: string, shell: Shell) => {
  const pathSep = getPathSeparator(shell);
  return dir.endsWith(pathSep) ? dir : dir + pathSep;
};

export const getPathDirname = (dir: string, shell: Shell) => {
  const pathSep = getPathSeparator(shell);
  return dir.endsWith(pathSep) || posixDirname(dir) === "." ? dir : addPathSeparator(posixDirname(dir), shell);
};

export const endsWithPathSeparator = (dir: string, shell: Shell) => dir.endsWith(getPathSeparator(shell));
