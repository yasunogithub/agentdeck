# AgentDeck

Native macOS (SwiftUI) control deck for AI coding-agent sessions. It watches
the local transcript directories of multiple coding agents, shows every
session as a card on a board, and lets you jump into a live terminal —
resume, tmux attach, or hand the work off to another agent.

![board](docs/screenshots/agentdeck-board-opencode2-qwen-2026-08-05.png)

## What it does

- **Session board** — cards for every local session from Claude Code,
  OpenCode, Qwen Code, Codex, pi, dsh … with running/waiting/idle state,
  archives, and AI-generated titles.
- **Live terminals** — embedded SwiftTerm views (Metal renderer) in a right
  panel, plus standalone terminal windows that persist across launches and
  restore in screen order.
- **Handoff** — continue a session with a different agent CLI
  (`handoff:` specs), copy a handoff brief to the clipboard.
- **MCP server** — exposes status / summary / session-id / reminders over
  MCP so editors and other agents can query AgentDeck (see
  [docs/mcp.md](docs/mcp.md)).
- **Extras** — dictation, file-manager style input suggestions, artifact
  browser with HTML preview, notifications, idle archiving, orphan process
  reaping, single-instance guard.

## Requirements

- macOS 26+
- Swift 6.2+ toolchain (SwiftPM)
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (fetched automatically)
- sqlite3 (system library, linked via `linkerSettings`)

## Build & run

```sh
swift build -c release
./scripts/bundle.sh          # builds and installs AgentDeck.app (+ /Applications copy)
open AgentDeck.app
```

## Project layout

```
Sources/AgentDeck/   App source (SwiftUI board, terminal, services)
scripts/             bundle.sh, icon generation
docs/                design notes, MCP docs, dated work reports
```

## Notes

- Terminal windows register themselves in `TerminalWindowState`; the set of
  open windows is persisted to UserDefaults and restored on the next launch.
- Only one instance of AgentDeck runs at a time; a second launch activates
  the existing one and exits.

## Built with AI

This app was developed primarily with **DeepSeek V4 Flash** (free tier)
driven through [OpenCode](https://opencode.ai). Want an agent to rebuild it
from scratch? Hand it [PROMPT.md](PROMPT.md) — a self-contained build brief.

## Docs

- [docs/mcp.md](docs/mcp.md) — MCP server tools
- [docs/reports/](docs/reports/) — dated implementation reports

## License

[MIT](LICENSE)
