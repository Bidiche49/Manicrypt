//
//  MigrationTester.swift
//  Manicrypt
//
//  Utilitaire pour tester la migration et la suppression des données legacy
//

import Foundation

class MigrationTester: TestRunner {
    static let shared = MigrationTester()
    
    let testName = "Migration"
    
    private enum LegacyKeys {
        static let tempPassphrase = "manicrypt_temp_passphrase"
        static let hasPassphrase = "manicrypt_has_passphrase"
        static let useGlobalHotkeys = "useGlobalHotkeys"
        static let lastVersion = "manicrypt_last_version"
    }
    
    private init() {}
    
    func runTests() -> [TestResult] {
        print("🧪 === TESTS MIGRATION ===")
        
        var results: [TestResult] = []
        
        // Test 1: Détection données legacy
        results.append(testLegacyDataDetection())
        
        // Test 2: Migration complète
        results.append(testCompleteMigration())
        
        // Test 3: Nettoyage
        results.append(testCleanup())
        
        return results
    }
    
    func cleanup() {
        // Nettoyer les données de test
        cleanAllDataForTesting()
    }
    
    private func testLegacyDataDetection() -> TestResult {
        print("1️⃣ Test détection données legacy...")
        
        // Créer des données legacy temporaires
        createLegacyData()
        
        let hasLegacy = hasLegacyData()
        
        if hasLegacy {
            return TestResult(.passed, "Détection données legacy")
        } else {
            return TestResult(.failed, "Échec détection données legacy")
        }
    }
    
    private func testCompleteMigration() -> TestResult {
        print("2️⃣ Test migration complète...")
        
        // S'assurer qu'il y a des données legacy
        createLegacyData()
        
        if !hasLegacyData() {
            return TestResult(.failed, "Impossible de créer données legacy pour test")
        }
        
        // Effectuer la migration
        performMigration()
        
        // Vérifier que les données sont supprimées
        let legacyGone = !hasLegacyData()
        
        if legacyGone {
            return TestResult(.passed, "Migration complète réussie")
        } else {
            return TestResult(.failed, "Données legacy persistent après migration")
        }
    }
    
    private func testCleanup() -> TestResult {
        print("3️⃣ Test nettoyage...")
        
        // Créer différents types de données
        UserDefaults.standard.set("test", forKey: "manicrypt_test_1")
        UserDefaults.standard.set("test", forKey: "manicrypt_test_2")
        UserDefaults.standard.synchronize()
        
        // Nettoyer
        cleanAllDataForTesting()
        
        // Vérifier
        let test1Gone = UserDefaults.standard.object(forKey: "manicrypt_test_1") == nil
        let test2Gone = UserDefaults.standard.object(forKey: "manicrypt_test_2") == nil
        
        if test1Gone && test2Gone {
            return TestResult(.passed, "Nettoyage complet")
        } else {
            return TestResult(.failed, "Nettoyage incomplet")
        }
    }
    
    /// Crée des données legacy pour tester la migration
    func createLegacyData() {
        print("🧪 Création de données legacy pour test...")
        
        // Simuler l'ancienne méthode de stockage NON SÉCURISÉE
        UserDefaults.standard.set("test_passphrase_insecure", forKey: LegacyKeys.tempPassphrase)
        UserDefaults.standard.set(true, forKey: LegacyKeys.hasPassphrase)
        UserDefaults.standard.set(true, forKey: LegacyKeys.useGlobalHotkeys)
        UserDefaults.standard.set("0.9", forKey: LegacyKeys.lastVersion)
        UserDefaults.standard.synchronize()
        
        print("✅ Données legacy créées pour simulation")
        listAllUserDefaults()
    }
    
    /// Vérifie si des données legacy existent
    func hasLegacyData() -> Bool {
        let tempPassphrase = UserDefaults.standard.object(forKey: LegacyKeys.tempPassphrase)
        let hasPassphrase = UserDefaults.standard.object(forKey: LegacyKeys.hasPassphrase)
        
        return tempPassphrase != nil || hasPassphrase != nil
    }
    
    /// Teste la migration complète
    func testMigration() {
        print("\n🔄 === TEST DE MIGRATION ===")
        
        // 1. Créer des données legacy
        print("1️⃣ Création des données legacy...")
        createLegacyData()
        
        // 2. Vérifier qu'elles existent
        print("2️⃣ Vérification des données legacy...")
        assert(hasLegacyData(), "❌ Les données legacy n'ont pas été créées")
        print("✅ Données legacy confirmées")
        
        // 3. Déclencher la migration (normalement fait par AppDelegate)
        print("3️⃣ Déclenchement de la migration...")
        performMigration()
        
        // 4. Vérifier que les données sont supprimées
        print("4️⃣ Vérification de la suppression...")
        let stillHasLegacy = hasLegacyData()
        if stillHasLegacy {
            print("❌ ÉCHEC: Des données legacy persistent")
            listAllUserDefaults()
        } else {
            print("✅ SUCCÈS: Toutes les données legacy ont été supprimées")
        }
        
        print("=== FIN TEST MIGRATION ===\n")
    }
    
    /// Effectue la migration (copie de la logique d'AppDelegate)
    private func performMigration() {
        let legacyKeys = [
            LegacyKeys.tempPassphrase,
            LegacyKeys.hasPassphrase
        ]
        
        var foundLegacyData = false
        for key in legacyKeys {
            if UserDefaults.standard.object(forKey: key) != nil {
                print("🧹 Suppression des données legacy: \(key)")
                UserDefaults.standard.removeObject(forKey: key)
                foundLegacyData = true
            }
        }
        
        if foundLegacyData {
            UserDefaults.standard.synchronize()
            print("✅ Migration terminée")
        }
    }
    
    /// Liste toutes les clés UserDefaults pour debug
    func listAllUserDefaults() {
        print("📋 Contenu actuel des UserDefaults:")
        let domain = Bundle.main.bundleIdentifier ?? "com.manicrypt.app"
        let defaults = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        
        for (key, value) in defaults {
            if key.contains("manicrypt") || key.contains("useGlobalHotkeys") {
                print("   \(key): \(value)")
            }
        }
        
        if defaults.isEmpty {
            print("   (aucune donnée trouvée)")
        }
    }
    
    /// Nettoie complètement toutes les données pour test
    func cleanAllDataForTesting() {
        print("🧹 Nettoyage complet pour test...")
        
        let allKeys = [
            LegacyKeys.tempPassphrase,
            LegacyKeys.hasPassphrase,
            LegacyKeys.useGlobalHotkeys,
            LegacyKeys.lastVersion,
            "manicrypt_last_version",
            "manicrypt_has_shown_welcome",
            "manicrypt_last_permission_check"
        ]
        
        for key in allKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        
        UserDefaults.standard.synchronize()
        
        // Aussi nettoyer le Keychain
        try? SecureKeychainManager.shared.deleteGlobalPassphrase()
        
        print("✅ Nettoyage complet terminé")
    }
}
