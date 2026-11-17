import CryptoKit
import Foundation

struct SessionResponse: Decodable { let session_id: String }
struct ChatResponse: Decodable {
    let answer: String
    let request_id: String?
    let idempotent_replay: Bool?
}
struct ChatRequest: Encodable {
    let session_id: String
    let message: String
    let provider: String
    let request_id: String
    let include_context: Bool
}
struct LearningCursorPage {
    let next_after_id: Int
    let has_more: Bool
}
struct ChatMessage: Identifiable {
    var id = UUID().uuidString
    let role: String
    let content: String
}
enum APIError: LocalizedError {
    case invalidURL, unauthorized, server(Int), serverMessage(String), invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "عنوان الخادم غير صالح أو لا يستخدم HTTPS"
        case .unauthorized: return "مفتاح الوصول غير صحيح"
        case .server(let code): return "خطأ الخادم: \(code)"
        case .serverMessage(let message): return message
        case .invalidResponse: return "استجابة غير صالحة"
        }
    }
}
/// FastAPI returns `detail` either as a plain string (HTTPException) or as an
/// array of validation objects (422). Decode both, taking the first message.
private struct APIErrorDetail: Decodable {
    private struct ValidationItem: Decodable { let msg: String? }

    let message: String

    private enum CodingKeys: String, CodingKey { case detail }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .detail) {
            message = text
        } else if let items = try? container.decode([ValidationItem].self, forKey: .detail) {
            message = items.compactMap(\.msg).first ?? ""
        } else {
            message = ""
        }
    }
}
struct APIClient {
    let server: String
    let key: String

    var accountScope: String {
        SHA256.hash(data: Data((server + "\u{0}" + key).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static let sessionIDPattern = "^[A-Za-z0-9_-]{1,100}$"

    /// Session IDs are embedded in URL paths; reject anything that is not a
    /// simple token before it reaches the network layer.
    private func validateSessionID(_ session: String) throws {
        guard session.range(of: APIClient.sessionIDPattern, options: .regularExpression) != nil else {
            throw APIError.invalidURL
        }
    }

    private func requestData(_ path: String, method: String = "GET",
                             body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let base = URL(string: server),
              base.scheme == "https",
              base.host != nil,
              let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Must exceed the server chat lease (120s) so a retry never collides
        // with an in-flight lease and surfaces as an unexplained 409.
        request.timeoutInterval = 125
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
        guard (200...299).contains(response.statusCode) else {
            if let error = try? JSONDecoder().decode(APIErrorDetail.self, from: data),
               !error.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw APIError.serverMessage(error.message)
            }
            throw APIError.server(response.statusCode)
        }
        return (data, response)
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET",
                                       body: Data? = nil) async throws -> T {
        let (data, _) = try await requestData(path, method: method, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Manual learning-evidence export; defaults to metadata-only on the server.
    func learningArchive(afterID: Int, limit: Int = 50,
                         includeContent: Bool = false) async throws -> (Data, LearningCursorPage) {
        guard afterID >= 0, (1...200).contains(limit) else { throw APIError.invalidURL }
        let path = "/learning/export?after_id=\(afterID)&limit=\(limit)&include_content=\(includeContent)"
        let (data, response) = try await requestData(path)
        guard data.count <= 5_500_000 else {
            throw APIError.serverMessage("ملف التصدير أكبر من الحد المسموح")
        }
        guard let rawNext = response.value(forHTTPHeaderField: "X-Next-After-ID"),
              let next = Int(rawNext), next >= afterID,
              let rawMore = response.value(forHTTPHeaderField: "X-Has-More"),
              let more = Bool(rawMore), !more || next > afterID else { throw APIError.invalidResponse }
        return (data, LearningCursorPage(next_after_id: next, has_more: more))
    }

    func exportSession(_ session: String) async throws -> Data {
        try validateSessionID(session)
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

    func send(session: String, message: String, provider: String, requestID: String, includeContext: Bool = true) async throws -> String {
        let body = try JSONEncoder().encode(ChatRequest(session_id: session, message: message, provider: provider, request_id: requestID, include_context: includeContext))
        let result: ChatResponse = try await request("/chat", method: "POST", body: body)
        return result.answer
    }

    func deleteSession(_ session: String) async throws {
        try validateSessionID(session)
        let _: DeleteMemoryResponse = try await request("/sessions/\(session)", method: "DELETE")
    }

    func messagePage(session: String, beforeID: Int = 0, limit: Int = 50) async throws -> MessagePage {
        try validateSessionID(session)
        guard beforeID >= 0, (1...100).contains(limit) else {
            throw APIError.invalidURL
        }
        return try await request("/sessions/\(session)/messages/page?before_id=\(beforeID)&limit=\(limit)")
    }

    func insights(session: String) async throws -> ConversationInsights {
        try validateSessionID(session)
        return try await request("/sessions/\(session)/insights")
    }

    func readiness() async throws -> ReadinessResponse {
        try await request("/health/ready")
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
    let title: String
    let pinned: Bool
}
struct ConversationListResponse: Decodable {
    let sessions: [ConversationSummary]
}
extension APIClient {
    func updateSession(_ session: String, title: String, pinned: Bool) async throws {
        try validateSessionID(session)
        let body = try JSONEncoder().encode(SessionUpdateRequest(title: title, pinned: pinned))
        let _: SessionUpdateResponse = try await request("/sessions/\(session)", method: "PATCH", body: body)
    }

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
    let next_before_id: Int?
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

private struct SessionUpdateRequest: Encodable {
    let title: String
    let pinned: Bool
}
private struct SessionUpdateResponse: Decodable {
    let id: String
    let title: String
    let pinned: Bool
}

struct AgentPlan: Decodable, Identifiable {
    var id: String { plan_id }
    let plan_id: String
    let session_id: String
    let action: String
    let payload: [String: StringOrBool]
    let requires_confirmation: Bool
    let expires_at: Int
}

enum StringOrBool: Codable {
    case string(String), bool(Bool)
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) { self = .string(string); return }
        self = .bool(try value.decode(Bool.self))
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let string): try value.encode(string)
        case .bool(let bool): try value.encode(bool)
        }
    }
    var display: String {
        switch self {
        case .string(let string): return string
        case .bool(let bool): return bool ? "نعم" : "لا"
        }
    }
}

struct AgentCommandRequest: Encodable {
    let session_id: String
    let command: String
}
struct AgentDecisionRequest: Encodable {
    let execute: Bool
    let session_id: String
}
struct AgentDecisionResponse: Decodable { let status: String }

extension APIClient {
    func planAgentAction(session: String, command: String) async throws -> AgentPlan {
        let body = try JSONEncoder().encode(AgentCommandRequest(session_id: session, command: command))
        return try await request("/agent/plans", method: "POST", body: body)
    }

    func decideAgentAction(planID: String, session: String, execute: Bool) async throws -> AgentDecisionResponse {
        guard planID.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil,
              session.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else {
            throw APIError.invalidURL
        }
        let body = try JSONEncoder().encode(AgentDecisionRequest(execute: execute, session_id: session))
        return try await request("/agent/plans/\(planID)/decision", method: "POST", body: body)
    }
}


struct BoardTask: Identifiable, Decodable {
    let id: String
    let title: String
    let done: Bool
}
private struct BoardTaskList: Decodable {
    let tasks: [BoardTask]
}
private struct BoardTaskInput: Encodable {
    let title: String
}
private struct BoardTaskStatus: Decodable {
    let id: String
    let done: Bool
}
extension APIClient {
    func boardTasks(session: String) async throws -> [BoardTask] {
        try validateSessionID(session)
        let result: BoardTaskList = try await request("/sessions/\(session)/tasks")
        return result.tasks
    }

    func addBoardTask(session: String, title: String) async throws {
        try validateSessionID(session)
        let body = try JSONEncoder().encode(BoardTaskInput(title: title))
        let _: BoardTask = try await request("/sessions/\(session)/tasks", method: "POST", body: body)
    }

    func updateBoardTask(session: String, task: String, done: Bool) async throws {
        try validateSessionID(session)
        let _: BoardTaskStatus = try await request(
            "/sessions/\(session)/tasks/\(task)?done=\(done)", method: "PATCH"
        )
    }

    func deleteBoardTask(session: String, task: String) async throws {
        try validateSessionID(session)
        let _: DeleteMemoryResponse = try await request(
            "/sessions/\(session)/tasks/\(task)", method: "DELETE"
        )
    }
}
