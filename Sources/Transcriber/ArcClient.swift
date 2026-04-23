import Foundation

struct ArcProject: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let phase: String?
    let status: String?
}

struct ArcProjectListResponse: Decodable {
    let items: [ArcProject]
    let total: Int
}

struct ArcCommunicationCreated: Decodable {
    let id: String
    let project_id: String?
}

actor ArcClient {
    enum Failure: Error, LocalizedError {
        case notAuthenticated
        case unauthorized           // 401 — token stale, sign out + re-auth
        case http(Int, String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:  return "Not signed in to Arc."
            case .unauthorized:      return "Arc token expired. Please sign in again."
            case .http(let c, let b): return "Arc returned \(c): \(b.prefix(200))"
            case .decode(let m):     return "Could not decode Arc response: \(m)"
            }
        }
    }

    private let baseURL: URL
    private let token: String

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    // MARK: - Projects

    func listProjects() async throws -> [ArcProject] {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("/api/v1/projects"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            URLQueryItem(name: "page_size", value: "100"),
            URLQueryItem(name: "include_archived", value: "false"),
        ]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        NSLog("[Arc] GET %@", comps.url!.absoluteString)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse {
            NSLog("[Arc] ← %d (%d bytes)", http.statusCode, data.count)
        }
        try Self.throwForStatus(response, data: data)
        do {
            return try JSONDecoder().decode(ArcProjectListResponse.self, from: data).items
        } catch {
            throw Failure.decode("\(error)")
        }
    }

    // MARK: - Communications

    struct NewCommunication: Encodable {
        let project_id: String?
        let type: String
        let direction: String?
        let contact_name: String?
        let subject: String?
        let body: String
        let body_format: String
        let occurred_at: String         // ISO-8601
        let duration_minutes: Int?
    }

    /// `projectID == nil` posts the communication to the user's Arc
    /// inbox (owner = caller, no project/site link) so they can link it
    /// to a project/site from within Arc.
    func createMeetingTranscript(
        projectID: String?,
        subject: String?,
        markdownBody: String,
        occurredAt: Date,
        durationMinutes: Int?
    ) async throws -> ArcCommunicationCreated {
        let url = baseURL.appendingPathComponent("/api/v1/communications")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let payload = NewCommunication(
            project_id: projectID,
            type: "meeting",
            // Self-captured transcripts aren't inbound or outbound — mark
            // them `internal` so Arc's UI stops showing "unknown · Logged"
            // and instead labels the message as an internal note.
            direction: "internal",
            // Surfaces as the author label in Arc's timeline (contact_name
            // is what the inbox UI falls back to when there's no external
            // party). Arc has no first-class "source: transcriber" yet,
            // so this is the least invasive way to get a human label.
            contact_name: "Arc Transcriber",
            subject: subject,
            body: markdownBody,
            body_format: "markdown",
            occurred_at: iso.string(from: occurredAt),
            duration_minutes: durationMinutes
        )
        req.httpBody = try JSONEncoder().encode(payload)

        NSLog("[Arc] POST %@ (project=%@)", url.absoluteString, projectID ?? "inbox")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse {
            NSLog("[Arc] ← %d (%d bytes)", http.statusCode, data.count)
        }
        try Self.throwForStatus(response, data: data)
        do {
            return try JSONDecoder().decode(ArcCommunicationCreated.self, from: data)
        } catch {
            throw Failure.decode("\(error)")
        }
    }

    // MARK: - Helpers

    private static func throwForStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw Failure.http(0, "No HTTP response")
        }
        if http.statusCode == 401 { throw Failure.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Failure.http(http.statusCode, body)
        }
    }
}
