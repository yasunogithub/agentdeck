import Foundation
import FoundationModels

/// On-device LLM via Apple Foundation Models. Fails open: every call has a
/// non-FM fallback so the app never depends on Apple Intelligence being on.
@MainActor
final class FMService {
    static let shared = FMService()

    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// 10-20 char Japanese title from the first user prompt.
    func title(forFirstPrompt prompt: String) async -> String? {
        guard isAvailable else { return nil }
        do {
            let session = LanguageModelSession(instructions: """
                あなたはセッションタイトル生成器。ユーザーの作業プロンプトを受け取り、\
                その作業が何か分かる10〜20文字の日本語タイトルを1行で返す。\
                例:「招待メール未達の調査」「Partner表の正規化設計」。説明・引用符・装飾は禁止。
                """)
            let response = try await session.respond(to: String(prompt.prefix(600)))
            let t = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : String(t.prefix(40))
        } catch {
            NSLog("AgentDeck FM title error: \(error)")
            return nil
        }
    }

    /// 10-25 char Japanese title for AI rename: derived from the whole
    /// transcript (what the session actually did), not just the first prompt.
    func suggestTitle(transcript: String) async -> String? {
        guard isAvailable else { return nil }
        do {
            let session = LanguageModelSession(instructions: """
                あなたはAIコーディングエージェントのセッションタイトル生成器。\
                セッションの会話記録を受け取り、そのセッションが結局何をしたかが分かる\
                10〜25文字の日本語タイトルを1行で返す。機能名・調査対象など作業の具体名を含めると良い。\
                説明・引用符・装飾・前置きは禁止。
                """)
            let response = try await session.respond(to: String(transcript.prefix(6000)))
            let t = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : String(t.prefix(50))
        } catch {
            NSLog("AgentDeck FM suggestTitle error: \(error)")
            return nil
        }
    }

    /// Conclusion-first summary + short timeline, in Japanese.
    func summarize(transcript: String) async -> String {
        guard isAvailable else {
            return "結論: Foundation Modelsが利用不可のため要約を生成できません（システム設定でApple Intelligenceを有効にしてください）。"
        }
        do {
            let session = LanguageModelSession(instructions: """
                あなたはAIコーディングエージェントのセッション記録を読む要約器。\
                出力は必ずこの構成・この順序で、日本語で簡潔に:
                結論: （このセッションが結局何をしたか/現状を1行で）
                その後、タイムラインを時系列で3〜7個の箇条書き（各1行、時刻は省略可）。\
                装飾・前置き・後書きは禁止。transcriptにない情報は書かない。
                """)
            let response = try await session.respond(to: String(transcript.prefix(7000)))
            return response.content
        } catch {
            return "結論: 要約の生成に失敗しました (\(error))"
        }
    }

    /// Chat about a session with its transcript as context.
    func chat(context: String, question: String, history: [(role: String, text: String)]) async -> String {
        guard isAvailable else {
            return "Foundation Modelsが利用できません（システム設定でApple Intelligenceを有効にしてください）。フォールバック: タイトルはtranscript由来で動作中です。"
        }
        do {
            let session = LanguageModelSession(instructions: """
                あなたはAIコーディングエージェントのセッション観察アシスタント。\
                以下に示すセッションtranscriptの抜粋を唯一の根拠として、ユーザーの質問に日本語で簡潔に答える。\
                根拠にないことは推測と明記する。
                """)
            var prompt = "【セッションtranscript抜粋】\n\(context)\n\n【これまでの会話】\n"
            for h in history.suffix(6) {
                prompt += "\(h.role): \(h.text)\n"
            }
            prompt += "\n【質問】\n\(question)"
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            return "FM呼び出しエラー: \(error)"
        }
    }

    /// Next-command prediction for the terminal ghost bar (Warp-style).
    /// Fails open: no FM → no suggestions.
    func nextCommands(prefix: String) async -> [String] {
        guard isAvailable else { return [] }
        do {
            let session = LanguageModelSession(instructions: """
                あなたはシェルのコマンド補完器。ユーザーがターミナルに入力中のコマンド行を渡すので、\
                次に打ちたいであろうコマンドを推測し、行単位で最大3つ返す。\
                gitリポジトリでの開発作業だと仮定してよい。\
                出力はコマンドのみ。説明・番号・引用符・装飾は禁止。
                """)
            let response = try await session.respond(to: "入力中: \(prefix)")
            let lines = response.content.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return Array(lines.prefix(3))
        } catch {
            return []
        }
    }
}
