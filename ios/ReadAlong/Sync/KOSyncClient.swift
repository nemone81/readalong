import CryptoKit
import Foundation

/// La posizione di un documento su un server KOSync (`GET /syncs/progress/:document`).
struct KOSyncProgress: Sendable, Equatable {
    /// L'identita' del documento (partial MD5 dell'EPUB, `Book.kindleDocument`).
    var document: String
    /// L'XPointer di KOReader (`XPointer`), o cio' che ha scritto il client.
    var progress: String
    /// Avanzamento nel libro, 0…1.
    var percentage: Double
    /// Il nome del dispositivo che l'ha scritta ("Kindle", "iPhone").
    var device: String
    /// L'id stabile di quel dispositivo: il nostro e' `KindleSettings.deviceID`.
    var deviceID: String
    /// Quando il server l'ha ricevuta (lo aggiunge lui, in secondi Unix).
    var timestamp: Date
}

/// Errori del client KOSync, con messaggio in italiano.
enum KOSyncError: Error, Equatable, LocalizedError {
    /// URL del server non valido.
    case invalidURL(String)
    /// 401: utente o password sbagliati (o utente inesistente).
    case unauthorized
    /// 402 su `register`: l'utente esiste gia'.
    case userExists
    /// Risposta HTTP inattesa.
    case server(status: Int)
    /// Rete assente, timeout, certificato rifiutato.
    case network(String)
    /// Risposta 200 ma corpo illeggibile.
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            "Indirizzo del server non valido: \(url)"
        case .unauthorized:
            "Utente o password non validi."
        case .userExists:
            "L'utente esiste già sul server."
        case .server(let status):
            "Il server ha risposto con l'errore \(status)."
        case .network(let reason):
            "Server non raggiungibile: \(reason)"
        case .invalidResponse(let reason):
            "Risposta del server non valida: \(reason)"
        }
    }
}

/// Le quattro chiamate del protocollo KOSync (SPEC «Kindle via KOReader e
/// KOSync»). Un protocollo per poter usare un client finto nei test di
/// `KindleSync`.
protocol KOSyncAPI: Sendable {
    /// `POST /users/create`; `.userExists` se c'e' gia'.
    func register() async throws(KOSyncError)
    /// `GET /users/auth`; `.unauthorized` se le credenziali non valgono.
    func authorize() async throws(KOSyncError)
    /// `PUT /syncs/progress`.
    func putProgress(
        document: String, progress: String, percentage: Double, device: String, deviceID: String
    ) async throws(KOSyncError)
    /// `GET /syncs/progress/:document`; `nil` se il server non ha una
    /// posizione per il documento.
    func getProgress(document: String) async throws(KOSyncError) -> KOSyncProgress?
}

/// Dove e come autenticarsi su un server KOSync.
struct KOSyncCredentials: Sendable, Equatable {
    var baseURL: URL
    var username: String
    /// `x-auth-key`: MD5 esadecimale (minuscolo) della password. La password
    /// in chiaro non esce mai dal dispositivo.
    var userKey: String

    init(baseURL: URL, username: String, userKey: String) {
        self.baseURL = baseURL
        self.username = username
        self.userKey = userKey
    }

    init(baseURL: URL, username: String, password: String) {
        self.init(baseURL: baseURL, username: username, userKey: Self.userKey(password: password))
    }

    /// MD5 esadecimale minuscolo della password, come lo calcola KOReader.
    static func userKey(password: String) -> String {
        Insecure.MD5.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Client HTTP di KOSync su `URLSession` (iniettabile: nei test una sessione
/// con un `URLProtocol` finto).
///
/// - Ogni chiamata porta `x-auth-user`, `x-auth-key`,
///   `Accept: application/vnd.koreader.v1+json` e, con un corpo,
///   `Content-Type: application/json`.
/// - Timeout di `timeout` (10 s): la sincronizzazione non deve tenere
///   appeso nulla, e un errore di rete si riprova alla prossima occasione.
/// - `register` manda come password l'MD5, come fa KOReader: il server lo
///   salva e lo confronta poi con `x-auth-key`.
struct KOSyncClient: KOSyncAPI {
    static let acceptHeader = "application/vnd.koreader.v1+json"
    static let defaultTimeout: TimeInterval = 10

    let credentials: KOSyncCredentials
    let session: URLSession
    let timeout: TimeInterval

    init(credentials: KOSyncCredentials, session: URLSession = .shared, timeout: TimeInterval = KOSyncClient.defaultTimeout) {
        self.credentials = credentials
        self.session = session
        self.timeout = timeout
    }

    func register() async throws(KOSyncError) {
        let body = ["username": credentials.username, "password": credentials.userKey]
        let (status, _) = try await send("POST", path: "users/create", body: body)
        switch status {
        case 200, 201: return
        case 402: throw .userExists
        default: throw Self.error(for: status)
        }
    }

    func authorize() async throws(KOSyncError) {
        let (status, _) = try await send("GET", path: "users/auth")
        guard status == 200 else { throw Self.error(for: status) }
    }

    func putProgress(
        document: String, progress: String, percentage: Double, device: String, deviceID: String
    ) async throws(KOSyncError) {
        let body = ProgressBody(
            document: document, progress: progress, percentage: percentage, device: device, deviceID: deviceID
        )
        let (status, _) = try await send("PUT", path: "syncs/progress", body: body)
        guard status == 200 || status == 201 else { throw Self.error(for: status) }
    }

    func getProgress(document: String) async throws(KOSyncError) -> KOSyncProgress? {
        guard let encoded = document.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) else {
            throw .invalidURL(document)
        }
        let (status, data) = try await send("GET", path: "syncs/progress/\(encoded)")
        if status == 404 { return nil }
        guard status == 200 else { throw Self.error(for: status) }
        return try Self.decodeProgress(data, document: document)
    }

    // MARK: - Interni

    /// Il corpo di `PUT /syncs/progress`, coi nomi dei campi del protocollo.
    private struct ProgressBody: Encodable {
        let document: String
        let progress: String
        let percentage: Double
        let device: String
        let deviceID: String

        enum CodingKeys: String, CodingKey {
            case document, progress, percentage, device
            case deviceID = "device_id"
        }
    }

    /// La risposta di `GET /syncs/progress`: tutto facoltativo, perche' il
    /// server per un documento sconosciuto risponde `{}` (o un record senza
    /// posizione) invece di 404.
    private struct ProgressResponse: Decodable {
        let document: String?
        let progress: String?
        let percentage: Double?
        let device: String?
        let deviceID: String?
        let timestamp: Double?

        enum CodingKeys: String, CodingKey {
            case document, progress, percentage, device, timestamp
            case deviceID = "device_id"
        }
    }

    /// La posizione da una risposta 200; `nil` se il server non ne ha una.
    static func decodeProgress(_ data: Data, document: String) throws(KOSyncError) -> KOSyncProgress? {
        if data.isEmpty { return nil }
        let response: ProgressResponse
        do {
            response = try JSONDecoder().decode(ProgressResponse.self, from: data)
        } catch {
            throw .invalidResponse(error.localizedDescription)
        }
        guard let progress = response.progress, let timestamp = response.timestamp else { return nil }
        return KOSyncProgress(
            document: response.document ?? document,
            progress: progress,
            percentage: response.percentage ?? 0,
            device: response.device ?? "",
            deviceID: response.deviceID ?? "",
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
    }

    private static func error(for status: Int) -> KOSyncError {
        status == 401 ? .unauthorized : .server(status: status)
    }

    private func send(_ method: String, path: String) async throws(KOSyncError) -> (Int, Data) {
        try await send(method, path: path, body: nil as [String: String]?)
    }

    private func send(_ method: String, path: String, body: (some Encodable)?) async throws(KOSyncError) -> (Int, Data) {
        var request = URLRequest(url: credentials.baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(credentials.username, forHTTPHeaderField: "x-auth-user")
        request.setValue(credentials.userKey, forHTTPHeaderField: "x-auth-key")
        request.setValue(Self.acceptHeader, forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                throw .invalidResponse(error.localizedDescription)
            }
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .invalidResponse("risposta non HTTP") }
        return (http.statusCode, data)
    }
}
