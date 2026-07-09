//
//  TestOrchestrator.swift
//  Manicrypt
//
//  Coordinateur principal pour orchestrer tous les tests
//

/*
 🛠️ UTILISATION PRATIQUE :
 1. Tests automatisés complets :
 swift// Via menu debug ou code :
 TestOrchestrator.shared.runAllTests()
 2. Validation rapide (< 10 secondes) :
 swiftTestOrchestrator.shared.runQuickValidation()
 3. Test spécifique :
 swiftTestOrchestrator.shared.runSpecificTest("crypto")
 TestOrchestrator.shared.runSpecificTest("keychain")
 4. Tests sans interaction :
 swiftTestOrchestrator.shared.runAutomatedTestsOnly()
 5. Rapport de diagnostic :
 swiftlet report = TestOrchestrator.shared.generateDiagnosticReport()
 
 */


import Foundation
import Cocoa

class TestOrchestrator {
    static let shared = TestOrchestrator()
    
    private let testRunners: [TestRunner] = [
        CryptoTester(),
        KeychainTester.shared as TestRunner,
        MigrationTester.shared as TestRunner,
        PermissionTester(),
        HotkeyTester(),
        IntegrationTester()
    ]
    
    private init() {}
    
    /// Lance tous les tests avec rapport complet
    func runAllTests() {
        print("\n🚀 === ORCHESTRATEUR DE TESTS MANICRYPT ===")
        print("Date: \(DateFormatter.fullFormatter.string(from: Date()))")
        print("Version: \(getCurrentVersion())")
        print("Système: \(getSystemInfo())")
        print("======================================================\n")
        
        var allSuites: [TestSuite] = []
        let globalStartTime = Date()
        
        for runner in testRunners {
            let suite = runTestSuite(runner)
            allSuites.append(suite)
            
            // Pause entre les suites pour éviter les interférences
            Thread.sleep(forTimeInterval: 0.5)
        }
        
        let globalEndTime = Date()
        
        // Afficher le rapport global
        printGlobalReport(suites: allSuites, startTime: globalStartTime, endTime: globalEndTime)
        
        // Générer recommandations
        generateRecommendations(suites: allSuites)
    }
    
    /// Lance un test spécifique par nom
    func runSpecificTest(_ testName: String) {
        guard let runner = testRunners.first(where: { $0.testName.lowercased().contains(testName.lowercased()) }) else {
            print("❌ Test '\(testName)' non trouvé")
            print("Tests disponibles: \(testRunners.map { $0.testName }.joined(separator: ", "))")
            return
        }
        
        print("\n🎯 === TEST SPÉCIFIQUE: \(runner.testName.uppercased()) ===")
        let suite = runTestSuite(runner)
        TestUtils.printTestSuite(suite)
    }
    
    /// Lance seulement les tests automatisés (sans interaction)
    func runAutomatedTestsOnly() {
        print("\n🤖 === TESTS AUTOMATISÉS UNIQUEMENT ===")
        
        let automatedRunners = testRunners.filter { runner in
            // Exclure les tests qui nécessitent une interaction manuelle
            return !(runner is HotkeyTester) // Les raccourcis nécessitent souvent une interaction
        }
        
        var allSuites: [TestSuite] = []
        
        for runner in automatedRunners {
            let suite = runTestSuite(runner)
            allSuites.append(suite)
        }
        
        printAutomatedReport(suites: allSuites)
    }
    
    /// Lance les tests de validation rapide
    func runQuickValidation() {
        print("\n⚡ === VALIDATION RAPIDE ===")
        
        var results: [TestResult] = []
        
        // Test 1: Crypto de base
        let cryptoTester = CryptoTester()
        let cryptoResults = cryptoTester.runTests()
        let cryptoPassed = cryptoResults.filter { $0.status == .passed }.count
        results.append(TestResult(
            cryptoPassed >= 4 ? .passed : .failed,
            "Crypto (\(cryptoPassed)/\(cryptoResults.count) tests passés)"
        ))
        
        // Test 2: Keychain de base
        let keychainTester = KeychainTester.shared
        _ = keychainTester.testManicryptKeychain()
        let hasKeychain = SecureKeychainManager.shared.isBiometryAvailable()
        results.append(TestResult(
            hasKeychain ? .passed : .warning,
            "Keychain \(hasKeychain ? "disponible" : "limité")"
        ))
        
        // Test 3: Permissions
        let hasPermissions = PermissionsHelper.shared.hasAccessibilityPermission()
        results.append(TestResult(
            hasPermissions ? .passed : .manual,
            "Permissions \(hasPermissions ? "accordées" : "requises")"
        ))
        
        // Test 4: Configuration
        let manager = GlobalHotkeyManager.shared
        let canEnable = manager.canEnable
        results.append(TestResult(
            canEnable ? .passed : .manual,
            "Configuration \(canEnable ? "complète" : "incomplète")"
        ))
        
        // Afficher les résultats
        print("\n📊 Résultats validation rapide:")
        for result in results {
            TestUtils.printTestResult(result)
        }
        
        let criticalIssues = results.filter { $0.status == .failed }.count
        let readyToUse = results.filter { $0.status == .passed }.count >= 3
        
        print("\n🎯 Conclusion:")
        if criticalIssues == 0 && readyToUse {
            print("   ✅ Manicrypt est prêt à l'utilisation")
        } else if criticalIssues == 0 {
            print("   ⚠️ Configuration manuelle requise")
        } else {
            print("   ❌ Problèmes critiques détectés")
        }
        print("")
    }
    
    /// Génère un rapport de diagnostic pour le support
    func generateDiagnosticReport() -> String {
        print("📋 Génération du rapport de diagnostic...")
        
        var report = """
        RAPPORT DE DIAGNOSTIC MANICRYPT
        ==============================
        Date: \(DateFormatter.fullFormatter.string(from: Date()))
        Version Manicrypt: \(getCurrentVersion())
        Système: \(getSystemInfo())
        
        """
        
        // Tests rapides
        let quickResults = runQuickDiagnostic()
        report += "TESTS RAPIDES:\n"
        for result in quickResults {
            report += "- \(result.message): \(result.status)\n"
        }
        report += "\n"
        
        // Configuration actuelle
        report += getConfigurationSummary()
        
        // Recommandations
        report += "\nRECOMMANDATIONS:\n"
        report += generateQuickRecommendations(quickResults)
        
        print("✅ Rapport de diagnostic généré")
        return report
    }
    
    // MARK: - Méthodes privées
    
    private func runTestSuite(_ runner: TestRunner) -> TestSuite {
        let startTime = Date()
        let results = runner.runTests()
        let endTime = Date()
        
        let suite = TestSuite(
            name: runner.testName,
            results: results,
            startTime: startTime,
            endTime: endTime
        )
        
        TestUtils.printTestSuite(suite)
        
        // Nettoyage après chaque suite
        runner.cleanup()
        
        return suite
    }
    
    private func printGlobalReport(suites: [TestSuite], startTime: Date, endTime: Date) {
        let totalDuration = endTime.timeIntervalSince(startTime)
        let totalTests = suites.reduce(0) { $0 + $1.results.count }
        let totalPassed = suites.reduce(0) { $0 + $1.passedCount }
        let totalFailed = suites.reduce(0) { $0 + $1.failedCount }
        let totalSkipped = suites.reduce(0) { $0 + $1.skippedCount }
        
        print("🏆 === RAPPORT GLOBAL ===")
        print("Durée totale: \(String(format: "%.2f", totalDuration))s")
        print("Suites exécutées: \(suites.count)")
        print("Tests totaux: \(totalTests)")
        print("Réussis: \(totalPassed) (\(String(format: "%.1f", Double(totalPassed)/Double(totalTests)*100))%)")
        print("Échecs: \(totalFailed)")
        print("Ignorés: \(totalSkipped)")
        print("")
        
        // Résumé par suite
        print("📊 Résumé par suite:")
        for suite in suites {
            let status = suite.failedCount == 0 ? "✅" : "❌"
            print("   \(status) \(suite.name): \(suite.passedCount)/\(suite.results.count) (\(String(format: "%.1f", suite.successRate))%)")
        }
        print("")
        
        // Score global
        let globalScore = Double(totalPassed) / Double(totalTests) * 100
        if globalScore >= 90 {
            print("🎉 EXCELLENT: Manicrypt fonctionne parfaitement!")
        } else if globalScore >= 75 {
            print("👍 BON: Manicrypt fonctionne bien avec quelques améliorations possibles")
        } else if globalScore >= 50 {
            print("⚠️ MOYEN: Configuration requise pour un fonctionnement optimal")
        } else {
            print("❌ PROBLÈMES: Des corrections importantes sont nécessaires")
        }
        print("==========================\n")
    }
    
    private func printAutomatedReport(suites: [TestSuite]) {
        let totalTests = suites.reduce(0) { $0 + $1.results.count }
        let totalPassed = suites.reduce(0) { $0 + $1.passedCount }
        
        print("🤖 Résultats tests automatisés:")
        print("   Score: \(totalPassed)/\(totalTests) (\(String(format: "%.1f", Double(totalPassed)/Double(totalTests)*100))%)")
        
        let canRunInCI = totalPassed == totalTests
        print("   CI/CD Ready: \(canRunInCI ? "✅" : "❌")")
        print("")
    }
    
    private func generateRecommendations(suites: [TestSuite]) {
        print("💡 === RECOMMANDATIONS ===")
        
        var recommendations: [String] = []
        
        // Analyser chaque suite
        for suite in suites {
            if suite.failedCount > 0 {
                switch suite.name {
                case "Crypto":
                    recommendations.append("🔧 Vérifiez l'installation d'OpenSSL et les fonctions crypto")
                case "Keychain":
                    recommendations.append("🔐 Configurez Touch ID/Face ID ou vérifiez les permissions Keychain")
                case "Permissions":
                    recommendations.append("⚙️ Accordez les permissions d'accessibilité dans Préférences Système")
                case "Raccourcis Globaux":
                    recommendations.append("⌨️ Vérifiez les permissions et la configuration des raccourcis")
                case "Intégration":
                    recommendations.append("🔄 Effectuez une configuration complète étape par étape")
                default:
                    recommendations.append("❓ Consultez les logs pour \(suite.name)")
                }
            }
        }
        
        // Recommandations générales
        let totalScore = suites.reduce(0.0) { $0 + $1.successRate } / Double(suites.count)
        
        if totalScore < 75 {
            recommendations.append("📖 Consultez le guide de troubleshooting")
            recommendations.append("🆘 Contactez le support avec ce rapport")
        }
        
        if recommendations.isEmpty {
            print("   ✅ Aucune recommandation - tout fonctionne parfaitement!")
        } else {
            for (index, recommendation) in recommendations.enumerated() {
                print("   \(index + 1). \(recommendation)")
            }
        }
        print("==========================\n")
    }
    
    private func runQuickDiagnostic() -> [TestResult] {
        // Version simplifiée pour diagnostic rapide
        var results: [TestResult] = []
        
        // Crypto
        let cryptoWorking = CryptoTester().testQuickCrypto()
        results.append(TestResult(cryptoWorking ? .passed : .failed, "Crypto"))
        
        // Keychain
        let biometryAvailable = SecureKeychainManager.shared.isBiometryAvailable()
        results.append(TestResult(biometryAvailable ? .passed : .warning, "Biométrie"))
        
        // Permissions
        let hasPermissions = PermissionsHelper.shared.hasAccessibilityPermission()
        results.append(TestResult(hasPermissions ? .passed : .manual, "Permissions"))
        
        return results
    }
    
    private func getConfigurationSummary() -> String {
        var summary = "CONFIGURATION ACTUELLE:\n"
        
        let manager = GlobalHotkeyManager.shared
        summary += "- Passphrase configurée: \(manager.hasConfiguredPassphrase)\n"
        summary += "- Raccourcis actifs: \(manager.isEnabled)\n"
        summary += "- Permissions accordées: \(PermissionsHelper.shared.hasAccessibilityPermission())\n"
        summary += "- Biométrie disponible: \(SecureKeychainManager.shared.isBiometryAvailable())\n"
        
        return summary + "\n"
    }
    
    private func generateQuickRecommendations(_ results: [TestResult]) -> String {
        var recommendations = ""
        
        for result in results {
            switch result.status {
            case .failed:
                recommendations += "❌ \(result.message): Action immédiate requise\n"
            case .manual:
                recommendations += "👤 \(result.message): Configuration manuelle nécessaire\n"
            case .warning:
                recommendations += "⚠️ \(result.message): Amélioration recommandée\n"
            default:
                break
            }
        }
        
        return recommendations.isEmpty ? "✅ Aucune action requise\n" : recommendations
    }
    
    private func getCurrentVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    private func getSystemInfo() -> String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
    }
}

// MARK: - Extension pour tests individuels isolés

extension CryptoTester {
    func testQuickCrypto() -> Bool {
        let testText = "Quick test"
        let testPassword = "quick_pass"
        
        guard let encryptResult = swift_encrypt_data(testText, testPassword) else { return false }
        defer { free_crypto_result(encryptResult) }
        
        let encryptData = encryptResult.pointee
        guard encryptData.success == 1 else { return false }
        
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
}
