// claude（Claude Code CLI）の自家最小 spec。上流 @withfig/autocomplete に無いため直置き。
// claude 2.1.215 の `claude --help` 実測から主要 subcommand/option のみ収載（純静的・
// generator/テンプレートは持たない。追加網羅はしない）。
const spec: Fig.Spec = {
  name: "claude",
  description: "Claude Code - starts an interactive session by default",
  subcommands: [
    { name: "agents", description: "Manage agent configurations" },
    { name: "auth", description: "Manage authentication and account" },
    { name: "doctor", description: "Check the health of your Claude Code installation" },
    { name: "install", description: "Install Claude Code native build" },
    { name: "mcp", description: "Configure and manage MCP servers" },
    { name: "plugin", description: "Manage Claude Code plugins" },
    { name: "project", description: "Manage project settings" },
    { name: "setup-token", description: "Set up a long-lived authentication token" },
    { name: "update", description: "Check for updates and install if available" },
  ],
  options: [
    {
      name: ["-p", "--print"],
      description: "Print response and exit (useful for pipes)",
    },
    {
      name: ["-c", "--continue"],
      description: "Continue the most recent conversation",
    },
    {
      name: ["-r", "--resume"],
      description: "Resume a conversation",
    },
    {
      name: "--model",
      description: "Model for the current session",
      args: { name: "model" },
    },
    {
      name: "--permission-mode",
      description: "Permission mode to use for the session",
      args: { name: "mode" },
    },
    {
      name: "--dangerously-skip-permissions",
      description: "Bypass all permission checks",
    },
    {
      name: "--add-dir",
      description: "Additional directories to allow tool access to",
      args: { name: "directories" },
    },
    { name: ["-d", "--debug"], description: "Enable debug mode" },
    { name: ["-v", "--version"], description: "Output the version number" },
    { name: ["-h", "--help"], description: "Display help for command" },
  ],
};

export default spec;
