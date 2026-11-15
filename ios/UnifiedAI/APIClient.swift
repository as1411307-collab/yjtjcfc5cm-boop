import Foundation

struct SessionResponse: Decodable { let session_id: String }
struct ChatResponse: Decodable { let answer: String }
struct ChatRequest: Encodable {
    let session_id: String
    let message: String
    let provider: String
}
struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    let content: String
}
struct MessageHistory: Decodable {
    struct Entry: Decodable {
        let role: String
        let content: String
    }
    let messages: [Entry]
}
enum APIError: LocalizedError {
    case invalidURL, unauthorized, server(Int), invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "عنوان الخادم غير صالح أو لا يستخدم HTTPS"
        case .unauthorized: return "مفتاح الوصول غير صحيح"
        case .server(let code): return "خطأ الخادم: \(code)"
        case .invalidResponse: return "استجابة غير صالحة"
        }
    }
}
struct APIClient {
    let server: String
    let key: String

    private func request<T: Decodable>(_ path: String, method: String = "GET",
                                       body: Data? = nil) async throws -> T {
        guard let base = URL(string: server),
              base.scheme == "https",
              base.host != nil,
              let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 100
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let session = URLSession(
            configuration: .ephemeral,
            delegate: RejectRedirects(),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if response.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(response.statusCode) else { throw APIError.server(response.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func exportSession(_ session: String) async throws -> Data {
        let result: ConversationExport = try await request("/sessions/\(session)/export")
        return try JSONEncoder().encode(result)
    }

    func searchSessions(_ query: String) async throws -> [ConversationSummary] {
        var parts = URLComponents()
        parts.path = "/sessions/search"
        parts.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let path = parts.string else { throw APIError.invalidURL }
        let result: ConversationListResponse = try await request(path)
        return result.sessions
    }

    func newSession() async throws -> String {
        let result: SessionResponse = try await request("/sessions", method: "POST")
        return result.session_id
    }

    func send(session: String, message: String, provider: String) async throws -> String {
        let body = try JSONEncoder().encode(ChatRequest(session_id: session, message: message, provider: provider))
        let result: ChatResponse = try await request("/chat", method: "POST", body: body)
        return result.answer
    }

    func deleteSession(_ session: String) async throws {
        let _: DeleteMemoryResponse = try await request("/sessions/\(session)", method: "DELETE")
    }

    func messagePage(session: String, afterID: Int = 0, limit: Int = 50) async throws -> MessagePage {
        guard session.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil,
              afterID >= 0, (1...100).contains(limit) else {
            throw APIError.invalidURL
        }
        return try await request("/sessions/\(session)/messages/page?after_id=\(afterID)&limit=\(limit)")
    }

    func insights(session: String) async throws -> ConversationInsights {
        guard session.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else {
            throw APIError.invalidURL
        }
        return try await request("/sessions/\(session)/insights")
    }

    func readiness() async throws -> ReadinessResponse {
        try await request("/health/ready")
    }

    func history(session: String) async throws -> [ChatMessage] {
        let result: MessageHistory = try await request("/sessions/\(session)/messages")
        return result.messages.map { ChatMessage(role: $0.role, content: $0.content) }
    }
}

struct PersonalMemory: Identifiable, Decodable {
    let id: String
    let content: String
}
struct MemoryListResponse: Decodable {
    let memories: [PersonalMemory]
}
struct MemoryCreateRequest: Encodable {
    let content: String
}
extension APIClient {
    func memories() async throws -> [PersonalMemory] {
        let response: MemoryListResponse = try await request("/memories")
        return response.memories
    }

    func addMemory(_ content: String) async throws {
        let body = try JSONEncoder().encode(MemoryCreateRequest(content: content))
        let _: PersonalMemory = try await request("/memories", method: "POST", body: body)
    }

    func deleteMemory(_ id: String) async throws {
        let _: DeleteMemoryResponse = try await request("/memories/\(id)", method: "DELETE")
    }
}
struct DeleteMemoryResponse: Decodable {
    let deleted: Bool
}


struct ConversationSummary: Identifiable, Decodable {
    let id: String
    let created_at: Int
    let message_count: Int
    let last_message_at: Int?
}
struct ConversationListResponse: Decodable {
    let sessions: [ConversationSummary]
}
extension APIClient {
    func sessions() async throws -> [ConversationSummary] {
        let result: ConversationListResponse = try await request("/sessions")
        return result.sessions
    }
}


struct ConversationExport: Codable {
    struct Session: Codable {
        let id: String
        let created_at: Int
    }
    struct Entry: Codable {
        let role: String
        let content: String
        let created_at: Int
    }
    let schema_version: Int
    let session: Session
    let messages: [Entry]
}


/// Never forward the API key to a URL returned in a server redirect.
private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct MessagePage: Decodable {
    struct Entry: Decodable {
        let id: Int
        let role: String
        let content: String
        let created_at: Int
    }
    let messages: [Entry]
    let next_after_id: Int
    let has_more: Bool
}

struct ReadinessResponse: Decodable {
    let status: String
}


struct ConversationInsights: Decodable {
    let message_count: Int
    let user_turns: Int
    let assistant_turns: Int
    let suggestions: [String]
    let source: String
}
