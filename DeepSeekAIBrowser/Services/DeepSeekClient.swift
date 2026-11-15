import Foundation

struct DeepSeekClient {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct Request: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case maxTokens = "max_tokens"
        }
    }

    struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    enum ClientError: LocalizedError {
        case missingKey, badResponse, invalidPlan, server(String)
        var errorDescription: String? {
            switch self {
            case .missingKey: return "请先在设置中填写 DeepSeek API Key。"
            case .badResponse: return "DeepSeek 返回了无法识别的响应。"
            case .invalidPlan: return "AI 返回的网页操作计划格式不正确。"
            case .server(let message): return message
            }
        }
    }

    let apiKey: String
    let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    func makePlan(profile: BehaviorProfile, task: String, pageSnapshot: String) async throws -> AgentPlan {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.missingKey }
        let prompt = """
用户任务：
\(task)

当前页面摘要：
\(pageSnapshot.prefix(12000))

只返回合法 JSON：
{"message":"简短说明","actions":[{"type":"open_url|click|type|scroll|hide|close_popup|download|wait|finish","selector":"可选 CSS 选择器","text":"可选文本","url":"可选 URL","amount":0}]}
"""
        let body = Request(
            model: profile.model,
            messages: [Message(role: "system", content: profile.systemPrompt), Message(role: "user", content: prompt)],
            temperature: profile.temperature,
            maxTokens: 700
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.server(String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let content = decoded.choices.first?.message.content else { throw ClientError.badResponse }
        return try parsePlan(content)
    }

    private func parsePlan(_ content: String) throws -> AgentPlan {
        let cleaned = content.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}") else { throw ClientError.invalidPlan }
        let json = String(cleaned[start...end])
        guard let data = json.data(using: .utf8), let plan = try? JSONDecoder().decode(AgentPlan.self, from: data) else { throw ClientError.invalidPlan }
        return plan
    }
}
