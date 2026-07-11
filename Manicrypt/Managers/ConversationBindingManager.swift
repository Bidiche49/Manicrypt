//
//  ConversationBindingManager.swift
//  Manicrypt
//
//  Liaison conversation ↔ passphrase du mode transparent (FEAT-002, brique 1).
//  V1 : une seule liaison à la fois, pilote WhatsApp.
//
//  Stockage (service Keychain com.manicrypt.app, jamais synchronisé iCloud) :
//  - Métadonnées {bundleID, titre de conversation} : item Keychain SANS biométrie
//    (kSecAttrAccessibleWhenUnlockedThisDeviceOnly). Elles sont relues à chaque
//    changement de conversation pour décider « liée / non liée » — une biométrie
//    ici serait inutilisable. Elles ne contiennent AUCUN secret de chiffrement,
//    mais restent hors UserDefaults (qui protège la conversation est une
//    métadonnée sensible).
//  - Passphrase de la conversation : item Keychain séparé, biométrie obligatoire
//    en production (même pattern DEBUG/release que SecureKeychainManager).
//
//  Limite structurelle documentée (POC) : WhatsApp n'expose aucun identifiant
//  technique de conversation — le titre AFFICHÉ est la seule clé. Conséquences :
//  - deux contacts homonymes sont indistinguables (le mode transparent
//    s'appliquerait aux deux) ;
//  - renommer le contact/groupe casse silencieusement la liaison (la
//    conversation redevient non protégée) → à re-lier après renommage.
//

import Foundation
import Security

struct ConversationBinding: Codable, Equatable {
    let bundleID: String
    let conversationTitle: String
    let createdAt: Date
}

final class ConversationBindingManager {
    static let shared = ConversationBindingManager()

    /// Notification postée à chaque liaison/déliaison (les briques 2–4 s'y
    /// abonnent pour recalculer leur état).
    static let bindingDidChangeNotification = Notification.Name("ManicryptConversationBindingDidChange")

    enum BindingError: Error {
        case emptyPassphrase
        case encodingFailed
        case keychainError(OSStatus)
        case noBinding

        var userMessage: String {
            switch self {
            case .emptyPassphrase: return "La passphrase ne peut pas être vide."
            case .encodingFailed: return "Impossible d'encoder la liaison."
            case .keychainError(let status): return "Erreur Keychain: \(status)"
            case .noBinding: return "Aucune conversation liée."
            }
        }
    }

    private enum KeychainKeys {
        static let service = "com.manicrypt.app"
        static let bindingMeta = "conversationBindingMeta"
        static let bindingPassphrase = "conversationBindingPassphrase"
    }

    /// Cache mémoire des métadonnées (relues très souvent par la détection
    /// d'activité). Invalide à chaque bind/unbind. JAMAIS la passphrase.
    private var cachedBinding: ConversationBinding??

    private init() {}

    // MARK: - Lecture

    /// Liaison courante, ou `nil`. Métadonnées seulement — ne touche jamais à
    /// l'item biométrique.
    func currentBinding() -> ConversationBinding? {
        if let cached = cachedBinding { return cached }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: KeychainKeys.bindingMeta,
            kSecReturnData as String: true
        ]
        var ref: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        guard status == errSecSuccess,
              let data = ref as? Data,
              let binding = try? JSONDecoder().decode(ConversationBinding.self, from: data) else {
            cachedBinding = .some(nil)
            return nil
        }
        cachedBinding = binding
        return binding
    }

    var hasBinding: Bool {
        return currentBinding() != nil
    }

    /// La conversation {bundleID, titre} est-elle celle qui est liée ?
    /// Comparaison stricte du titre (seule clé disponible, cf. en-tête).
    func isBound(bundleID: String, conversationTitle: String) -> Bool {
        guard let binding = currentBinding() else { return false }
        return binding.bundleID == bundleID && binding.conversationTitle == conversationTitle
    }

    /// Passphrase de la conversation liée. Déclenche Touch ID en production.
    func loadPassphrase() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: KeychainKeys.bindingPassphrase,
            kSecReturnData as String: true,
            kSecUseOperationPrompt as String: "Authentifiez-vous pour activer la conversation protégée"
        ]
        var ref: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        switch status {
        case errSecSuccess:
            guard let data = ref as? Data,
                  let passphrase = String(data: data, encoding: .utf8) else {
                throw BindingError.keychainError(errSecDecode)
            }
            return passphrase
        case errSecItemNotFound:
            throw BindingError.noBinding
        default:
            throw BindingError.keychainError(status)
        }
    }

    // MARK: - Écriture

    /// Enregistre la liaison (remplace l'existante — V1 : une seule).
    func bind(bundleID: String, conversationTitle: String, passphrase: String) throws {
        guard !passphrase.isEmpty else { throw BindingError.emptyPassphrase }

        let binding = ConversationBinding(
            bundleID: bundleID,
            conversationTitle: conversationTitle,
            createdAt: Date()
        )
        guard let metaData = try? JSONEncoder().encode(binding),
              let passphraseData = passphrase.data(using: .utf8) else {
            throw BindingError.encodingFailed
        }

        // Remplacement atomique simple : purger puis réécrire les deux items.
        deleteItem(account: KeychainKeys.bindingMeta)
        deleteItem(account: KeychainKeys.bindingPassphrase)

        // 1) Passphrase d'abord : si elle échoue, aucune liaison ne doit exister
        //    (fail-safe — jamais de métadonnées « liée » sans passphrase lisible).
        let passphraseQuery = try passphraseAddQuery(data: passphraseData)
        let passStatus = SecItemAdd(passphraseQuery as CFDictionary, nil)
        guard passStatus == errSecSuccess else {
            throw BindingError.keychainError(passStatus)
        }

        // 2) Métadonnées ensuite.
        let metaQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: KeychainKeys.bindingMeta,
            kSecValueData as String: metaData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let metaStatus = SecItemAdd(metaQuery as CFDictionary, nil)
        guard metaStatus == errSecSuccess else {
            // Cohérence : ne pas laisser une passphrase orpheline.
            deleteItem(account: KeychainKeys.bindingPassphrase)
            throw BindingError.keychainError(metaStatus)
        }

        cachedBinding = binding
        print("✅ Liaison de conversation enregistrée")
        NotificationCenter.default.post(name: Self.bindingDidChangeNotification, object: nil)
    }

    /// Supprime la liaison courante (métadonnées + passphrase).
    func unbind() {
        deleteItem(account: KeychainKeys.bindingMeta)
        deleteItem(account: KeychainKeys.bindingPassphrase)
        cachedBinding = .some(nil)
        print("✅ Liaison de conversation supprimée")
        NotificationCenter.default.post(name: Self.bindingDidChangeNotification, object: nil)
    }

    // MARK: - Privé

    private func passphraseAddQuery(data: Data) throws -> [String: Any] {
        #if DEBUG
        // Mode debug : sans biométrie (même compromis que SecureKeychainManager,
        // pour permettre les tests sans Touch ID à chaque build).
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: KeychainKeys.bindingPassphrase,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        #else
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryCurrentSet],
            &error
        ) else {
            throw BindingError.keychainError(errSecAuthFailed)
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: KeychainKeys.bindingPassphrase,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: accessControl
        ]
        #endif
    }

    private func deleteItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
