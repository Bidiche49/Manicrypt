//
//  ConfigurationManager.swift
//  Manicrypt
//
//  Gestionnaire centralisé de la configuration et des préférences
//

import Foundation
import Security
import LocalAuthentication

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
    }
    
    // MARK: - Keychain Keys
    private enum KeychainKeys {
        static let service = "com.nztd.Manicrypt"
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
