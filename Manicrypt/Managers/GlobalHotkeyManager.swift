//
//  GlobalHotkeyManager.swift
//  Manicrypt
//
//  Gestionnaire unifié des raccourcis clavier globaux CORRIGÉ
//

import Cocoa
import Carbon
import SwiftUI
import UserNotifications
import LocalAuthentication

class GlobalHotkeyManager: ObservableObject {
    static let shared = GlobalHotkeyManager()
    
    private var encryptHotkeyRef: EventHotKeyRef?
    private var decryptHotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var sessionPassphrase: String?
    private var sessionTimer: Timer?

    /// Sérialise les opérations : une seule chaîne capture→crypto→presse-papier à
    /// la fois. Empêche l'entrelacement de deux raccourcis rapprochés qui, pendant
    /// la fenêtre transitoire d'un collage in-place, laisserait le clair sur le
    /// presse-papier. Manipulé uniquement sur le main thread.
    private var isProcessing = false
    
    // État publié pour l'UI
    @Published var isEnabled: Bool = false
    @Published var sessionActive: Bool = false
    @Published var hasConfiguredPassphrase: Bool = false
    @Published var temporaryPassphrase: String = "" // Pour synchronisation avec l'UI
    
    // Configuration des raccourcis
    private struct HotkeyConfig {
        static let encryptKey: UInt32 = UInt32(kVK_ANSI_E)
        static let decryptKey: UInt32 = UInt32(kVK_ANSI_D)
        static let modifiers: UInt32 = UInt32(controlKey + shiftKey)
    }
    
    // Timeout de session (10 minutes)
    private let sessionTimeout: TimeInterval = 600
    
    private init() {
        // Vérifier si une passphrase est configurée
        hasConfiguredPassphrase = SecureKeychainManager.shared.hasGlobalPassphrase()
        
        // Nettoyer les anciennes données UserDefaults
        cleanupLegacyData()
    }
    
    // MARK: - Public Interface
    
    var canEnable: Bool {
        return hasConfiguredPassphrase && PermissionsHelper.shared.hasAccessibilityPermission()
    }
    
    func requestPermissionsAndSetup() {
        guard hasConfiguredPassphrase else {
            print("❌ Aucune passphrase configurée")
            return
        }
        
        if !PermissionsHelper.shared.hasAccessibilityPermission() {
            print("🔐 Demande des permissions d'accessibilité...")
            PermissionsHelper.shared.triggerAccessibilityRequest()
            
            // Vérifier les permissions après un délai
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if self.canEnable {
                    self.setupHotkeys()
                }
            }
        } else {
            setupHotkeys()
        }
    }
    
    func setupHotkeys() {
        print("🔧 Configuration des raccourcis globaux...")
        
        guard canEnable else {
            print("❌ Conditions non remplies pour activer les raccourcis")
            DispatchQueue.main.async {
                self.showSetupRequiredAlert()
            }
            return
        }
        
        // Nettoyer d'abord
        disableHotkeys()
        
        // Créer le gestionnaire d'événements
        guard setupEventHandler() else {
            print("❌ Échec de la création du gestionnaire d'événements")
            return
        }
        
        // Enregistrer les raccourcis
        let encryptSuccess = registerHotkey(
            id: 1,
            keyCode: HotkeyConfig.encryptKey,
            modifiers: HotkeyConfig.modifiers,
            hotkeyRef: &encryptHotkeyRef
        )
        
        let decryptSuccess = registerHotkey(
            id: 2,
            keyCode: HotkeyConfig.decryptKey,
            modifiers: HotkeyConfig.modifiers,
            hotkeyRef: &decryptHotkeyRef
        )
        
        if encryptSuccess && decryptSuccess {
            DispatchQueue.main.async {
                self.isEnabled = true
                print("✅ Raccourcis globaux activés: ⌃⇧E et ⌃⇧D")
                self.showNotification(title: "Manicrypt", message: "Raccourcis globaux activés ✅")
            }
        } else {
            print("❌ Échec de l'enregistrement des raccourcis")
            disableHotkeys()
            DispatchQueue.main.async {
                self.showNotification(title: "Erreur", message: "Impossible d'activer les raccourcis")
            }
        }
    }
    
    func disableHotkeys() {
        if let encryptRef = encryptHotkeyRef {
            UnregisterEventHotKey(encryptRef)
            encryptHotkeyRef = nil
        }
        
        if let decryptRef = decryptHotkeyRef {
            UnregisterEventHotKey(decryptRef)
            decryptHotkeyRef = nil
        }
        
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        
        clearSession()
        
        DispatchQueue.main.async {
            self.isEnabled = false
            print("🔕 Raccourcis globaux désactivés")
        }
    }
    
    // MARK: - Session Management
    
    /// S'assure qu'une session est prête : charge la passphrase depuis le Keychain
    /// (déclenche Touch ID en production, silencieux en DEBUG) si aucune session
    /// active. Le cas « session expirée » retombe ici et ré-authentifie.
    /// Retourne un état d'erreur à afficher dans l'overlay, ou `nil` si prête.
    /// Exécuté sur le main thread ; `loadGlobalPassphrase` y bloque pendant Touch ID
    /// (comportement historique conservé — l'UI d'auth vit dans un autre process).
    private func ensureSession() -> OverlayState? {
        if sessionActive, sessionPassphrase != nil { return nil }

        guard SecureKeychainManager.shared.hasGlobalPassphrase() else {
            return .passphraseNotConfigured
        }

        do {
            let passphrase = try SecureKeychainManager.shared.loadGlobalPassphrase()
            sessionPassphrase = passphrase
            sessionActive = true
            startSessionTimer()
            print("🔐 Session sécurisée démarrée")
            return nil
        } catch {
            let errorMessage = SecureKeychainManager.shared.handleKeychainError(error)
            print("❌ Erreur démarrage session: \(errorMessage)")
            return .failure(errorMessage)
        }
    }

    private func startSessionTimer() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: sessionTimeout, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.clearSession()
                self?.showNotification(title: "Session expirée", message: "Authentifiez-vous à nouveau pour utiliser les raccourcis")
            }
        }
    }
    
    private func clearSession() {
        if let passphrase = sessionPassphrase {
            // Effacement sécurisé de la mémoire - méthode corrigée pour Swift
            var mutableData = Data(passphrase.utf8)
            _ = mutableData.withUnsafeMutableBytes { bytes in
                memset_s(bytes.baseAddress, bytes.count, 0, bytes.count)
            }
        }
        
        sessionPassphrase = nil
        sessionActive = false
        sessionTimer?.invalidate()
        sessionTimer = nil
        
        print("🧹 Session sécurisée effacée")
    }
    
    // MARK: - Event Handling
    
    private func setupEventHandler() -> Bool {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (nextHandler, theEvent, userData) -> OSStatus in
                return GlobalHotkeyManager.hotkeyHandler(
                    nextHandler: nextHandler,
                    theEvent: theEvent,
                    userData: userData
                )
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        
        return status == noErr
    }
    
    private static func hotkeyHandler(
        nextHandler: EventHandlerCallRef?,
        theEvent: EventRef?,
        userData: UnsafeMutableRawPointer?
    ) -> OSStatus {
        guard let userData = userData else {
            print("❌ UserData manquant dans hotkeyHandler")
            return OSStatus(eventNotHandledErr)
        }
        
        let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        
        var hotkeyID = EventHotKeyID()
        let status = GetEventParameter(
            theEvent,
            OSType(kEventParamDirectObject),
            OSType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotkeyID
        )
        
        guard status == noErr else {
            print("❌ Erreur GetEventParameter: \(status)")
            return OSStatus(eventNotHandledErr)
        }
        
        print("🎯 Raccourci détecté, ID: \(hotkeyID.id)")
        
        DispatchQueue.main.async {
            switch hotkeyID.id {
            case 1: // Chiffrer
                manager.processSelectedText(encrypt: true)
            case 2: // Déchiffrer
                manager.processSelectedText(encrypt: false)
            default:
                print("⚠️ ID de raccourci inconnu: \(hotkeyID.id)")
            }
        }
        
        return OSStatus(noErr)
    }
    
    private func registerHotkey(
        id: UInt32,
        keyCode: UInt32,
        modifiers: UInt32,
        hotkeyRef: inout EventHotKeyRef?
    ) -> Bool {
        let hotkeyID = EventHotKeyID(signature: fourCharCode("SECR"), id: id)
        
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        
        if status == noErr {
            print("✅ Raccourci \(id) enregistré")
            return true
        } else {
            print("❌ Erreur enregistrement raccourci \(id): \(status)")
            return false
        }
    }
    
    // MARK: - Text Processing (contextuel v3)

    /// Point d'entrée des deux raccourcis. Prépare la session (Touch ID si besoin),
    /// détecte le contexte de la sélection (champ éditable ou non), capture via ⌘C,
    /// chiffre/déchiffre, puis applique le comportement contextuel :
    ///   - champ éditable      → remplacement in-place (⌘V par-dessus la sélection) ;
    ///   - zone non éditable   → ⌃⇧E : chiffré au presse-papier + HUD ;
    ///                           ⌃⇧D : overlay flottant.
    /// La sélection source n'est modifiée QUE dans le cas in-place (contexte prouvé
    /// éditable) ; jamais de ⌘V à l'aveugle.
    func processSelectedText(encrypt: Bool) {
        print("🔄 Traitement de la sélection — chiffrement: \(encrypt)")

        // Sérialisation : ignorer une nouvelle demande tant qu'une opération est
        // en cours (voir `isProcessing`). Évite l'entrelacement des presse-papiers.
        guard !isProcessing else {
            print("⏳ Opération déjà en cours — raccourci ignoré")
            return
        }
        isProcessing = true

        // Session prête ? (déclenche Touch ID en production ; couvre la ré-auth
        // après expiration). En cas d'échec, l'erreur s'affiche dans l'overlay.
        if let errorState = ensureSession() {
            OverlayPanelController.shared.showError(errorState)
            finishProcessing()
            return
        }

        // Court délai pour laisser la sélection se stabiliser, puis détecter le
        // contexte (tant que le focus est dans l'app source) et capturer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            let context = FocusContextDetector.shared.currentContext()
            self.captureSelection { capture in
                self.handleCapture(capture, encrypt: encrypt, context: context)
            }
        }
    }

    /// Libère le verrou de sérialisation. Appelé à la fin de CHAQUE chemin terminal
    /// (y compris après la restauration différée d'un collage in-place).
    private func finishProcessing() {
        isProcessing = false
    }

    /// Applique le comportement contextuel et les règles strictes de presse-papier.
    /// Chaque chemin terminal libère le verrou : les chemins synchrones via
    /// `finishProcessing()`, les chemins in-place via `pasteInPlace` (après restore).
    private func handleCapture(_ capture: SelectionCapture?, encrypt: Bool, context: FocusContext) {
        guard let passphrase = sessionPassphrase else {
            OverlayPanelController.shared.showError(.failure("Session expirée."))
            finishProcessing()
            return
        }
        guard let capture = capture else {
            // Capture vide : `captureSelection` a déjà restauré le presse-papier.
            OverlayPanelController.shared.showError(.emptySelection)
            finishProcessing()
            return
        }

        switch (encrypt, context) {
        case (true, .editable):
            // ⌃⇧E in-place : chiffre et colle par-dessus la sélection.
            switch performEncrypt(capture.text, passphrase: passphrase) {
            case .success(let cipher):
                pasteInPlace(cipher, restoringTo: capture.snapshot) // libère le verrou après restore
            case .failure(let message):
                restorePasteboard(capture.snapshot)
                OverlayPanelController.shared.showError(.failure(message))
                finishProcessing()
            }

        case (true, .nonEditable):
            // ⌃⇧E non éditable : le presse-papier reçoit le chiffré (c'est la
            // feature), témoin HUD éphémère.
            switch performEncrypt(capture.text, passphrase: passphrase) {
            case .success(let cipher):
                writeToPasteboard(cipher)
                OverlayPanelController.shared.showEncryptedHUD()
            case .failure(let message):
                restorePasteboard(capture.snapshot)
                OverlayPanelController.shared.showError(.failure(message))
            }
            finishProcessing()

        case (false, .editable):
            // ⌃⇧D in-place : déchiffre et colle par-dessus la sélection.
            switch performDecrypt(capture.text, passphrase: passphrase) {
            case .success(let plaintext):
                pasteInPlace(plaintext, restoringTo: capture.snapshot) // libère le verrou après restore
            case .failure:
                // Rien à coller : restaurer, puis proposer l'overlay + autre passphrase.
                restorePasteboard(capture.snapshot)
                OverlayPanelController.shared.showDecryptFailure(retry: makeRetry(cipher: capture.text))
                finishProcessing()
            }

        case (false, .nonEditable):
            // ⌃⇧D overlay : restaurer le presse-papier (le clair n'y transite
            // jamais), puis afficher le clair — ou l'échec + autre passphrase.
            restorePasteboard(capture.snapshot)
            switch performDecrypt(capture.text, passphrase: passphrase) {
            case .success(let plaintext):
                OverlayPanelController.shared.showDecryptSuccess(plaintext, retry: makeRetry(cipher: capture.text))
            case .failure:
                OverlayPanelController.shared.showDecryptFailure(retry: makeRetry(cipher: capture.text))
            }
            finishProcessing()
        }
    }

    /// Fabrique la relance de déchiffrement pour une passphrase alternative saisie
    /// dans l'overlay. Le chiffré est capté par la closure ; la passphrase saisie
    /// n'est ni conservée ni loggée.
    private func makeRetry(cipher: String) -> (String) -> String? {
        return { [weak self] passphrase in
            guard let self = self else { return nil }
            if case .success(let plaintext) = self.performDecrypt(cipher, passphrase: passphrase) {
                return plaintext
            }
            return nil
        }
    }

    // MARK: - Capture de sélection

    /// Résultat d'une capture : le texte sélectionné + un instantané complet du
    /// presse-papier utilisateur (tous types) pour restauration à l'identique.
    private struct SelectionCapture {
        let text: String
        let snapshot: [NSPasteboardItem]
    }

    /// Capture la sélection courante via un ⌘C simulé, après avoir sauvegardé le
    /// presse-papier. En cas de succès, laisse le texte copié au presse-papier :
    /// c'est à l'appelant de décider (⌃⇧D restaure, ⌃⇧E écrase avec le chiffré).
    /// En cas d'échec (rien de textuel copié), restaure lui-même le presse-papier
    /// à l'identique — y compris si un ⌘C a copié du non-texte (image, fichier) —
    /// et retourne `nil`.
    private func captureSelection(completion: @escaping (SelectionCapture?) -> Void) {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard()
        let changeCountBefore = pasteboard.changeCount

        simulateKeyPress(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)

        // Laisser le temps à l'app source de répondre au ⌘C.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            // Le changeCount est plus fiable qu'une comparaison de chaînes :
            // s'il n'a pas bougé, aucune sélection n'a été copiée.
            guard pasteboard.changeCount != changeCountBefore,
                  let text = pasteboard.string(forType: .string),
                  !text.isEmpty else {
                // Échec : ne rien laisser derrière (le ⌘C a pu copier du non-texte).
                self?.restorePasteboard(snapshot)
                completion(nil)
                return
            }
            completion(SelectionCapture(text: text, snapshot: snapshot))
        }
    }

    // MARK: - Presse-papier

    /// Instantané de tous les items/types du presse-papier, pour une restauration
    /// fidèle (texte, RTF, images, URLs…) et pas seulement la chaîne.
    private func snapshotPasteboard() -> [NSPasteboardItem] {
        var snapshot: [NSPasteboardItem] = []
        for item in NSPasteboard.general.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            snapshot.append(copy)
        }
        return snapshot
    }

    private func restorePasteboard(_ items: [NSPasteboardItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private func writeToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Remplace la sélection courante par `text` via un ⌘V simulé, puis restaure
    /// le presse-papier à l'identique. Réservé au contexte prouvé ÉDITABLE — c'est
    /// le seul chemin qui modifie le contenu source (jamais de ⌘V à l'aveugle).
    /// Le texte collé ne fait que transiter par le presse-papier, restauré ensuite.
    private func pasteInPlace(_ text: String, restoringTo snapshot: [NSPasteboardItem]) {
        writeToPasteboard(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            self.simulateKeyPress(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            // Laisser le collage aboutir avant de restaurer le presse-papier, puis
            // libérer le verrou : aucune autre opération ne démarre tant que le
            // texte transitoire n'a pas quitté le presse-papier.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.restorePasteboard(snapshot)
                self.finishProcessing()
            }
        }
    }

    // MARK: - Crypto (sans effet de bord — aucun log du contenu)

    private enum CryptoOutcome {
        case success(String)
        case failure(String)
    }

    private func performEncrypt(_ text: String, passphrase: String) -> CryptoOutcome {
        guard let result = swift_encrypt_data(text, passphrase) else {
            return .failure("Le chiffrement a échoué.")
        }
        defer { free_crypto_result(result) }
        let cryptoResult = result.pointee
        guard cryptoResult.success == 1 else {
            return .failure(String(cString: cryptoResult.error_message))
        }
        guard let base64 = swift_base64_encode(cryptoResult.data, Int32(cryptoResult.length)) else {
            return .failure("Encodage base64 impossible.")
        }
        defer { free(base64) }
        return .success(String(cString: base64))
    }

    private func performDecrypt(_ text: String, passphrase: String) -> CryptoOutcome {
        guard let decodeResult = swift_base64_decode(text) else {
            return .failure("Format base64 invalide.")
        }
        defer { free_crypto_result(decodeResult) }
        let decoded = decodeResult.pointee
        guard decoded.success == 1 else {
            return .failure("Format base64 invalide.")
        }
        guard let decryptResult = swift_decrypt_data(decoded.data, Int32(decoded.length), passphrase) else {
            return .failure("Déchiffrement impossible.")
        }
        defer { free_crypto_result(decryptResult) }
        let decrypted = decryptResult.pointee
        guard decrypted.success == 1 else {
            return .failure(String(cString: decrypted.error_message))
        }
        // Le texte en clair n'est jamais loggé ni persisté.
        return .success(String(cString: decrypted.data))
    }
    
    // MARK: - Utilities
    
    private func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            
            keyDown.flags = flags
            keyUp.flags = flags
            
            keyDown.post(tap: .cghidEventTap)
            usleep(50000) // 50ms
            keyUp.post(tap: .cghidEventTap)
        }
    }
    
    private func showNotification(title: String, message: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = nil
            
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            let id = UUID().uuidString
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            
            UNUserNotificationCenter.current().add(request) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
                }
            }
        }
    }
    
    private func showSetupRequiredAlert() {
        let alert = NSAlert()
        alert.messageText = "Configuration requise"
        alert.informativeText = """
        Pour utiliser les raccourcis globaux, vous devez :
        1. Configurer une passphrase dans les préférences
        2. Autoriser l'accès à l'accessibilité
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Ouvrir Préférences")
        alert.addButton(withTitle: "Plus tard")
        
        if alert.runModal() == .alertFirstButtonReturn {
            // Ouvrir les préférences de l'app
            NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
        }
    }
    
    private func cleanupLegacyData() {
        // Nettoyer les anciennes données UserDefaults non sécurisées
        let legacyKeys = ["manicrypt_temp_passphrase"]
        for key in legacyKeys {
            if UserDefaults.standard.object(forKey: key) != nil {
                print("🧹 Nettoyage des données legacy: \(key)")
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
    
    deinit {
        disableHotkeys()
        clearSession()
    }
}

// Helper pour fourCharCode
private func fourCharCode(_ string: String) -> FourCharCode {
    assert(string.count == 4)
    var result: FourCharCode = 0
    for char in string.utf8 {
        result = (result << 8) + FourCharCode(char)
    }
    return result
}
