import SwiftUI

/// Impostazioni «Kindle (KOSync)» (T18): server, utente, password, verifica
/// delle credenziali (con la creazione dell'utente se il server non lo
/// conosce), interruttore e stato dell'ultima sincronizzazione. Si apre
/// dalla libreria.
struct KindleSettingsView: View {
    let sync: KindleSync
    @Bindable var settings: KindleSettings
    @Environment(\.dismiss) private var dismiss

    @State private var isWorking = false
    /// Esito dell'ultima verifica o registrazione, da mostrare sotto i pulsanti.
    @State private var outcome: String?
    /// Vero dopo un 401: si offre «Crea l'utente sul server».
    @State private var canRegister = false

    init(sync: KindleSync) {
        self.sync = sync
        self.settings = sync.settings
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Attivo", isOn: $settings.isEnabled)
                } footer: {
                    Text("La posizione dei libri preparati per il Kindle passa tra ReadAlong e KOReader tramite il server KOSync. I segnalibri restano su iCloud.")
                }

                Section("Server") {
                    TextField("Indirizzo", text: $settings.serverURL, prompt: Text(KindleSettings.defaultServerURL))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Utente", text: $settings.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $settings.password)
                        .textContentType(.password)
                }

                Section {
                    Button {
                        Task { await verify() }
                    } label: {
                        HStack {
                            Text("Verifica")
                            if isWorking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isWorking || settings.credentials == nil)

                    if canRegister {
                        Button("Crea l'utente sul server") {
                            Task { await register() }
                        }
                        .disabled(isWorking)
                    }
                } footer: {
                    if let outcome {
                        Text(outcome)
                    }
                }

                Section("Stato") {
                    LabeledContent("Ultima sincronizzazione Kindle") {
                        if let date = settings.lastSyncAt {
                            Text(date, format: .dateTime.day().month().hour().minute())
                        } else {
                            Text("mai")
                        }
                    }
                    if let error = settings.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                    LabeledContent("Questo dispositivo", value: settings.deviceName)
                }
            }
            .navigationTitle("Kindle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }

    private func verify() async {
        isWorking = true
        defer { isWorking = false }
        switch await sync.verify() {
        case .ok:
            canRegister = false
            outcome = "Credenziali valide: sincronizzazione attiva."
            await sync.pullAll()
        case .unauthorized:
            canRegister = true
            outcome = "Il server non riconosce utente e password. Se l'utente non esiste ancora, puoi crearlo."
        case .failed(let message):
            outcome = message
        }
    }

    private func register() async {
        isWorking = true
        defer { isWorking = false }
        switch await sync.register() {
        case .created:
            canRegister = false
            outcome = "Utente creato: sincronizzazione attiva. Usa le stesse credenziali in KOReader."
            await sync.pullAll()
        case .exists:
            outcome = "L'utente esiste già con un'altra password."
        case .failed(let message):
            outcome = message
        }
    }
}
