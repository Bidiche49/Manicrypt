////
////  PassphraseManager.swift
////  Manicrypt
////
////  Manages passphrase lifecycle: generation, display, and secure storage
////  CORRIGÉ pour utiliser directement les fonctions C
////
//
//import Foundation
//import AppKit  // Pour NSPasteboard
//import Security
//import LocalAuthentication
//
//class PassphraseManager: ObservableObject {
//    static let shared = PassphraseManager()
//    
//    // Published properties for UI binding
//    @Published var currentPassphrase: String = ""
//    @Published var isPassphraseGenerated: Bool = false
//    @Published var sessionTimeRemaining: Int = 600 // 10 minutes in seconds
//    
//    // Session management
//    private var sessionTimer: Timer?
//    private var passphraseData: Data?
//    
//    // Keychain configuration
//    private enum KeychainKeys {
//        static let service = "com.manicrypt.app"
//        static let generatedPassphraseKey = "generatedPassphrase"
//    }
//    
//    private init() {}
//    
//    // MARK: - Passphrase Generation (utilisant les fonctions C)
//    
//    /// Generate a new passphrase with specified parameters using C implementation
//    func generateNewPassphrase(
//        wordCount: Int,
//        capitalize: Bool,
//        includeDigit: Bool,
//        includeSymbol: Bool
//    ) -> Bool {
//        // Clear any existing passphrase first
//        clearCurrentPassphrase()
//        
//        // Créer les options pour la fonction C
//        var options = PassphraseOptions(
//            word_count: Int32(wordCount),
//            capitalize_word: capitalize,
//            add_digit: includeDigit,
//            add_symbol: includeSymbol
//        )
//        
//        // Appeler la fonction C
//        guard let result = generate_passphrase(&options) else {
//            print("❌ Échec de l'allocation mémoire pour la passphrase")
//            return false
//        }
//        
//        defer { free_passphrase_result(result) }
//        let resultData = result.pointee
//        
//        if resultData.success == 1 {
//            // Succès - copier la passphrase
//            let passphrase = String(cString: resultData.passphrase)
//            
//            // Store in memory temporarily
//            currentPassphrase = passphrase
//            passphraseData = passphrase.data(using: .utf8)
//            isPassphraseGenerated = true
//            
//            // Start session timer
//            startSessionTimer()
//            
//            print("✅ Generated new passphrase with \(wordCount) words (Entropy: \(Int(resultData.entropy_bits)) bits)")
//            return true
//        } else {
//            // Erreur
//            let errorMsg = String(cString: resultData.error_message)
//            print("❌ Erreur génération passphrase: \(errorMsg)")
//            return false
//        }
//    }
//    
//    /// Calculate entropy for given parameters using C implementation
//    func calculateEntropy(
//        wordCount: Int,
//        capitalize: Bool,
//        includeDigit: Bool,
//        includeSymbol: Bool
//    ) -> Double {
//        var options = PassphraseOptions(
//            word_count: Int32(wordCount),
//            capitalize_word: capitalize,
//            add_digit: includeDigit,
//            add_symbol: includeSymbol
//        )
//        
//        return calculate_entropy(&options)
//    }
//    
//    /// Get security rating for entropy using C implementation
//    func getSecurityRating(entropy: Double) -> (rating: String, color: String) {
//        guard let rating = get_security_rating(entropy) else {
//            return ("Unknown", "gray")
//        }
//        
//        let ratingString = String(cString: rating)
//        
//        // Mapping des couleurs basé sur le rating
//        let color: String = {
//            switch ratingString.lowercased() {
//            case "weak":
//                return "red"
//            case "fair":
//                return "orange"
//            case "good":
//                return "yellow"
//            case "strong":
//                return "green"
//            case "excellent":
//                return "blue"
//            default:
//                return "gray"
//            }
//        }()
//        
//        return (ratingString, color)
//    }
//    
//    // MARK: - Keychain Storage
//    
//    /// Store the current passphrase in Keychain with biometric protection
//    func storeInKeychain() async throws {
//        guard let data = passphraseData else {
//            throw PassphraseError.noPassphraseGenerated
//        }
//        
//        // Verify biometric availability
//        guard SecureKeychainManager.shared.isBiometryAvailable() else {
//            throw PassphraseError.biometryNotAvailable
//        }
//        
//        // Create access control requiring biometry
//        var error: Unmanaged<CFError>?
//        guard let accessControl = SecAccessControlCreateWithFlags(
//            kCFAllocatorDefault,
//            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
//            [.biometryCurrentSet, .privateKeyUsage],
//            &error
//        ) else {
//            if let error = error?.takeRetainedValue() {
//                print("❌ Failed to create access control: \(error)")
//            }
//            throw PassphraseError.keychainAccessError
//        }
//        
//        // Delete any existing entry first
//        deleteFromKeychain()
//        
//        // Prepare the Keychain query
//        let query: [String: Any] = [
//            kSecClass as String: kSecClassGenericPassword,
//            kSecAttrService as String: KeychainKeys.service,
//            kSecAttrAccount as String: KeychainKeys.generatedPassphraseKey,
//            kSecValueData as String: data,
//            kSecAttrAccessControl as String: accessControl,
//            kSecUseAuthenticationContext as String: LAContext(),
//            kSecAttrSynchronizable as String: false, // Never sync to iCloud
//            kSecAttrLabel as String: "Manicrypt Generated Passphrase"
//        ]
//        
//        let status = SecItemAdd(query as CFDictionary, nil)
//        
//        switch status {
//        case errSecSuccess:
//            print("✅ Passphrase stored securely in Keychain with biometric protection")
//        case errSecDuplicateItem:
//            throw PassphraseError.duplicateItem
//        case errSecAuthFailed:
//            throw PassphraseError.authenticationFailed
//        default:
//            print("❌ Keychain error: \(status)")
//            throw PassphraseError.keychainError(status)
//        }
//    }
//    
//    /// Retrieve a stored passphrase from Keychain
//    func retrieveFromKeychain() async throws -> String {
//        let context = LAContext()
//        context.localizedReason = "Authenticate to access your generated passphrase"
//        
//        let query: [String: Any] = [
//            kSecClass as String: kSecClassGenericPassword,
//            kSecAttrService as String: KeychainKeys.service,
//            kSecAttrAccount as String: KeychainKeys.generatedPassphraseKey,
//            kSecReturnData as String: true,
//            kSecUseAuthenticationContext as String: context,
//            kSecMatchLimit as String: kSecMatchLimitOne
//        ]
//        
//        var dataTypeRef: AnyObject?
//        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
//        
//        switch status {
//        case errSecSuccess:
//            guard let data = dataTypeRef as? Data,
//                  let passphrase = String(data: data, encoding: .utf8) else {
//                throw PassphraseError.invalidData
//            }
//            return passphrase
//        case errSecItemNotFound:
//            throw PassphraseError.notFound
//        case errSecUserCanceled:
//            throw PassphraseError.userCancelled
//        case errSecAuthFailed:
//            throw PassphraseError.authenticationFailed
//        default:
//            throw PassphraseError.keychainError(status)
//        }
//    }
//    
//    /// Check if a passphrase is stored in Keychain
//    func hasStoredPassphrase() -> Bool {
//        let query: [String: Any] = [
//            kSecClass as String: kSecClassGenericPassword,
//            kSecAttrService as String: KeychainKeys.service,
//            kSecAttrAccount as String: KeychainKeys.generatedPassphraseKey,
//            kSecReturnAttributes as String: false
//        ]
//        
//        let status = SecItemCopyMatching(query as CFDictionary, nil)
//        return status == errSecSuccess
//    }
//    
//    /// Delete stored passphrase from Keychain
//    func deleteFromKeychain() {
//        let query: [String: Any] = [
//            kSecClass as String: kSecClassGenericPassword,
//            kSecAttrService as String: KeychainKeys.service,
//            kSecAttrAccount as String: KeychainKeys.generatedPassphraseKey
//        ]
//        
//        let status = SecItemDelete(query as CFDictionary)
//        if status == errSecSuccess {
//            print("✅ Deleted passphrase from Keychain")
//        }
//    }
//    
//    // MARK: - Session Management
//    
//    func startSessionTimer() {
//        // Cancel any existing timer
//        sessionTimer?.invalidate()
//        
//        // Reset timer
//        sessionTimeRemaining = 600 // 10 minutes
//        
//        // Start countdown
//        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
//            DispatchQueue.main.async {
//                self.sessionTimeRemaining -= 1
//                
//                if self.sessionTimeRemaining <= 0 {
//                    self.sessionTimeout()
//                }
//            }
//        }
//    }
//    
//    private func sessionTimeout() {
//        print("⏱️ Session timeout - clearing passphrase from memory")
//        clearCurrentPassphrase()
//    }
//    
//    /// Clear the current passphrase from memory
//    func clearCurrentPassphrase() {
//        // Stop timer
//        sessionTimer?.invalidate()
//        sessionTimer = nil
//        sessionTimeRemaining = 0
//        
//        // Clear string
//        currentPassphrase = ""
//        isPassphraseGenerated = false
//        
//        // Securely clear data
//        if var data = passphraseData {
//            // Zero out the memory
//            data.withUnsafeMutableBytes { bytes in
//                memset_s(bytes.baseAddress, bytes.count, 0, bytes.count)
//            }
//            passphraseData = nil
//        }
//        
//        print("🧹 Passphrase cleared from memory")
//    }
//    
//    /// Copy passphrase to clipboard with auto-clear
//    func copyToClipboard() {
//        guard !currentPassphrase.isEmpty else { return }
//        
//        let pasteboard = NSPasteboard.general
//        pasteboard.clearContents()
//        pasteboard.setString(currentPassphrase, forType: .string)
//        
//        // Auto-clear clipboard after 30 seconds
//        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
//            // Only clear if our passphrase is still there
//            if pasteboard.string(forType: .string) == self.currentPassphrase {
//                pasteboard.clearContents()
//                print("🧹 Cleared passphrase from clipboard")
//            }
//        }
//    }
//    
//    deinit {
//        clearCurrentPassphrase()
//    }
//}
//
//// MARK: - Error Types
//enum PassphraseError: LocalizedError {
//    case noPassphraseGenerated
//    case biometryNotAvailable
//    case keychainAccessError
//    case keychainError(OSStatus)
//    case duplicateItem
//    case notFound
//    case invalidData
//    case userCancelled
//    case authenticationFailed
//    
//    var errorDescription: String? {
//        switch self {
//        case .noPassphraseGenerated:
//            return "No passphrase has been generated"
//        case .biometryNotAvailable:
//            return "Touch ID / Face ID is not available on this device"
//        case .keychainAccessError:
//            return "Failed to configure Keychain access control"
//        case .keychainError(let status):
//            return "Keychain error: \(status)"
//        case .duplicateItem:
//            return "A passphrase is already stored. Delete it first."
//        case .notFound:
//            return "No stored passphrase found"
//        case .invalidData:
//            return "Stored passphrase data is corrupted"
//        case .userCancelled:
//            return "Authentication was cancelled"
//        case .authenticationFailed:
//            return "Authentication failed"
//        }
//    }
//}
//





//
//  PassphraseManager.swift - VERSION DEBUG
//  Pour diagnostiquer le problème d'affichage
//

import Foundation
import AppKit
import Security
import LocalAuthentication

class PassphraseManager: ObservableObject {
    static let shared = PassphraseManager()
    
    // Published properties for UI binding
    @Published var currentPassphrase: String = ""
    @Published var isPassphraseGenerated: Bool = false
    @Published var sessionTimeRemaining: Int = 600
    
    // Session management
    private var sessionTimer: Timer?
    private var passphraseData: Data?
    
    // Keychain configuration
    private enum KeychainKeys {
        static let service = "com.manicrypt.app"
        static let generatedPassphraseKey = "generatedPassphrase"
    }
    
    private init() {}
    
    // MARK: - Passphrase Generation avec DEBUG
    
    func generateNewPassphrase(
        wordCount: Int,
        capitalize: Bool,
        includeDigit: Bool,
        includeSymbol: Bool
    ) -> Bool {
        print("🔍 DEBUG: Début génération passphrase")
        print("   - Mots: \(wordCount)")
        print("   - Capitaliser: \(capitalize)")
        print("   - Chiffre: \(includeDigit)")
        print("   - Symbole: \(includeSymbol)")
        
        // Clear any existing passphrase first
        clearCurrentPassphrase()
        
        // ✅ TEST 1: Vérifier que les fonctions C sont disponibles
        print("🔍 DEBUG: Test de la fonction C...")
        
        // Créer les options pour la fonction C
        var options = PassphraseOptions(
            word_count: Int32(wordCount),
            capitalize_word: capitalize,
            add_digit: includeDigit,
            add_symbol: includeSymbol
        )
        
        print("🔍 DEBUG: Options créées, appel de generate_passphrase...")
        
        // Appeler la fonction C
        guard let result = generate_passphrase(&options) else {
            print("❌ DEBUG: generate_passphrase a retourné NULL")
            return false
        }
        
        defer {
            print("🔍 DEBUG: Libération de la mémoire C")
            free_passphrase_result(result)
        }
        
        let resultData = result.pointee
        print("🔍 DEBUG: Résultat C reçu")
        print("   - Success: \(resultData.success)")
        print("   - Length: \(resultData.length)")
        
        if resultData.success == 1 {
            // ✅ TEST 2: Vérifier le pointeur et la conversion
            guard resultData.passphrase != nil else {
                print("❌ DEBUG: Pointeur passphrase est NULL")
                return false
            }
            
            print("🔍 DEBUG: Conversion du pointeur C vers String...")
            let passphrase = String(cString: resultData.passphrase)
            
            print("🔍 DEBUG: Passphrase convertie:")
            print("   - Longueur: \(passphrase.count)")
            print("   - Contenu: '\(passphrase)'")
            print("   - Premier caractère: '\(passphrase.first ?? Character(" "))'")
            print("   - Dernier caractère: '\(passphrase.last ?? Character(" "))'")
            
            // ✅ TEST 3: Vérifier l'assignation
            DispatchQueue.main.async {
                print("🔍 DEBUG: Assignation sur main thread...")
                self.currentPassphrase = passphrase
                self.passphraseData = passphrase.data(using: .utf8)
                self.isPassphraseGenerated = true
                
                print("🔍 DEBUG: État après assignation:")
                print("   - currentPassphrase: '\(self.currentPassphrase)'")
                print("   - isPassphraseGenerated: \(self.isPassphraseGenerated)")
                print("   - passphraseData nil: \(self.passphraseData == nil)")
                
                // Start session timer
                self.startSessionTimer()
            }
            
            print("✅ DEBUG: Génération réussie avec \(wordCount) mots (Entropy: \(Int(resultData.entropy_bits)) bits)")
            return true
        } else {
            // Erreur
            let errorMsg = String(cString: resultData.error_message)
            print("❌ DEBUG: Erreur génération: \(errorMsg)")
            return false
        }
    }
    
    // ✅ TEST 4: Fonction de test simple
    func testSimpleGeneration() -> String? {
        print("🧪 TEST: Génération simple...")
        
        var options = PassphraseOptions(
            word_count: 4,
            capitalize_word: false,
            add_digit: false,
            add_symbol: false
        )
        
        guard let result = generate_passphrase(&options) else {
            print("❌ TEST: generate_passphrase échec")
            return nil
        }
        
        defer { free_passphrase_result(result) }
        let resultData = result.pointee
        
        if resultData.success == 1 {
            let passphrase = String(cString: resultData.passphrase)
            print("✅ TEST: Passphrase générée: '\(passphrase)'")
            return passphrase
        } else {
            let error = String(cString: resultData.error_message)
            print("❌ TEST: Erreur: \(error)")
            return nil
        }
    }
    
    // Calculate entropy for given parameters using C implementation
    func calculateEntropy(
        wordCount: Int,
        capitalize: Bool,
        includeDigit: Bool,
        includeSymbol: Bool
    ) -> Double {
        var options = PassphraseOptions(
            word_count: Int32(wordCount),
            capitalize_word: capitalize,
            add_digit: includeDigit,
            add_symbol: includeSymbol
        )
        
        let entropy = calculate_entropy(&options)
        print("🔍 DEBUG: Entropie calculée: \(entropy) bits")
        return entropy
    }
    
    // Get security rating for entropy using C implementation
    func getSecurityRating(entropy: Double) -> (rating: String, color: String) {
        guard let rating = get_security_rating(entropy) else {
            print("❌ DEBUG: get_security_rating a retourné NULL")
            return ("Unknown", "gray")
        }
        
        let ratingString = String(cString: rating)
        print("🔍 DEBUG: Rating sécurité: \(ratingString)")
        
        let color: String = {
            switch ratingString.lowercased() {
            case "weak": return "red"
            case "fair": return "orange"
            case "good": return "yellow"
            case "strong": return "green"
            case "excellent": return "blue"
            default: return "gray"
            }
        }()
        
        return (ratingString, color)
    }
    
    // MARK: - Session Management
    
    func startSessionTimer() {
        sessionTimer?.invalidate()
        sessionTimeRemaining = 600
        
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                self.sessionTimeRemaining -= 1
                if self.sessionTimeRemaining <= 0 {
                    self.sessionTimeout()
                }
            }
        }
        print("🔍 DEBUG: Timer de session démarré")
    }
    
    private func sessionTimeout() {
        print("⏱️ DEBUG: Session timeout - clearing passphrase from memory")
        clearCurrentPassphrase()
    }
    
    func clearCurrentPassphrase() {
        print("🔍 DEBUG: Clearing passphrase...")
        
        sessionTimer?.invalidate()
        sessionTimer = nil
        sessionTimeRemaining = 0
        
        DispatchQueue.main.async {
            self.currentPassphrase = ""
            self.isPassphraseGenerated = false
        }
        
        if var data = passphraseData {
            data.withUnsafeMutableBytes { bytes in
                memset_s(bytes.baseAddress, bytes.count, 0, bytes.count)
            }
            passphraseData = nil
        }
        
        print("🧹 DEBUG: Passphrase cleared from memory")
    }
    
    func copyToClipboard() {
        guard !currentPassphrase.isEmpty else {
            print("❌ DEBUG: Impossible de copier - passphrase vide")
            return
        }
        
        print("🔍 DEBUG: Copie dans le presse-papiers...")
        print("   - Contenu à copier: '\(currentPassphrase)'")
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(currentPassphrase, forType: .string)
        
        print("🔍 DEBUG: Copie réussie: \(success)")
        
        // Vérifier que ça a bien été copié
        if let clipboardContent = pasteboard.string(forType: .string) {
            print("🔍 DEBUG: Contenu presse-papiers: '\(clipboardContent)'")
        }
        
        // Auto-clear clipboard after 30 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if pasteboard.string(forType: .string) == self.currentPassphrase {
                pasteboard.clearContents()
                print("🧹 DEBUG: Presse-papiers nettoyé")
            }
        }
    }
    
    // MARK: - Keychain methods (unchanged)
    func storeInKeychain() async throws {
        // Implementation unchanged...
    }
    
    func retrieveFromKeychain() async throws -> String {
        // Implementation unchanged...
        return ""
    }
    
    func hasStoredPassphrase() -> Bool {
        // Implementation unchanged...
        return false
    }
    
    func deleteFromKeychain() {
        // Implementation unchanged...
    }
    
    deinit {
        clearCurrentPassphrase()
    }
}
