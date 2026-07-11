//
//  ManicryptMessageFormat.swift
//  Manicrypt
//
//  Format de message versionné « MC1. » (FEAT-002, brique 5).
//
//  Un message Manicrypt v1 = "MC1." + base64 standard (monoligne, paddé) du blob
//  binaire produit par crypto_bridge : salt(32) ‖ iv(12) ‖ tag(16) ‖ ciphertext.
//  Le préfixe versionné permet de repérer de façon fiable les messages Manicrypt
//  dans un fil mixte (labels AX composés de WhatsApp) et d'évoluer plus tard
//  (MC2., …) sans ambiguïté.
//
//  Règles :
//  - Le chiffrement transparent ajoute TOUJOURS le préfixe (wrap).
//  - Le déchiffrement accepte AVEC ou SANS préfixe (rétrocompat avec les messages
//    produits par le mode manuel historique) : voir payloadForDecryption.
//  - La détection (isEncryptedMessage / tokens) est volontairement STRICTE pour
//    éviter les faux positifs dans du texte libre ; la vraie garantie d'intégrité
//    reste le tag GCM au déchiffrement.
//

import Foundation

enum ManicryptMessageFormat {

    /// Préfixe versionné du format v1.
    static let prefix = "MC1."

    /// Taille minimale du payload base64 d'un vrai message : le blob minimal
    /// (salt 32 + iv 12 + tag 16 = 60 octets, message vide) encode en 80 chars.
    /// En dessous, ce n'est pas un chiffré Manicrypt valide.
    static let minPayloadLength = 80

    private static let base64Charset = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
    )

    // MARK: - Construction

    /// Enveloppe un payload base64 (sortie de swift_base64_encode) au format v1.
    static func wrap(_ base64Payload: String) -> String {
        return prefix + base64Payload
    }

    // MARK: - Détection

    /// Le texte (une fois trimé) est-il exactement un message Manicrypt v1 ?
    /// Strict : préfixe + payload base64 plausible (charset, padding, longueur).
    static func isEncryptedMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return false }
        let payload = String(trimmed.dropFirst(prefix.count))
        return isPlausiblePayload(payload)
    }

    /// Extrait tous les jetons « MC1.<base64> » d'un texte composite — typiquement
    /// le label AX d'une bulle WhatsApp ("Your message, MC1.xxx, 14:20, Delivered").
    /// Ne retourne que des jetons plausibles (mêmes critères que la détection).
    static func encryptedTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var searchRange = text.startIndex..<text.endIndex

        while let prefixRange = text.range(of: prefix, range: searchRange) {
            // Étendre tant que le caractère appartient au charset base64.
            var end = prefixRange.upperBound
            while end < text.endIndex,
                  let scalar = text[end].unicodeScalars.first,
                  text[end].unicodeScalars.count == 1,
                  base64Charset.contains(scalar) {
                end = text.index(after: end)
            }
            let payload = String(text[prefixRange.upperBound..<end])
            if isPlausiblePayload(payload) {
                tokens.append(prefix + payload)
            }
            searchRange = end..<text.endIndex
        }
        return tokens
    }

    // MARK: - Déchiffrement (rétrocompat)

    /// Payload base64 à passer à swift_base64_decode. Accepte les deux formes :
    /// - "MC1.<base64>" → "<base64>" (format v1) ;
    /// - "<base64>"     → inchangé (messages historiques du mode manuel).
    /// Le texte est trimé (une sélection embarque souvent espaces/retours ligne,
    /// fatals au décodeur base64 NO_NL).
    static func payloadForDecryption(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return trimmed }
        return String(trimmed.dropFirst(prefix.count))
    }

    // MARK: - Validation interne

    /// Un payload est plausible s'il a la longueur minimale d'un vrai chiffré,
    /// une longueur multiple de 4 (base64 paddé monoligne), un charset base64
    /// pur et un padding bien placé (au plus 2 '=' terminaux).
    private static func isPlausiblePayload(_ payload: String) -> Bool {
        guard payload.count >= minPayloadLength, payload.count % 4 == 0 else {
            return false
        }
        guard payload.unicodeScalars.allSatisfy({ base64Charset.contains($0) }) else {
            return false
        }
        // '=' uniquement en fin, au plus 2.
        if let firstPad = payload.firstIndex(of: "=") {
            let padding = payload[firstPad...]
            guard padding.count <= 2, padding.allSatisfy({ $0 == "=" }) else {
                return false
            }
        }
        return true
    }
}
