//
//  MessageFormatTester.swift
//  Manicrypt
//
//  Tests unitaires du format de message versionné MC1. (FEAT-002, brique 5)
//

import Foundation

class MessageFormatTester: TestRunner {
    let testName = "MessageFormat"

    /// Payload base64 valide de taille réaliste (96 chars = 72 octets > blob min).
    private let validPayload = String(repeating: "QUJDRA", count: 16)

    func runTests() -> [TestResult] {
        print("🧪 === TESTS FORMAT MC1. ===")

        var results: [TestResult] = []
        results.append(testWrapRoundTrip())
        results.append(testDetectionValid())
        results.append(testDetectionRejectsInvalid())
        results.append(testRetrocompatDecryption())
        results.append(testTokenExtractionFromBubbleLabels())
        results.append(testRealCryptoRoundTrip())
        return results
    }

    func cleanup() {}

    // MARK: - Tests

    private func testWrapRoundTrip() -> TestResult {
        let wrapped = ManicryptMessageFormat.wrap(validPayload)
        guard wrapped == "MC1." + validPayload else {
            return TestResult(.failed, "wrap n'ajoute pas le préfixe attendu")
        }
        guard ManicryptMessageFormat.payloadForDecryption(wrapped) == validPayload else {
            return TestResult(.failed, "payloadForDecryption ne retire pas le préfixe")
        }
        return TestResult(.passed, "wrap/unwrap round-trip OK")
    }

    private func testDetectionValid() -> TestResult {
        let wrapped = ManicryptMessageFormat.wrap(validPayload)
        guard ManicryptMessageFormat.isEncryptedMessage(wrapped) else {
            return TestResult(.failed, "Message v1 valide non détecté")
        }
        // Tolérance au whitespace autour (sélections, labels)
        guard ManicryptMessageFormat.isEncryptedMessage("  \(wrapped)\n") else {
            return TestResult(.failed, "Message v1 entouré de whitespace non détecté")
        }
        return TestResult(.passed, "Détection des messages v1 OK")
    }

    private func testDetectionRejectsInvalid() -> TestResult {
        let rejects: [(String, String)] = [
            ("Bonjour, on se voit demain ?", "texte libre"),
            ("MC1.", "préfixe seul"),
            ("MC1.abcd", "payload trop court"),
            (validPayload, "base64 sans préfixe"),
            ("MC1." + String(repeating: "é", count: 100), "charset invalide"),
            ("MC1." + String(validPayload.dropLast()), "longueur non multiple de 4"),
            ("MC1." + validPayload.replacingOccurrences(of: "QUJD", with: "QU=D"), "padding mal placé")
        ]
        for (input, label) in rejects where ManicryptMessageFormat.isEncryptedMessage(input) {
            return TestResult(.failed, "Faux positif détection", details: label)
        }
        return TestResult(.passed, "Rejet des non-messages OK (\(rejects.count) cas)")
    }

    private func testRetrocompatDecryption() -> TestResult {
        // Sans préfixe (mode manuel historique) : identité après trim
        let legacy = ManicryptMessageFormat.payloadForDecryption(" \(validPayload)\n")
        guard legacy == validPayload else {
            return TestResult(.failed, "Rétrocompat sans préfixe cassée")
        }
        // Avec préfixe : payload nu
        let v1 = ManicryptMessageFormat.payloadForDecryption("MC1." + validPayload)
        guard v1 == validPayload else {
            return TestResult(.failed, "Extraction payload v1 cassée")
        }
        return TestResult(.passed, "Rétrocompat déchiffrement OK")
    }

    private func testTokenExtractionFromBubbleLabels() -> TestResult {
        let token = ManicryptMessageFormat.wrap(validPayload)

        // Label sortant réel : corps + heure + statut
        let outgoing = "Your message, \(token), 14:20, Sent to Julien Steinitz, Delivered"
        guard ManicryptMessageFormat.encryptedTokens(in: outgoing) == [token] else {
            return TestResult(.failed, "Token non extrait d'un label sortant")
        }
        // Label entrant
        let incoming = "message, \(token)"
        guard ManicryptMessageFormat.encryptedTokens(in: incoming) == [token] else {
            return TestResult(.failed, "Token non extrait d'un label entrant")
        }
        // Deux tokens (réponse citant un message chiffré)
        let double = "Replying to You. message, \(token), \(token), 09:12"
        guard ManicryptMessageFormat.encryptedTokens(in: double).count == 2 else {
            return TestResult(.failed, "Extraction multiple cassée")
        }
        // Aucun token
        guard ManicryptMessageFormat.encryptedTokens(in: "Photo from Julien, 12:01").isEmpty else {
            return TestResult(.failed, "Faux positif extraction")
        }
        return TestResult(.passed, "Extraction de tokens dans labels composés OK")
    }

    /// Chaîne complète : chiffrer via crypto_bridge → wrap → détecter → unwrap →
    /// déchiffrer. C'est le chemin exact des briques 3 et 4.
    private func testRealCryptoRoundTrip() -> TestResult {
        let plaintext = "Message transparent Manicrypt — éàü 🔐"
        let passphrase = TestConstants.testPassphrase

        guard let encResult = swift_encrypt_data(plaintext, passphrase) else {
            return TestResult(.failed, "Allocation chiffrement échouée")
        }
        defer { free_crypto_result(encResult) }
        let enc = encResult.pointee
        guard enc.success == 1,
              let base64 = swift_base64_encode(enc.data, Int32(enc.length)) else {
            return TestResult(.failed, "Chiffrement/encodage échoué")
        }
        defer { free(base64) }

        let wire = ManicryptMessageFormat.wrap(String(cString: base64))
        guard ManicryptMessageFormat.isEncryptedMessage(wire) else {
            return TestResult(.failed, "Vrai chiffré non détecté comme message v1")
        }

        let payload = ManicryptMessageFormat.payloadForDecryption(wire)
        guard let decodeResult = swift_base64_decode(payload) else {
            return TestResult(.failed, "Décodage base64 du payload échoué")
        }
        defer { free_crypto_result(decodeResult) }
        let decoded = decodeResult.pointee
        guard decoded.success == 1,
              let decryptResult = swift_decrypt_data(decoded.data, Int32(decoded.length), passphrase) else {
            return TestResult(.failed, "Déchiffrement du payload échoué")
        }
        defer { free_crypto_result(decryptResult) }
        let dec = decryptResult.pointee
        guard dec.success == 1, String(cString: dec.data) == plaintext else {
            return TestResult(.failed, "Round-trip crypto+format non fidèle")
        }
        return TestResult(.passed, "Round-trip crypto réel via format MC1. OK")
    }
}
