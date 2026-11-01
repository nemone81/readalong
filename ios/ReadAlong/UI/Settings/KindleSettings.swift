import Foundation
import Observation
import Security

/// Dove si tengono i segreti (la password KOSync): il Keychain in app, un
/// dizionario nei test.
protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    /// Scrive il segreto; `nil` o stringa vuota lo cancella.
    func setSecret(_ value: String?, for account: String)
}

/// `SecretStore` sul Keychain di iOS (`Security`, voci generic password).
///
/// Accessibile `AfterFirstUnlockThisDeviceOnly`: la `PUT` verso KOSync parte
/// anche a schermo bloccato durante l'ascolto; la voce non va nei backup
/// ne' su altri dispositivi (su ciascuno la password si inserisce a mano).
struct KeychainSecretStore: SecretStore {
    let service: String

    init(service: String = "it.fabiocrestoni.readalong.kosync") {
        self.service = service
    }

    func secret(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ value: String?, for account: String) {
        let query = baseQuery(account)
        guard let value, !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { $1 }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Impostazioni del collegamento al Kindle via KOSync (T18): server, utente,
/// password, interruttore, identita' di questo dispositivo e stato
/// dell'ultima sincronizzazione.
///
/// URL, utente, interruttore, `deviceID` e stato in `UserDefaults`; la
/// password nel Keychain (`SecretStore`): al server va solo il suo MD5.
@MainActor
@Observable
final class KindleSettings {
    enum Keys {
        static let serverURL = "kindle.serverURL"
        static let username = "kindle.username"
        static let enabled = "kindle.enabled"
        static let deviceID = "kindle.deviceID"
        static let lastSyncAt = "kindle.lastSyncAt"
        static let lastError = "kindle.lastError"
        /// L'account della password nel Keychain.
        static let passwordAccount = "kosync.password"
    }

    nonisolated static let defaultServerURL = "https://kosync.fabiocrestoni.it"
    /// Il dispositivo che ha scritto una posizione arrivata da KOSync, nella
    /// proposta «Riprendi da dove eri arrivato su Kindle?».
    nonisolated static let remoteDeviceName = "Kindle"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStore

    var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Keys.serverURL) }
    }

    var username: String {
        didSet { defaults.set(username, forKey: Keys.username) }
    }

    /// La password in chiaro, solo nel Keychain.
    var password: String {
        didSet { secrets.setSecret(password, for: Keys.passwordAccount) }
    }

    /// Sincronizzazione col Kindle attiva. Predefinito: spenta; la accende
    /// una verifica riuscita.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }

    /// Identita' stabile di questo dispositivo per KOSync (`device_id`):
    /// generata una volta e poi sempre quella. Una posizione col nostro id
    /// e' nostra e non si propone.
    let deviceID: String
    /// Il nome mostrato da KOReader (`device`).
    let deviceName: String

    /// L'ultima sincronizzazione riuscita (GET o PUT).
    private(set) var lastSyncAt: Date?
    /// L'ultimo errore, finche' una sincronizzazione non riesce.
    private(set) var lastError: String?

    init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainSecretStore(), deviceName: String) {
        self.defaults = defaults
        self.secrets = secrets
        self.deviceName = deviceName
        serverURL = defaults.string(forKey: Keys.serverURL) ?? Self.defaultServerURL
        username = defaults.string(forKey: Keys.username) ?? ""
        password = secrets.secret(for: Keys.passwordAccount) ?? ""
        isEnabled = defaults.bool(forKey: Keys.enabled)
        if let stored = defaults.string(forKey: Keys.deviceID), !stored.isEmpty {
            deviceID = stored
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: Keys.deviceID)
            deviceID = generated
        }
        lastSyncAt = defaults.object(forKey: Keys.lastSyncAt) as? Date
        lastError = defaults.string(forKey: Keys.lastError)
    }

    /// Le credenziali se URL, utente e password ci sono e l'URL e' http(s).
    var credentials: KOSyncCredentials? {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !password.isEmpty, let url = Self.serverURL(from: serverURL) else { return nil }
        return KOSyncCredentials(baseURL: url, username: user, password: password)
    }

    /// L'URL del server da quanto scritto: http o https, con un host.
    nonisolated static func serverURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil
        else { return nil }
        return url
    }

    /// Una sincronizzazione riuscita: data e niente errore.
    func recordSuccess(at date: Date) {
        lastSyncAt = date
        lastError = nil
        defaults.set(date, forKey: Keys.lastSyncAt)
        defaults.removeObject(forKey: Keys.lastError)
    }

    /// Una sincronizzazione fallita: l'errore resta fino al prossimo successo.
    func recordFailure(_ message: String) {
        lastError = message
        defaults.set(message, forKey: Keys.lastError)
    }
}
