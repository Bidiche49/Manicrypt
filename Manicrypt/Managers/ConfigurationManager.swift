//
//  ConfigurationManager.swift
//  Manicrypt
//
//  Gestionnaire centralisé de la configuration et des préférences
//

import Foundation
import Security
import LocalAuthentication

/// Fréquence de ré-authentification biométrique pour débloquer les raccourcis globaux.
/// Gouverne combien de temps la passphrase déchiffrée reste en cache mémoire avant
/// qu'un nouveau Touch ID / Face ID soit exigé.
enum BiometricSessionTimeout: String, CaseIterable, Identifiable {
    case eachTime          // ré-auth à chaque utilisation
    case fiveMinutes
    case thirtyMinutes
    case oneHour           // défaut
    case threeHours
    case twentyFourHours
    case eachLaunch        // déverrouillé jusqu'à la fermeture de l'app (le moins sûr)

    var id: String { rawValue }

    /// Durée du cache en secondes. `0` = ré-auth à chaque fois (jamais mis en cache
    /// entre deux opérations). `.infinity` = jamais expiré tant que l'app vit.
    var duration: TimeInterval {
        switch self {
        case .eachTime:        return 0
        case .fiveMinutes:     return 5 * 60
        case .thirtyMinutes:   return 30 * 60
        case .oneHour:         return 60 * 60
        case .threeHours:      return 3 * 60 * 60
        case .twentyFourHours: return 24 * 60 * 60
        case .eachLaunch:      return .infinity
        }
    }

    var label: String {
        switch self {
        case .eachTime:        return "À chaque utilisation"
        case .fiveMinutes:     return "Toutes les 5 minutes"
        case .thirtyMinutes:   return "Toutes les 30 minutes"
        case .oneHour:         return "Toutes les heures"
        case .threeHours:      return "Toutes les 3 heures"
        case .twentyFourHours: return "Toutes les 24 heures"
        case .eachLaunch:      return "À chaque ouverture de l'app"
        }
    }
}

class ConfigurationManager {
    static let shared = ConfigurationManager()
    
    // MARK: - Keys
    private enum Keys {
        static let hasPassphrase = "manicrypt_has_passphrase"
        static let tempPassphrase = "manicrypt_temp_passphrase" // Temporaire, à remplacer par Keychain
        static let useGlobalHotkeys = "useGlobalHotkeys"
        static let lastVersion = "manicrypt_last_version"
        static let hasRequestedAccessibility = "hasRequestedAccessibility"
        static let hasShownWelcome = "hasShownWelcome"
        static let biometricTimeout = "manicrypt_biometric_timeout"
    }
    
    // MARK: - Keychain Keys
    private enum KeychainKeys {
        static let service = "com.manicrypt.app"
        static let globalPassphrase = "globalPassphrase"
    }
    
    private init() {}
    
    // MARK: - Version Management
    
    var currentVersion: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    var lastVersion: String? {
        get { UserDefaults.standard.string(forKey: Keys.lastVersion) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastVersion) }
    }
    
    var isFirstLaunch: Bool {
        return lastVersion == nil
    }
    
    var isNewVersion: Bool {
        return lastVersion != currentVersion
    }
    
    // MARK: - Hotkeys Configuration
    
    var useGlobalHotkeys: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.useGlobalHotkeys) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.useGlobalHotkeys) }
    }
    
    var hasGlobalPassphrase: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.hasPassphrase) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.hasPassphrase) }
    }

    /// Politique de verrouillage biométrique. Défaut : toutes les heures.
    var biometricSessionTimeout: BiometricSessionTimeout {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Keys.biometricTimeout),
                  let value = BiometricSessionTimeout(rawValue: raw) else {
                return .oneHour
            }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.biometricTimeout) }
    }
    
    // MARK: - Welcome & Permissions
    
    var hasShownWelcome: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.hasShownWelcome) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.hasShownWelcome) }
    }
    
    var hasRequestedAccessibility: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.hasRequestedAccessibility) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.hasRequestedAccessibility) }
    }
    
    // MARK: - Passphrase Management (Temporaire - À migrer vers Keychain)
    
    func saveGlobalPassphrase(_ passphrase: String) {
        // Temporaire : stockage dans UserDefaults
        // TODO: Migrer vers Keychain pour la sécurité
        if let data = passphrase.data(using: .utf8) {
            UserDefaults.standard.set(data, forKey: Keys.tempPassphrase)
            hasGlobalPassphrase = true
        }
    }
    
    func loadGlobalPassphrase() -> String? {
        // Temporaire : lecture depuis UserDefaults
        // TODO: Migrer vers Keychaindisc
        guard let data = UserDefaults.standard.data(forKey: Keys.tempPassphrase),
              let passphrase = String(data: data, encoding: .utf8) else {
            return nil
        }
        return passphrase
    }
    
    func clearGlobalPassphrase() {
        UserDefaults.standard.removeObject(forKey: Keys.tempPassphrase)
        hasGlobalPassphrase = false
    }
    
    // MARK: - Reset
    
    func resetAllPreferences() {
        // Supprimer toutes les préférences
        let keys = [
            Keys.hasPassphrase,
            Keys.tempPassphrase,
            Keys.useGlobalHotkeys,
            Keys.lastVersion,
            Keys.hasRequestedAccessibility,
            Keys.hasShownWelcome
        ]
        
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        
        UserDefaults.standard.synchronize()
    }
    
    func resetForNewInstallation() {
        // Reset sélectif pour nouvelle installation
        clearGlobalPassphrase()
        useGlobalHotkeys = false
        hasRequestedAccessibility = false
        hasShownWelcome = false
    }
}

// MARK: - Future Keychain Implementation
extension ConfigurationManager {
    /*
    // À implémenter pour une sécurité renforcée
    
    private func saveToKeychain(key: String, value: String) -> Bool {
        let data = value.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        
        SecItemDelete(query as CFDictionary) // Supprimer l'ancien si existe
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecSuccess {
            if let data = dataTypeRef as? Data,
               let value = String(data: data, encoding: .utf8) {
                return value
            }
        }
        
        return nil
    }
    
    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
    }
    */
}
