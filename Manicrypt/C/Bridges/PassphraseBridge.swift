//
//  PassphraseBridge.swift
//  Manicrypt
//
//  Bridge Swift pour le générateur de passphrases en C
//

import Foundation

class PassphraseBridge {
    static let shared = PassphraseBridge()
    
    private init() {
        // Charger la wordlist au démarrage
        load_eff_wordlist(nil)
    }
    
    deinit {
        // Nettoyer la wordlist
        cleanup_wordlist()
    }
    
    /// Génère une passphrase avec les options spécifiées
    func generatePassphrase(
        wordCount: Int,
        capitalize: Bool = false,
        includeDigit: Bool = false,
        includeSymbol: Bool = false
    ) -> (passphrase: String?, entropy: Double, error: String?) {
        
        // Créer les options
        var options = PassphraseOptions(
            word_count: Int32(wordCount),
            capitalize_word: capitalize,
            add_digit: includeDigit,
            add_symbol: includeSymbol
        )
        
        // Générer la passphrase
        guard let result = generate_passphrase(&options) else {
            return (nil, 0, "Failed to allocate memory")
        }
        
        defer {
            free_passphrase_result(result)
        }
        
        let resultData = result.pointee
        
        if resultData.success == 1 {
            // Succès - copier la passphrase
            let passphrase = String(cString: resultData.passphrase)
            let entropy = resultData.entropy_bits
            return (passphrase, entropy, nil)
        } else {
            // Erreur
            let error = String(cString: resultData.error_message)
            return (nil, 0, error)
        }
    }
    
    /// Calcule l'entropie pour une configuration donnée
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
        
        return calculate_entropy(&options)
    }
    
    /// Obtient l'évaluation de sécurité pour une entropie donnée
    func getSecurityRating(entropy: Double) -> String {
        guard let rating = get_security_rating(entropy) else {
            return "Unknown"
        }
        return String(cString: rating)
    }
    
    /// Génère un nombre aléatoire sécurisé dans une plage
    func secureRandomInRange(min: Int, max: Int) -> Int? {
        let result = secure_random_range(Int32(min), Int32(max))
        return result >= 0 ? Int(result) : nil
    }
}

// MARK: - Extension pour l'intégration avec PassphraseManager
extension PassphraseManager {
    
    /// Version optimisée utilisant le générateur C
    func generateNewPassphraseOptimized(
        wordCount: Int,
        capitalize: Bool,
        includeDigit: Bool,
        includeSymbol: Bool
    ) -> Bool {
        // Clear any existing passphrase first
        clearCurrentPassphrase()
        
        let (passphrase, entropy, error) = PassphraseBridge.shared.generatePassphrase(
            wordCount: wordCount,
            capitalize: capitalize,
            includeDigit: includeDigit,
            includeSymbol: includeSymbol
        )
        
        guard let passphrase = passphrase else {
            print("❌ Failed to generate passphrase: \(error ?? "Unknown error")")
            return false
        }
        
        // Store in memory temporarily
        currentPassphrase = passphrase
        // Ne pas accéder directement à passphraseData qui est privé
        // Le manager gère ça en interne via currentPassphrase
        isPassphraseGenerated = true
        
        // Start session timer via la méthode publique
        restartSessionTimer()
        
        print("✅ Generated new passphrase with \(wordCount) words (Entropy: \(Int(entropy)) bits)")
        return true
    }
}

// MARK: - Extension publique pour PassphraseManager
extension PassphraseManager {
    /// Redémarre le timer de session (méthode publique)
    func restartSessionTimer() {
        startSessionTimer()
    }
}
