import Foundation
import Synchronization
import Testing
@testable import ReadAlong

/// Un server KOSync finto dietro `URLProtocol`: registra le richieste (con il
/// corpo, che `URLSession` passa come stream) e risponde con `respond`.
final class FakeKOSyncProtocol: URLProtocol {
    struct Recorded: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?
    }

    struct Reply: Sendable {
        var status: Int
        var body: Data = Data()
    }

    private struct State {
        var requests: [Recorded] = []
        var respond: @Sendable (Recorded) -> Reply = { _ in Reply(status: 200) }
    }

    private static let state = Mutex(State())

    static func reset(_ respond: @escaping @Sendable (Recorded) -> Reply) {
        state.withLock { $0 = State(requests: [], respond: respond) }
    }

    static var requests: [Recorded] {
        state.withLock { $0.requests }
    }

    /// Una sessione che passa solo da questo protocollo.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeKOSyncProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let recorded = Recorded(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        )
        let reply = Self.state.withLock { state in
            state.requests.append(recorded)
            return state.respond(recorded)
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite("Client KOSync", .serialized)
struct KOSyncClientTests {
    private let credentials = KOSyncCredentials(
        baseURL: URL(string: "https://kosync.example.it")!, username: "fabio", password: "segreta"
    )

    private func client() -> KOSyncClient {
        KOSyncClient(credentials: credentials, session: FakeKOSyncProtocol.session())
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("userkey = MD5 esadecimale minuscolo della password")
    func userKey() {
        #expect(KOSyncCredentials.userKey(password: "segreta") == "da7ade0712cb6417beb45550334bda18")
        #expect(KOSyncCredentials.userKey(password: "") == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(credentials.userKey == KOSyncCredentials.userKey(password: "segreta"))
    }

    @Test("Header su ogni chiamata; authorize 200 va, 401 = unauthorized")
    func authorize() async throws {
        FakeKOSyncProtocol.reset { _ in .init(status: 200, body: Data(#"{"authorized":"OK"}"#.utf8)) }
        try await client().authorize()
        let request = try #require(FakeKOSyncProtocol.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://kosync.example.it/users/auth")
        #expect(request.headers["x-auth-user"] == "fabio")
        #expect(request.headers["x-auth-key"] == credentials.userKey)
        #expect(request.headers["Accept"] == "application/vnd.koreader.v1+json")

        FakeKOSyncProtocol.reset { _ in .init(status: 401) }
        await #expect(throws: KOSyncError.unauthorized) { try await client().authorize() }
    }

    @Test("register: POST con l'MD5 come password; 201 va, 402 = userExists")
    func register() async throws {
        FakeKOSyncProtocol.reset { _ in .init(status: 201, body: Data(#"{"username":"fabio"}"#.utf8)) }
        try await client().register()
        let request = try #require(FakeKOSyncProtocol.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.path() == "/users/create")
        #expect(request.headers["Content-Type"] == "application/json")
        let body = try json(request.body)
        #expect(body["username"] as? String == "fabio")
        #expect(body["password"] as? String == credentials.userKey)

        FakeKOSyncProtocol.reset { _ in .init(status: 402) }
        await #expect(throws: KOSyncError.userExists) { try await client().register() }
    }

    @Test("putProgress: PUT con i cinque campi del protocollo")
    func putProgress() async throws {
        FakeKOSyncProtocol.reset { _ in .init(status: 200, body: Data(#"{"document":"abc","timestamp":1700000000}"#.utf8)) }
        try await client().putProgress(
            document: "abc", progress: "/body/DocFragment[2]/body/p[1]/text().17",
            percentage: 0.4125, device: "iPhone", deviceID: "ID-1"
        )
        let request = try #require(FakeKOSyncProtocol.requests.first)
        #expect(request.method == "PUT")
        #expect(request.url.path() == "/syncs/progress")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["x-auth-key"] == credentials.userKey)
        let body = try json(request.body)
        #expect(Set(body.keys) == ["document", "progress", "percentage", "device", "device_id"])
        #expect(body["document"] as? String == "abc")
        #expect(body["progress"] as? String == "/body/DocFragment[2]/body/p[1]/text().17")
        #expect(body["percentage"] as? Double == 0.4125)
        #expect(body["device"] as? String == "iPhone")
        #expect(body["device_id"] as? String == "ID-1")

        FakeKOSyncProtocol.reset { _ in .init(status: 401) }
        await #expect(throws: KOSyncError.unauthorized) {
            try await client().putProgress(document: "abc", progress: "x", percentage: 0, device: "d", deviceID: "i")
        }
        FakeKOSyncProtocol.reset { _ in .init(status: 500) }
        await #expect(throws: KOSyncError.server(status: 500)) {
            try await client().putProgress(document: "abc", progress: "x", percentage: 0, device: "d", deviceID: "i")
        }
    }

    @Test("getProgress: record completo, timestamp in secondi Unix")
    func getProgress() async throws {
        FakeKOSyncProtocol.reset { _ in
            .init(status: 200, body: Data(#"""
            {"document":"abc","progress":"/body/DocFragment[3]/body/p[5]/text().40","percentage":0.52,
             "device":"Kindle","device_id":"KINDLE-1","timestamp":1700000123}
            """#.utf8))
        }
        let progress = try #require(try await client().getProgress(document: "abc"))
        #expect(progress == KOSyncProgress(
            document: "abc", progress: "/body/DocFragment[3]/body/p[5]/text().40", percentage: 0.52,
            device: "Kindle", deviceID: "KINDLE-1", timestamp: Date(timeIntervalSince1970: 1_700_000_123)
        ))
        let request = try #require(FakeKOSyncProtocol.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.path() == "/syncs/progress/abc")
        #expect(request.headers["x-auth-user"] == "fabio")
        #expect(request.headers["Accept"] == "application/vnd.koreader.v1+json")
    }

    @Test("getProgress: 404, {} o record senza posizione = nil; 401 = unauthorized; JSON rotto = invalidResponse")
    func getProgressEdgeCases() async throws {
        FakeKOSyncProtocol.reset { _ in .init(status: 404) }
        #expect(try await client().getProgress(document: "abc") == nil)
        FakeKOSyncProtocol.reset { _ in .init(status: 200, body: Data("{}".utf8)) }
        #expect(try await client().getProgress(document: "abc") == nil)
        FakeKOSyncProtocol.reset { _ in .init(status: 200, body: Data(#"{"document":"abc"}"#.utf8)) }
        #expect(try await client().getProgress(document: "abc") == nil)
        FakeKOSyncProtocol.reset { _ in .init(status: 401) }
        await #expect(throws: KOSyncError.unauthorized) { try await client().getProgress(document: "abc") }
        FakeKOSyncProtocol.reset { _ in .init(status: 200, body: Data("non json".utf8)) }
        await #expect {
            try await client().getProgress(document: "abc")
        } throws: { error in
            if case KOSyncError.invalidResponse = error { return true }
            return false
        }
    }

    @Test("Timeout di 10 s sulle richieste")
    func timeout() {
        #expect(KOSyncClient.defaultTimeout == 10)
        #expect(client().timeout == 10)
    }
}
