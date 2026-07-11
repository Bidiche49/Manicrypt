//
//  TransparentSessionManager.swift
//  Manicrypt
//
//  Session du mode transparent (FEAT-002) : détient la passphrase de la
//  conversation liée, déverrouillée une seule fois, et offre le chiffrement /
//  déchiffrement au format de fil MC1. aux consommateurs (intercepteur d'envoi
//  brique 3, panneau de lecture brique 4).
//
//  Pourquoi centraliser : le Keychain biométrique ne peut PAS être interrogé
//  dans le callback du CGEventTap (Touch ID y figerait le clavier système) ni
//  à chaque rafraîchissement du panneau. La passphrase est donc déverrouillée
//  une fois à l'activation, gardée en mémoire, et partagée — un seul Touch ID
//  pour l'envoi ET la lecture. Effacée de la mémoire (memset_s) au changement
//  de liaison.
//
//  Les opérations crypto ci-dessous sont pures (aucun accès Keychain) : sûres
//  à appeler depuis le callback du tap.
//

import Foundation

final class TransparentSessionManager {
    static let shared = TransparentSessionManager()

    private var passphrase: String?
    private var isUnlocking = false

    private init() {}

    var isUnlocked: Bool { passphrase != nil }

    // MARK: - Déverrouillage / effacement

    /// Déverrouille la passphrase de la liaison courante (peut déclencher Touch
    /// ID en release). Idempotent, main thread. `onResult` est optionnel :
    /// `true` si une passphrase est disponible ensuite.
    func unlock(onResult: ((Bool) -> Void)? = nil) {
        assert(Thread.isMainThread)
        if passphrase != nil { onResult?(true); return }
        guard !isUnlocking else { onResult?(false); return }
        isUnlocking = true

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            defer { self.isUnlocking = false }
            do {
                self.passphrase = try ConversationBindingManager.shared.loadPassphrase()
                print("🔐 [Transparent] Passphrase de liaison déverrouillée")
                onResult?(true)
            } catch {
                print("❌ [Transparent] Passphrase de liaison indisponible")
                onResult?(false)
            }
        }
    }

    /// Efface la passphrase de la mémoire (changement / suppression de liaison).
    func clear() {
        if var data = passphrase.map({ Data($0.utf8) }) {
            _ = data.withUnsafeMutableBytes { bytes in
                memset_s(bytes.baseAddress, bytes.count, 0, bytes.count)
            }
        }
        passphrase = nil
    }

    // MARK: - Crypto (pur, sans Keychain — sûr dans le callback du tap)

    /// Chiffre `plaintext` et le met au format de fil MC1.. `nil` si échec —
    /// l'appelant DOIT alors bloquer l'envoi (fail-safe).
    func encryptToWire(_ plaintext: String) -> String? {
        guard let passphrase = passphrase else { return nil }
        guard let result = swift_encrypt_data(plaintext, passphrase) else { return nil }
        defer { free_crypto_result(result) }
        let cryptoResult = result.pointee
        guard cryptoResult.success == 1 else { return nil }
        guard let base64 = swift_base64_encode(cryptoResult.data, Int32(cryptoResult.length)) else {
            return nil
        }
        defer { free(base64) }
        return ManicryptMessageFormat.wrap(String(cString: base64))
    }

    /// Déchiffre un jeton de fil (`MC1.…` ou base64 nu). `nil` si la passphrase
    /// courante ne le déchiffre pas (mauvaise clé, format invalide) — jamais de
    /// faux clair (le tag GCM authentifie).
    func decryptWire(_ wire: String) -> String? {
        guard let passphrase = passphrase else { return nil }
        let payload = ManicryptMessageFormat.payloadForDecryption(wire)
        guard let decodeResult = swift_base64_decode(payload) else { return nil }
        defer { free_crypto_result(decodeResult) }
        let decoded = decodeResult.pointee
        guard decoded.success == 1 else { return nil }
        guard let decryptResult = swift_decrypt_data(decoded.data, Int32(decoded.length), passphrase) else {
            return nil
        }
        defer { free_crypto_result(decryptResult) }
        let decrypted = decryptResult.pointee
        guard decrypted.success == 1 else { return nil }
        return String(cString: decrypted.data)
    }
}
