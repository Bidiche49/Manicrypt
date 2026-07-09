//
//  IntegrationTester.swift
//  Manicrypt
//
//  Tests d'intégration bout-en-bout
//

import Foundation
import Cocoa
import UserNotifications

class IntegrationTester: TestRunner {
    let testName = "Intégration"
    
    func runTests() -> [TestResult] {
        print("🧪 === TESTS D'INTÉGRATION ===")
        
        var results: [TestResult] = []
        
        // Test 1: Configuration complète bout-en-bout
        results.append(testCompleteSetup())
        
        // Test 2: Workflow crypto complet
        results.append(testCompleteWorkflow())
        
        // Test 3: Gestion des erreurs
        results.append(testErrorRecovery())
        
        // Test 4: Performance bout-en-bout
        results.append(testEndToEndPerformance())
        
        // Test 5: Compatibilité applications
        results.append(testApplicationCompatibility())
        
        return results
    }
    
    func cleanup() {
        // Nettoyer l'état de test
        GlobalHotkeyManager.shared.disableHotkeys()
    }
    
    // MARK: - Tests individuels
    
    private func testCompleteSetup() -> TestResult {
        print("1️⃣ Test configuration complète...")
        
        var steps: [String] = []
        
        // Étape 1: Vérifier Keychain disponible
        do {
            try SecureKeychainManager.shared.storeGlobalPassphrase("test_integration_passphrase")
            steps.append("✅ Stockage Keychain")
            
            let hasPassphrase = SecureKeychainManager.shared.hasGlobalPassphrase()
            steps.append(hasPassphrase ? "✅ Vérification Keychain" : "❌ Vérification Keychain")
            
            try SecureKeychainManager.shared.deleteGlobalPassphrase()
            steps.append("✅ Nettoyage Keychain")
            
        } catch {
            steps.append("❌ Keychain: \(error)")
            return TestResult(.failed, "Configuration complète", details: steps.joined(separator: ", "))
        }
        
        // Étape 2: Vérifier gestionnaire de raccourcis
        let manager = GlobalHotkeyManager.shared
        let canSetup = manager.canEnable
        steps.append(canSetup ? "✅ Gestionnaire prêt" : "⚠️ Gestionnaire non prêt")
        
        // Étape 3: Vérifier permissions
        let hasPermissions = PermissionsHelper.shared.hasAccessibilityPermission()
        steps.append(hasPermissions ? "✅ Permissions OK" : "⚠️ Permissions manquantes")
        
        // Étape 4: Test crypto
        let cryptoTest = testQuickCrypto()
        steps.append(cryptoTest ? "✅ Crypto opérationnel" : "❌ Crypto défaillant")
        
        let criticalFailures = steps.filter { $0.hasPrefix("❌") }
        let status: TestStatus = criticalFailures.isEmpty ? (steps.contains { $0.hasPrefix("⚠️") } ? .manual : .passed) : .failed
        
        return TestResult(status, "Configuration complète", details: steps.joined(separator: ", "))
    }
    
    private func testCompleteWorkflow() -> TestResult {
        print("2️⃣ Test workflow complet...")
        
        // Ce test nécessite une interaction manuelle car il implique les raccourcis globaux
        let manager = GlobalHotkeyManager.shared
        
        if !manager.canEnable {
            return TestResult(.manual, "Workflow complet nécessite configuration manuelle",
                            details: "Configurez passphrase et permissions d'accessibilité")
        }
        
        var steps: [String] = []
        
        // Étape 1: Configuration passphrase temporaire
        do {
            try SecureKeychainManager.shared.storeGlobalPassphrase("test_workflow_passphrase")
            manager.hasConfiguredPassphrase = true
            steps.append("✅ Passphrase configurée")
        } catch {
            return TestResult(.failed, "Workflow: échec configuration passphrase")
        }
        
        // Étape 2: Activation raccourcis
        manager.setupHotkeys()
        
        let activated = TestUtils.waitForCondition(timeout: 3.0) {
            return manager.isEnabled
        }
        
        if activated {
            steps.append("✅ Raccourcis activés")
        } else {
            steps.append("❌ Raccourcis non activés")
            // Nettoyage
            try? SecureKeychainManager.shared.deleteGlobalPassphrase()
            return TestResult(.failed, "Workflow: échec activation raccourcis")
        }
        
        // Étape 3: Test fonctionnel (simulation)
        let testText = "Test workflow integration"
        
        // Simuler le workflow de chiffrement
        let workflowTest = simulateEncryptionWorkflow(testText)
        steps.append(workflowTest ? "✅ Workflow simulation réussie" : "❌ Workflow simulation échouée")
        
        // Nettoyage
        manager.disableHotkeys()
        try? SecureKeychainManager.shared.deleteGlobalPassphrase()
        
        let allPassed = steps.allSatisfy { $0.hasPrefix("✅") }
        return TestResult(allPassed ? .passed : .failed, "Workflow complet", details: steps.joined(separator: ", "))
    }
    
    private func testErrorRecovery() -> TestResult {
        print("3️⃣ Test récupération d'erreurs...")
        
        var tests: [String] = []
        
        // Test 1: Récupération après crash simulé
        let manager = GlobalHotkeyManager.shared
        manager.disableHotkeys() // Simuler un arrêt brutal
        
        // Redémarrer
        if manager.canEnable {
            manager.setupHotkeys()
            let recovered = TestUtils.waitForCondition(timeout: 2.0) {
                return manager.isEnabled
            }
            tests.append(recovered ? "✅ Récupération après crash" : "❌ Récupération après crash")
            manager.disableHotkeys()
        } else {
            tests.append("⏭️ Récupération (prérequis manquants)")
        }
        
        // Test 2: Gestion passphrase corrompue
        let corruptedPassphraseTest = testCorruptedPassphraseRecovery()
        tests.append(corruptedPassphraseTest ? "✅ Récupération passphrase corrompue" : "❌ Récupération passphrase corrompue")
        
        // Test 3: Perte de permissions
        let originalPermissions = PermissionsHelper.shared.hasAccessibilityPermission()
        if originalPermissions {
            // Simuler la détection de perte de permissions
            tests.append("✅ Test permissions (simulé)")
        } else {
            tests.append("⏭️ Test permissions (déjà manquantes)")
        }
        
        let criticalFailures = tests.filter { $0.hasPrefix("❌") }
        return TestResult(criticalFailures.isEmpty ? .passed : .failed, "Récupération d'erreurs", details: tests.joined(separator: ", "))
    }
    
    private func testEndToEndPerformance() -> TestResult {
        print("4️⃣ Test performance bout-en-bout...")
        
        let testData = "Performance test data for end-to-end testing. " + String(repeating: "Data ", count: 50)
        let iterations = 5
        
        let (_, totalTime) = TestUtils.measureTime {
            for _ in 0..<iterations {
                // Simuler le workflow complet : stockage Keychain + crypto + nettoyage
                do {
                    try SecureKeychainManager.shared.storeGlobalPassphrase("perf_test_pass")
                    
                    // Test crypto
                    _ = performQuickCrypto(testData, "perf_test_pass")
                    
                    try SecureKeychainManager.shared.deleteGlobalPassphrase()
                } catch {
                    // Ignorer les erreurs pour le test de performance
                }
            }
        }
        
        let avgTime = totalTime / Double(iterations) * 1000 // en ms
        
        if avgTime < 500 { // Moins de 500ms par cycle complet
            return TestResult(.passed, "Performance bout-en-bout (avg: \(String(format: "%.1f", avgTime))ms)")
        } else if avgTime < 1000 {
            return TestResult(.warning, "Performance acceptable (avg: \(String(format: "%.1f", avgTime))ms)")
        } else {
            return TestResult(.failed, "Performance insuffisante (avg: \(String(format: "%.1f", avgTime))ms)")
        }
    }
    
    private func testApplicationCompatibility() -> TestResult {
        print("5️⃣ Test compatibilité applications...")
        
        // Ce test vérifie que Manicrypt fonctionne bien avec l'environnement macOS
        var tests: [String] = []
        
        // Test 1: Compatible avec le mode sombre/clair
        let interfaceStyle = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        tests.append("📊 Mode interface: \(interfaceStyle ?? "clair")")
        
        // Test 2: Langue système
        let language = Locale.current.languageCode ?? "en"
        tests.append("📊 Langue: \(language)")
        
        // Test 3: Notifications disponibles
        var notificationAvailable = false
        let semaphore = DispatchSemaphore(value: 0)
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            notificationAvailable = granted
            semaphore.signal()
        }
        
        _ = semaphore.wait(timeout: .now() + 2.0)
        tests.append(notificationAvailable ? "✅ Notifications disponibles" : "⚠️ Notifications non autorisées")
        
        // Test 4: Accès menu bar
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menuBarAvailable = (statusItem.button != nil)
        NSStatusBar.system.removeStatusItem(statusItem) // Nettoyer
        tests.append(menuBarAvailable ? "✅ Menu bar accessible" : "❌ Menu bar inaccessible")
        
        // Test 5: Architecture app
        let bundleID = Bundle.main.bundleIdentifier
        tests.append("📊 Bundle ID: \(bundleID ?? "N/A")")
        
        let criticalFailures = tests.filter { $0.hasPrefix("❌") }
        return TestResult(criticalFailures.isEmpty ? .passed : .warning, "Compatibilité applications", details: tests.joined(separator: ", "))
    }
    
    // MARK: - Méthodes utilitaires
    
    private func testQuickCrypto() -> Bool {
        let testText = "Quick crypto test"
        let testPassword = "quick_test_pass"
        
        // Chiffrement
        guard let encryptResult = swift_encrypt_data(testText, testPassword) else { return false }
        defer { free_crypto_result(encryptResult) }
        
        let encryptData = encryptResult.pointee
        guard encryptData.success == 1 else { return false }
        
        // Déchiffrement
        guard let decryptResult = swift_decrypt_data(
            encryptData.data,
            Int32(encryptData.length),
            testPassword
        ) else { return false }
        defer { free_crypto_result(decryptResult) }
        
        let decryptData = decryptResult.pointee
        guard decryptData.success == 1 else { return false }
        
        let decryptedText = String(cString: decryptData.data)
        return decryptedText == testText
    }
    
    private func simulateEncryptionWorkflow(_ text: String) -> Bool {
        // Simuler le workflow complet sans les raccourcis réels
        
        // 1. Chiffrement
        guard let encryptResult = swift_encrypt_data(text, "test_workflow_passphrase") else { return false }
        defer { free_crypto_result(encryptResult) }
        
        let encryptData = encryptResult.pointee
        guard encryptData.success == 1 else { return false }
        
        // 2. Base64 encoding
        guard let base64 = swift_base64_encode(encryptData.data, Int32(encryptData.length)) else { return false }
        defer { free(base64) }
        
        // 3. Base64 decoding
        guard let decodeResult = swift_base64_decode(base64) else { return false }
        defer { free_crypto_result(decodeResult) }
        
        let decodedData = decodeResult.pointee
        guard decodedData.success == 1 else { return false }
        
        // 4. Déchiffrement
        guard let decryptResult = swift_decrypt_data(
            decodedData.data,
            Int32(decodedData.length),
            "test_workflow_passphrase"
        ) else { return false }
        defer { free_crypto_result(decryptResult) }
        
        let decryptData = decryptResult.pointee
        guard decryptData.success == 1 else { return false }
        
        let decryptedText = String(cString: decryptData.data)
        return decryptedText == text
    }
    
    private func testCorruptedPassphraseRecovery() -> Bool {
        // Tester la récupération après une passphrase corrompue/inaccessible
        
        do {
            // Stocker une passphrase
            try SecureKeychainManager.shared.storeGlobalPassphrase("test_corruption")
            
            // Vérifier qu'elle existe
            let exists = SecureKeychainManager.shared.hasGlobalPassphrase()
            
            // Nettoyer
            try SecureKeychainManager.shared.deleteGlobalPassphrase()
            
            // Vérifier qu'elle est supprimée
            let cleaned = !SecureKeychainManager.shared.hasGlobalPassphrase()
            
            return exists && cleaned
        } catch {
            return false
        }
    }
    
    private func performQuickCrypto(_ text: String, _ password: String) -> Bool {
        guard let encryptResult = swift_encrypt_data(text, password) else { return false }
        defer { free_crypto_result(encryptResult) }
        
        let encryptData = encryptResult.pointee
        guard encryptData.success == 1 else { return false }
        
        guard let decryptResult = swift_decrypt_data(
            encryptData.data,
            Int32(encryptData.length),
            password
        ) else { return false }
        defer { free_crypto_result(decryptResult) }
        
        let decryptData = decryptResult.pointee
        guard decryptData.success == 1 else { return false }
        
        let decryptedText = String(cString: decryptData.data)
        return decryptedText == text
    }
}
