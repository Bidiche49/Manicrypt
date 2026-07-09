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
    
    private func startSecureSession() {
        do {
            let passphrase = try SecureKeychainManager.shared.loadGlobalPassphrase()
            sessionPassphrase = passphrase
            sessionActive = true
            
            // Démarrer le timer de session
            sessionTimer?.invalidate()
            sessionTimer = Timer.scheduledTimer(withTimeInterval: sessionTimeout, repeats: false) { _ in
                DispatchQueue.main.async {
                    self.clearSession()
                    self.showNotification(title: "Session expirée", message: "Authentifiez-vous à nouveau pour utiliser les raccourcis")
                }
            }
            
            print("🔐 Session sécurisée démarrée")
        } catch {
            let errorMessage = SecureKeychainManager.shared.handleKeychainError(error)
            print("❌ Erreur démarrage session: \(errorMessage)")
            
            DispatchQueue.main.async {
                self.showNotification(title: "Erreur", message: errorMessage)
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
    
    // MARK: - Text Processing
    
    func processSelectedText(encrypt: Bool) {
        print("🔄 Traitement du texte sélectionné, chiffrement: \(encrypt)")
        
        // Vérifier ou démarrer la session
        if !sessionActive {
            startSecureSession()
            
            // Si la session n'a pas pu démarrer, arrêter
            guard sessionActive else {
                return
            }
        }
        
        // Attendre un court délai pour s'assurer que la sélection est complète
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.performTextProcessing(encrypt: encrypt)
        }
    }
    
    private func performTextProcessing(encrypt: Bool) {
        guard let passphrase = sessionPassphrase else {
            showNotification(title: "Erreur", message: "Session expirée")
            return
        }
        
        // Sauvegarder le presse-papiers actuel
        let pasteboard = NSPasteboard.general
        let originalContents = pasteboard.string(forType: .string)
        
        // Simuler Cmd+C pour copier la sélection
        simulateKeyPress(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        
        // Attendre que le presse-papiers soit mis à jour
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let selectedText = pasteboard.string(forType: .string),
                  !selectedText.isEmpty,
                  selectedText != originalContents else {
                print("❌ Aucun texte sélectionné ou presse-papiers inchangé")
                self.showNotification(title: "Manicrypt", message: "Sélectionnez du texte avant d'utiliser le raccourci")
                
                // Restaurer le presse-papiers original
                if let original = originalContents {
                    pasteboard.clearContents()
                    pasteboard.setString(original, forType: .string)
                }
                return
            }
            
            print("✅ Texte sélectionné capturé: \(selectedText.prefix(50))...")
            
            // Traiter le texte
            if let processedText = self.performCrypto(text: selectedText, passphrase: passphrase, encrypt: encrypt) {
                print("✅ Texte traité avec succès")
                
                // Mettre le résultat dans le presse-papiers
                pasteboard.clearContents()
                pasteboard.setString(processedText, forType: .string)
                
                // Attendre un court délai puis coller
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    // Simuler Cmd+V pour coller
                    self.simulateKeyPress(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
                    
                    // Notification de succès
                    self.showNotification(
                        title: "Manicrypt",
                        message: encrypt ? "Texte chiffré ✅" : "Texte déchiffré ✅"
                    )
                    
                    // Restaurer le presse-papiers après un délai
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if let original = originalContents {
                            pasteboard.clearContents()
                            pasteboard.setString(original, forType: .string)
                            print("📋 Presse-papiers original restauré")
                        }
                    }
                }
            } else {
                // Restaurer le presse-papiers en cas d'erreur
                if let original = originalContents {
                    pasteboard.clearContents()
                    pasteboard.setString(original, forType: .string)
                }
            }
        }
    }
    
    private func performCrypto(text: String, passphrase: String, encrypt: Bool) -> String? {
        if encrypt {
            print("🔐 Chiffrement en cours...")
            if let result = swift_encrypt_data(text, passphrase) {
                defer { free_crypto_result(result) }
                let cryptoResult = result.pointee
                if cryptoResult.success == 1 {
                    if let base64 = swift_base64_encode(cryptoResult.data, Int32(cryptoResult.length)) {
                        defer { free(base64) }
                        print("✅ Chiffrement réussi")
                        return String(cString: base64)
                    }
                } else {
                    let errorMsg = String(cString: cryptoResult.error_message)
                    print("❌ Erreur chiffrement: \(errorMsg)")
                    showNotification(title: "Erreur", message: errorMsg)
                }
            }
        } else {
            print("🔓 Déchiffrement en cours...")
            if let decodeResult = swift_base64_decode(text) {
                defer { free_crypto_result(decodeResult) }
                let decodedData = decodeResult.pointee
                if decodedData.success == 1 {
                    if let decryptResult = swift_decrypt_data(
                        decodedData.data,
                        Int32(decodedData.length),
                        passphrase
                    ) {
                        defer { free_crypto_result(decryptResult) }
                        let decryptData = decryptResult.pointee
                        if decryptData.success == 1 {
                            print("✅ Déchiffrement réussi")
                            return String(cString: decryptData.data)
                        } else {
                            let errorMsg = String(cString: decryptData.error_message)
                            print("❌ Erreur déchiffrement: \(errorMsg)")
                            showNotification(title: "Erreur", message: errorMsg)
                        }
                    }
                } else {
                    print("❌ Erreur décodage Base64")
                    showNotification(title: "Erreur", message: "Format Base64 invalide")
                }
            }
        }
        return nil
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
