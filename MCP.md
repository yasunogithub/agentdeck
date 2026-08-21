# AgentDeck MCP Server

AgentDeck は **MCP (Model Context Protocol) Server** を内蔵しています。
Cursor / Claude Desktop / opencode などの MCP クライアントから接続すると、
エージェントの**ステータス・サマリ・Resume 用セッション ID** を取得でき、
物忘れ防止・リマインドに使えます。

## 接続情報

- Transport: **Streamable HTTP** (MCP 2025-03-26)
- URL: `http://127.0.0.1:47837/mcp`
- ポート: 47837 (EventServer の 47836 とは別)
- 認証なし・localhost のみで待受・依存ライブラリなし (Network.framework)

## クライアント設定

### Cursor (`~/.cursor/mcp.json`)

```json
{
  "mcpServers": {
    "agentdeck": {
      "url": "http://127.0.0.1:47837/mcp"
    }
  }
}
```

Cursor で AgentDeck が起動している状態で設定すると、Agent が
`status` / `session_summary` / `resume_session` を呼べます。

### Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`)

```json
{
  "mcpServers": {
    "agentdeck": {
      "url": "http://127.0.0.1:47837/mcp"
    }
  }
}
```

### opencode (プロジェクトの `opencode.json`)

```json
{
  "mcp": {
    "agentdeck": {
      "type": "http",
      "url": "http://127.0.0.1:47837/mcp"
    }
  }
}
```

## 提供ツール

| Tool | 用途 |
|---|---|
| `status` | 全体ステータス (状態別セッション数・最新アクティビティ) |
| `list_sessions` | セッション一覧。状態 / 最終活動 / プロジェクト / **sessionId** / 再開コマンド |
| `session_summary` | タイトル・要約・最初の指示・最後の成果・vault 蒸留ログ |
| `resume_session` | 再開コマンド (`opencode2 --session ses_…` / `claude --resume …`) と cwd |
| `stale_sessions` | 放置リマインダ (既定10分以上動かない running/waiting/failed) |
| `vault_today` | 今日の蒸留ログ全文 |
| `vault_read` | 指定日 (YYYY-MM-DD) の蒸留ログ |

## データの出所とフォールバック

- SessionStore (hook イベント + transcript スキャン、直近7日) → 最優先
- OpenCodeDB 直接参照 (`~/.local/share/opencode/*.db`) → 保持期間外セッション
- vault 蒸留ログ (`~/dev/agentdeck/vault/YYYY-MM-DD.md`) → DB からも消えたセッション
  (opencode が DB を prune しても vault は残る = 物忘れ防止の最終防衛線)

## ヘルスチェック

```sh
curl http://127.0.0.1:47837/mcp/health
# {"ok":true,"sessions":198,"events":0,"tools":7}
```

## 手動テスト

```sh
# initialize
curl -s -X POST http://127.0.0.1:47837/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'

# ツール一覧
curl -s -X POST http://127.0.0.1:47837/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# セッション要約 (Resume 前の文脈復元)
curl -s -X POST http://127.0.0.1:47837/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"session_summary","arguments":{"sessionId":"ses_…"}}}'
```
