// agy（Antigravity CLI）の自家 spec。上流 @withfig/autocomplete に無いため直置き。
// agy 1.5.14 の `agy --help` に載るサブコマンドとオプションを載せる（サブコマンドの中のサブコマンドとオプション・値の候補・generator は持たない）。
const spec: Fig.Spec = {
  name: "agy",
  description: "Antigravity CLI",
  subcommands: [
    { name: "acp", description: "Start the Agent Client Protocol (ACP) stdio server" },
    { name: ["agent", "agents"], description: "List available agents" },
    { name: "changelog", description: "Show changelog and release notes" },
    { name: "help", description: "Show help for subcommands" },
    { name: "install", description: "Configure environment paths and shell settings" },
    { name: "mcp", description: "Manage MCP servers (add, remove, list, enable, disable)" },
    { name: "mic-serve", description: "Serve this machine's microphone to a CLI on another host" },
    { name: "models", description: "List available models" },
    { name: ["plugin", "plugins"], description: "Manage plugins (install, uninstall, list, enable, disable)" },
    { name: "remote-control", description: "Manage the remote-control background daemon (start, status, stop)" },
    { name: "update", description: "Update CLI" },
  ],
  options: [
    {
      name: "--add-dir",
      description: "Add a directory to the workspace (repeatable)",
      args: { name: "dir" },
    },
    {
      name: "--agent",
      description: "Agent for the current CLI session",
      args: { name: "agent" },
    },
    { name: ["-c", "--continue"], description: "Continue the most recent conversation" },
    {
      name: "--conversation",
      description: "Resume a previous conversation by ID",
      args: { name: "id" },
    },
    { name: "--dangerously-skip-permissions", description: "Auto-approve all tool permission requests without prompting" },
    { name: "--disable-slash-commands", description: "Disable slash command and skill expansion in print mode" },
    {
      name: "--effort",
      description: "Reasoning effort for the current CLI session (low|medium|high|xhigh|max)",
      args: { name: "effort" },
    },
    {
      name: ["-i", "--prompt-interactive"],
      description: "Run an initial prompt interactively and continue the session",
      args: { name: "prompt" },
    },
    {
      name: "--input-format",
      description: "Input format for print mode (text, stream-json)",
      args: { name: "format" },
    },
    {
      name: "--json-schema",
      description: "Optional JSON schema string or path to a schema file to enforce structured output",
      args: { name: "schema" },
    },
    {
      name: "--log-file",
      description: "Override CLI log file path",
      args: { name: "path" },
    },
    {
      name: "--mode",
      description: "Set the agent execution mode for this session (accept-edits, auto, plan)",
      args: { name: "mode" },
    },
    {
      name: "--model",
      description: "Model for the current CLI session",
      args: { name: "model" },
    },
    { name: "--new-project", description: "Create a new project for this session" },
    {
      name: "--output-format",
      description: "Output format for print mode (text, json, stream-json)",
      args: { name: "format" },
    },
    {
      name: ["-p", "--print", "--prompt"],
      description: "Run a single prompt non-interactively and print the response",
      args: { name: "prompt" },
    },
    {
      name: "--print-timeout",
      description: "Optional time limit for print mode; 0 waits until the turn completes",
      args: { name: "duration" },
    },
    {
      name: "--project",
      description: "Project ID or project name for the current CLI session",
      args: { name: "project" },
    },
    { name: "--remote-agent", description: "Run this session's conversations using remote agents" },
    { name: "--remote-control", description: "Create a remote connection for the CLI session on start up" },
    { name: "--sandbox", description: "Run in a sandbox with terminal restrictions enabled" },
    {
      name: "--settings",
      description: "Settings for this session only, never saved: a JSON object of settings.json keys, inline or as a file path",
      args: { name: "settings" },
    },
  ],
};

export default spec;
