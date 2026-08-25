// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import { CommandToken } from "./parser.js";

export type Suggestion = {
  name: string;
  allNames: string[];
  description?: string;
  icon: string;
  priority: number;
  insertValue?: string;
  type?: Fig.SuggestionType;
  hidden?: boolean;
};

export type SuggestionBlob = {
  suggestions: Suggestion[];
  argumentDescription?: string;
  activeToken?: CommandToken;
  // 絞り込みと並べ替えに実際に使った現在トークン（path なら basename・isPathComplete なら ""）。
  partialCmd?: string;
  // 確定したコマンド列（root ＋ 走査で確定したサブコマンド）。runtime の再帰の復路で積む。
  commandPath?: string[];
};
