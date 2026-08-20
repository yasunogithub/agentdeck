# PROMPT.md — Rebuild AgentDeck from scratch (AI agent brief)

> このファイルは、AI コーディングエージェントに AgentDeck をゼロから再構築させるための指示文です。
> そのままプロンプトとして渡せることを意図しています。
>
> **Actual build note:** AgentDeck was developed primarily with
> **DeepSeek V4 Flash** (free tier) driven through
> [OpenCode](https://opencode.ai) — small models can ship this if you feed
> them this brief one milestone at a time.

---

You are building **AgentDeck**, a native macOS app that gives the user a
single control deck over every local AI coding-agent session (Claude Code,
OpenCode, Qwen Code, Codex, pi, dsh …). Build it as specified below,
milestone by milestone. Do not skip the constraints.

## 1. Hard constraints

- **macOS 26+**, SwiftUI + AppKit hybrid, **SwiftPM only** (no .xcodeproj).
- `swift-tools-version:6.2`, single executable target `AgentDeck`.
- Dependencies: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
  (terminal emulation) and the system `sqlite3` library (linker setting).
- Everything runs locally. No accounts, no network calls except localhost
  servers you create yourself and reading local transcript files.
- The app must feel instant: the board renders from cached state and fills
  in as background scans complete.

## 2. What the app does

1. **Watch** the transcript directories of multiple coding-agent CLIs
   (`~/.claude/projects`, `~/.qwen/projects`, `~/.codex/sessions`,
   `~/.pi/agent/sessions`, `~/.dsh/sessions`, `~/.local/share/opencode`).
2. **Board** — every live/recent session is a card showing title, project,
   state (**running / waiting / idle**), last activity, subagent count.
   Cards support rename (manual + AI-generated titles), archive/unarchive,
   and per-project sections.
3. **Terminals** — click/⏎ opens the session in a right-hand panel with an
   embedded terminal (resume the agent CLI, or attach to its live tmux
   session when one exists). Any session can also be popped out into a
   standalone terminal window; those windows persist across launches and
   restore in screen order.
4. **Handoff** — continue a session with a *different* agent CLI, optionally
   seeding it with a handoff brief; copy-brief-to-clipboard included.
5. **MCP server** — a local MCP server exposes tools (`status`, `summary`,
   `session-id`, reminders) so editors/agents can query AgentDeck.
6. **Extras** — URL linkification, markdown preview, artifact browser with
   HTML/image/PDF preview (WebKit), dictation, shell input suggestions,
   notifications, idle archiving, per-pane font zoom, trackpad swipe to
   toggle the panel.

## 3. Architecture

```
Sources/AgentDeck/
  AgentDeckApp.swift      AppDelegate: lifecycle, key/swipe monitors,
                          single-instance guard, orphan reaping
  TranscriptScanner.swift watches transcript dirs, parses JSONL sessions
  SessionStore.swift      in-memory session model + archive/sections state
  OpenCodeDB.swift        reads the opencode sqlite DB for fast backfill
  BoardView.swift         card grid, selection, right panel host, hotkeys
  SessionRightPanel.swift embedded terminal + detail tabs
  TerminalSheetView.swift SwiftTerm view (Metal renderer), PTY lifecycle
  TerminalWindowState.swift standalone-window registry, persistence+restore
  HotkeyRouter.swift      decouples key events from actions across windows
  EventServer.swift       localhost HTTP/SSE hub announcing session changes
  MCPServer.swift         MCP tool server (status/summary/session-id/remind)
  …                       one file per small service (Notifier, Dictation…)
```

Design rules:

- **Window specs are strings.** A standalone terminal window is opened via
  `openWindow(id:"terminal", value: spec)` where spec is one of:
  | Spec | Meaning |
  |---|---|
  | `<sessionKey>` | resume the agent CLI for that session |
  | `attach:<key>\n<tmuxSession>` | attach to the live tmux mirror |
  | `handoff:<key>` | new session seeded from this one |
  | `handoffto:<target>\n<key>` | hand off to a specific other CLI |
  | `comment:<key>\n<text>` | send a comment into the running session |
  | `bare:<path>` | plain shell in a directory |
- **`TerminalWindowState`** registers each open window (spec + windowNumber),
  saves the set ordered by live window frames on close/terminate, and
  restores after launch with retries while the startup scan fills the store.
- **`HotkeyRouter`** fires typed actions so global and local key paths never
  duplicate logic.

## 4. Milestones

- **M0 Skeleton** — SwiftPM package builds; empty board window shows.
- **M1 Data** — scanner + store populate cards from one CLI's transcripts;
  states derived correctly (running/waiting/idle).
- **M2 Panel terminal** — ⏎ opens embedded SwiftTerm, spawns the right CLI
  in a PTY, cwd = session project dir.
- **M3 Pop-out windows** — spec-routed standalone windows, persistence,
  ordered restore after relaunch.
- **M4 Multi-CLI** — all six transcript sources merged; tmux attach path;
  handoff between CLIs.
- **M5 Servers** — EventServer + MCPServer; verify with an MCP client.
- **M6 Polish** — rename/archive/AI titles, artifact browser, notifications,
  dictation, zoom, swipe.
- **M7 Hardening** — single-instance guard, orphan reaping, crash-safe
  window-state saves.

## 5. Pitfalls we hit for real (do these from day one)

1. **Bundle the Metal shaders.** SwiftTerm's Metal renderer loads
   `Shaders.metal` from `Bundle.main` resources — copy it in your bundling
   script or terminals silently fall back to CPU rendering.
2. **Single-instance guard.** A second launch collides on localhost ports
   (`Address already in use`) and duplicates every terminal. On launch, if
   another instance with your bundle id is running, activate it and exit —
   *without* saving window state (you'd wipe the survivor's registry).
3. **Match hotkeys by `keyCode`, not `characters`.** With a kana IME active,
   `characters` becomes the transformed glyph; physical key codes don't lie.
4. **Dedupe restore per *session*, not per spec string.** The same session
   saved once as resume and once as `attach:` must not reopen twice.
5. **Reap orphaned agent processes on launch** (parent PID 1, matching your
   auto-spawn command line) — crashed GUIs otherwise leave CPU-eating CLI
   processes behind.
6. **Save window sets on close *and* terminate**, ordered by frames, so a
   crash can't resurrect stale tabs.

## 6. Acceptance checks

- `swift build -c release` succeeds; `scripts/bundle.sh` produces a runnable
  `AgentDeck.app`.
- Relaunch restores the same terminal windows in the same order.
- Launching twice yields exactly one app process.
- With a kana IME on, all hotkeys still fire.
- An MCP client can call `status` and get live session JSON.

## License

MIT — see [LICENSE](LICENSE).
