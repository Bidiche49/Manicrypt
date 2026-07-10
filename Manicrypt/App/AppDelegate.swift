//
//  AppDelegate.swift
//  Manicrypt
//
//  Gestionnaire de l'application menu bar CORRIGÉ avec gestion sécurisée
//

import Cocoa
import SwiftUI
import LocalAuthentication
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var settingsHostingController: NSHostingController<SettingsView>?
    private var menu: NSMenu!
    // Sparkle : démarre le cycle de vérification des mises à jour (SUFeedURL de l'Info.plist)
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialiser OpenSSL
        init_openssl()
        
        // Créer l'icône dans la menu bar
        setupMenuBar()
        
        // Créer le popover pour l'interface
        setupPopover()
        
        // Créer le menu contextuel
        setupMenu()
        
        // Ajouter le menu debug en mode debug
        addDebugMenu()
        
        // Configuration initiale et vérifications
        performInitialSetup()
        
        // Test rapide de l'intégration crypto
        testCryptoIntegration()
        
        // Écouter les notifications pour ouvrir les préférences
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: NSNotification.Name("OpenSettings"),
            object: nil
        )
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Désactiver les raccourcis globaux et nettoyer la session
        GlobalHotkeyManager.shared.disableHotkeys()
        
        // Nettoyer OpenSSL à la fermeture
        cleanup_openssl()
        
        // Nettoyer les observers
        NotificationCenter.default.removeObserver(self)
        
        // ✅ AJOUT: Nettoyer proprement les fenêtres
        cleanupWindows()
    }
    
    private func performInitialSetup() {
        print("🚀 Configuration initiale de Manicrypt...")
        
        // Nettoyer les anciennes données non sécurisées
        cleanupLegacyData()
        
        // Vérifier les permissions si c'est le premier lancement ou une nouvelle version
        PermissionsHelper.shared.checkInitialPermissions()
        
        // Diagnostic du système
        DiagnosticHelper.runFullDiagnostic()
        
        // Vérifier si l'utilisateur a une passphrase configurée
        let hasPassphrase = SecureKeychainManager.shared.hasGlobalPassphrase()
        let hasPermissions = PermissionsHelper.shared.hasAccessibilityPermission()
        
        print("📊 État initial:")
        print("   - Passphrase sécurisée: \(hasPassphrase ? "✅" : "❌")")
        print("   - Permissions accessibilité: \(hasPermissions ? "✅" : "❌")")
        
        // Mettre à jour l'état du gestionnaire de raccourcis
        GlobalHotkeyManager.shared.hasConfiguredPassphrase = hasPassphrase
        
        // Tenter d'activer automatiquement les raccourcis si tout est configuré
        if hasPassphrase && hasPermissions {
            print("🎯 Conditions remplies - tentative d'activation automatique des raccourcis")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                GlobalHotkeyManager.shared.setupHotkeys()
            }
        } else {
            print("ℹ️ Configuration incomplète - raccourcis non activés automatiquement")
        }
    }
    
    private func cleanupLegacyData() {
        // Nettoyer les anciennes données UserDefaults non sécurisées
        let legacyKeys = [
            "manicrypt_temp_passphrase", // CRITIQUE: passphrase en clair
            "manicrypt_has_passphrase"
        ]
        
        var foundLegacyData = false
        for key in legacyKeys {
            if UserDefaults.standard.object(forKey: key) != nil {
                print("🧹 Suppression des données legacy non sécurisées: \(key)")
                UserDefaults.standard.removeObject(forKey: key)
                foundLegacyData = true
            }
        }
        
        if foundLegacyData {
            UserDefaults.standard.synchronize()
            print("✅ Nettoyage des données legacy terminé")
        }
    }
    
    private func setupMenuBar() {
        // Créer l'item dans la status bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            // Icône menu bar — glyphe Manicrypt (template, teinté clair/sombre par le système)
            if let image = NSImage(named: "MenuBarIcon") {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            } else {
                button.title = "🔐"
            }
            
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }
    
    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ManicryptView())
    }
    
    private func setupMenu() {
        menu = NSMenu()
        
        // Item principal
        menu.addItem(NSMenuItem(title: "Ouvrir Manicrypt", action: #selector(showPopover), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        // Raccourcis globaux
        let hotkeyItem = NSMenuItem(title: "Raccourcis globaux", action: nil, keyEquivalent: "")
        let hotkeySubmenu = NSMenu()
        
        let encryptItem = NSMenuItem(title: "Chiffrer la sélection (⌃⇧E)", action: #selector(encryptSelection), keyEquivalent: "")
        hotkeySubmenu.addItem(encryptItem)

        let decryptItem = NSMenuItem(title: "Déchiffrer la sélection (⌃⇧D)", action: #selector(decryptSelection), keyEquivalent: "")
        hotkeySubmenu.addItem(decryptItem)
        
        hotkeySubmenu.addItem(NSMenuItem.separator())
        
        // Statut des raccourcis (sera mis à jour dynamiquement)
        let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusItem.tag = 999 // Tag pour l'identifier
        hotkeySubmenu.addItem(statusItem)
        
        hotkeyItem.submenu = hotkeySubmenu
        menu.addItem(hotkeyItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // ✅ CORRECTION: Ajouter le menu passphrase ici
        addPassphraseMenu()
        
        // Préférences
        menu.addItem(NSMenuItem(title: "Préférences...", action: #selector(showSettings), keyEquivalent: ","))

        menu.addItem(NSMenuItem.separator())

        // Mises à jour (Sparkle)
        let updateItem = NSMenuItem(title: "Vérifier les mises à jour…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)

        // À propos et Quitter
        menu.addItem(NSMenuItem(title: "À propos de Manicrypt", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
    
    // ✅ AJOUT: Fonction pour ajouter le menu passphrase
    private func addPassphraseMenu() {
        let toolsItem = NSMenuItem(title: "Outils", action: nil, keyEquivalent: "")
        let toolsMenu = NSMenu()
        
        // Passphrase Generator
        let passphraseItem = NSMenuItem(
            title: "Générateur de passphrase",
            action: #selector(showPassphraseGenerator),
            keyEquivalent: "g"
        )
        passphraseItem.keyEquivalentModifierMask = [.command, .shift]
        toolsMenu.addItem(passphraseItem)
        
        // Retrieve Stored Passphrase
        let retrieveItem = NSMenuItem(
            title: "Récupérer passphrase stockée",
            action: #selector(showPassphraseRetriever),
            keyEquivalent: ""
        )
        toolsMenu.addItem(retrieveItem)
        
        toolsMenu.addItem(NSMenuItem.separator())
        
        // Manage Passphrases
        let manageItem = NSMenuItem(
            title: "Gérer les passphrases...",
            action: #selector(showPassphraseManager),
            keyEquivalent: ""
        )
        toolsMenu.addItem(manageItem)
        
        toolsItem.submenu = toolsMenu
        menu.addItem(toolsItem)
        menu.addItem(NSMenuItem.separator())
    }
    
    // ✅ AJOUT: Actions pour le menu passphrase
    @objc private func showPassphraseGenerator() {
        showPassphraseWindow(content: PassphraseGeneratorView())
    }
    
    @objc private func showPassphraseRetriever() {
        showPassphraseWindow(content: RetrievePassphraseView(), size: NSSize(width: 350, height: 300))
    }
    
    @objc private func showPassphraseManager() {
        showPassphraseWindow(content: PassphraseManagerView())
    }
    
    private func showPassphraseWindow<Content: View>(content: Content, size: NSSize = NSSize(width: 400, height: 600)) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Manicrypt - Générateur de passphrase"
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.isReleasedWhenClosed = true // Les fenêtres d'outils peuvent être libérées
        window.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - Actions Debug - DÉFINIES AVANT UTILISATION
    
    @objc func runAutomatedTests() {
        // Fonction de test si nécessaire
        print("🧪 Lancement des tests automatisés...")
    }
    
    @objc func runQuickValidation() {
        // Validation rapide si nécessaire
        print("⚡ Validation rapide...")
    }
    
    @objc func runSpecificTest() {
        // Demander quel test lancer
        let alert = NSAlert()
        alert.messageText = "Quel test lancer ?"
        alert.informativeText = "Tests disponibles: Crypto, Keychain, Migration, Permissions, Raccourcis, Intégration"
        alert.addButton(withTitle: "Crypto")
        alert.addButton(withTitle: "Keychain")
        alert.addButton(withTitle: "Raccourcis")
        alert.addButton(withTitle: "Annuler")
        
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            print("🔐 Test crypto...")
        case .alertSecondButtonReturn:
            print("🔑 Test keychain...")
        case .alertThirdButtonReturn:
            print("⌨️ Test raccourcis...")
        default:
            break
        }
    }
    
    @objc func generateDiagnosticReport() {
        let report = generateSimpleDiagnosticReport()
        
        // Copier dans le presse-papiers
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        
        showAlert(title: "Rapport généré", message: "Le rapport de diagnostic a été copié dans le presse-papiers")
    }
    
    private func generateSimpleDiagnosticReport() -> String {
        let hasPassphrase = SecureKeychainManager.shared.hasGlobalPassphrase()
        let hasPermissions = PermissionsHelper.shared.hasAccessibilityPermission()
        let hotkeysEnabled = GlobalHotkeyManager.shared.isEnabled
        
        return """
        === RAPPORT DIAGNOSTIC MANICRYPT ===
        Date: \(Date())
        Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
        
        État de la sécurité:
        - Passphrase configurée: \(hasPassphrase ? "✅" : "❌")
        - Permissions accessibilité: \(hasPermissions ? "✅" : "❌")
        - Raccourcis globaux: \(hotkeysEnabled ? "✅" : "❌")
        
        Configuration système:
        - macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        - Bundle ID: \(Bundle.main.bundleIdentifier ?? "inconnu")
        """
    }
    
    @objc func testKeychain() {
        print("🔑 Test Keychain...")
        let hasPassphrase = SecureKeychainManager.shared.hasGlobalPassphrase()
        print("Passphrase configurée: \(hasPassphrase)")
    }
    
    @objc func testMigration() {
        print("🔄 Test migration...")
    }
    
    @objc func createLegacyData() {
        UserDefaults.standard.set("test_legacy", forKey: "manicrypt_temp_passphrase")
        showAlert(title: "Debug", message: "Données legacy créées pour test")
    }
    
    @objc func cleanAllData() {
        let alert = NSAlert()
        alert.messageText = "Nettoyer toutes les données ?"
        alert.informativeText = "Ceci supprimera TOUTES les données Manicrypt pour permettre un test de première installation."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Nettoyer")
        alert.addButton(withTitle: "Annuler")
        
        if alert.runModal() == .alertFirstButtonReturn {
            SecureKeychainManager.shared.cleanupAllSecureData()
            showAlert(title: "Debug", message: "Toutes les données ont été supprimées. Relancez l'app.")
        }
    }
    
    @objc func showUserDefaults() {
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        for (key, value) in defaults {
            if key.contains("manicrypt") {
                print("UserDefault: \(key) = \(value)")
            }
        }
        showAlert(title: "Debug", message: "UserDefaults affichés dans la console")
    }
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
    
    // MARK: - Menu Debug
    
    /// Ajouter ceci dans setupMenu() pour créer un menu de debug
    private func addDebugMenu() {
        #if DEBUG
        menu.addItem(NSMenuItem.separator())
        
        let debugItem = NSMenuItem(title: "🧪 Debug", action: nil, keyEquivalent: "")
        let debugSubmenu = NSMenu()
        
        // Tests automatisés
        debugSubmenu.addItem(NSMenuItem(title: "🚀 Tous les tests", action: #selector(runAutomatedTests), keyEquivalent: ""))
        debugSubmenu.addItem(NSMenuItem(title: "⚡ Validation rapide", action: #selector(runQuickValidation), keyEquivalent: ""))
        debugSubmenu.addItem(NSMenuItem(title: "🎯 Test spécifique", action: #selector(runSpecificTest), keyEquivalent: ""))
        
        debugSubmenu.addItem(NSMenuItem.separator())
        
        // Tests individuels
        debugSubmenu.addItem(NSMenuItem(title: "🔐 Test Keychain", action: #selector(testKeychain), keyEquivalent: ""))
        debugSubmenu.addItem(NSMenuItem(title: "🔄 Test Migration", action: #selector(testMigration), keyEquivalent: ""))
        debugSubmenu.addItem(NSMenuItem(title: "📊 Rapport diagnostic", action: #selector(generateDiagnosticReport), keyEquivalent: ""))
        
        debugSubmenu.addItem(NSMenuItem.separator())
        
        // Outils de données
        debugSubmenu.addItem(NSMenuItem(title: "➕ Créer données legacy", action: #selector(createLegacyData), keyEquivalent: ""))
        debugSubmenu.addItem(NSMenuItem(title: "🧹 Nettoyer toutes données", action: #selector(cleanAllData), keyEquivalent: ""))
        debugSubmenu.addItem(NSMenuItem(title: "📋 Afficher UserDefaults", action: #selector(showUserDefaults), keyEquivalent: ""))
        
        debugItem.submenu = debugSubmenu
        menu.addItem(debugItem)
        #endif
    }
    
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        
        if event.type == .rightMouseUp {
            // Mettre à jour le statut avant d'afficher le menu
            updateMenuStatus()
            
            // Clic droit : afficher le menu
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            // Clic gauche : afficher le popover
            togglePopover()
        }
    }
    
    private func updateMenuStatus() {
        // Mettre à jour le statut des raccourcis dans le menu
        if let hotkeySubmenu = menu.item(withTitle: "Raccourcis globaux")?.submenu,
           let statusItem = hotkeySubmenu.items.first(where: { $0.tag == 999 }) {
            
            let manager = GlobalHotkeyManager.shared
            let isEnabled = manager.isEnabled
            let hasPassphrase = manager.hasConfiguredPassphrase
            let hasPermissions = PermissionsHelper.shared.hasAccessibilityPermission()
            
            let statusText: String
            let statusColor: NSColor
            
            if isEnabled {
                statusText = "✅ Raccourcis actifs"
                statusColor = .systemGreen
            } else if !hasPassphrase {
                statusText = "⚙️ Passphrase non configurée"
                statusColor = .systemOrange
            } else if !hasPermissions {
                statusText = "🔒 Permissions manquantes"
                statusColor = .systemOrange
            } else {
                statusText = "❌ Raccourcis inactifs"
                statusColor = .systemRed
            }
            
            statusItem.attributedTitle = NSAttributedString(
                string: statusText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: statusColor
                ]
            )
        }
    }
    
    @objc private func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
                
                // S'assurer que la fenêtre du popover devient key
                if let popoverWindow = popover.contentViewController?.view.window {
                    popoverWindow.makeKey()
                }
            }
        }
    }
    
    @objc private func showPopover() {
        if let button = statusItem.button {
            if !popover.isShown {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
            }
        }
    }
    
    @objc private func showSettings() {
        openSettings()
    }
    
    // ✅ CORRECTION PRINCIPALE: Gestion sécurisée des préférences
    @objc private func openSettings() {
        print("🔧 Ouverture des préférences...")
        
        // Si une fenêtre existe déjà, la ramener au premier plan
        if let existingWindow = settingsWindow {
            print("🔄 Fenêtre existante trouvée - mise au premier plan")
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Créer le hosting controller AVANT la fenêtre
        settingsHostingController = NSHostingController(rootView: SettingsView())
        
        // ✅ TAILLE FIXE pour éviter les problèmes de redimensionnement
        let windowSize = NSSize(width: 450, height: 750)
        let windowRect = NSRect(origin: .zero, size: windowSize)
        
        settingsWindow = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        // Configuration de la fenêtre
        settingsWindow?.title = "Préférences Manicrypt"
        settingsWindow?.contentViewController = settingsHostingController
        settingsWindow?.isReleasedWhenClosed = false // ✅ CRITIQUE: Éviter la libération automatique
        settingsWindow?.delegate = self
        
        // ✅ TAILLE FIXE pour éviter les problèmes d'affichage
        settingsWindow?.minSize = windowSize
        settingsWindow?.maxSize = windowSize
        
        // Centrer et afficher
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        print("✅ Préférences ouvertes avec succès - Taille: \(windowSize)")
    }
    
    // ✅ AJOUT: Méthode de nettoyage des fenêtres
    private func cleanupWindows() {
        if let window = settingsWindow {
            window.orderOut(nil)
            window.delegate = nil // ✅ Supprimer le delegate
        }
        // ✅ Libérer les références seulement à la fermeture de l'app
        settingsWindow = nil
        settingsHostingController = nil
    }
    
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Manicrypt"
        
        let manager = GlobalHotkeyManager.shared
        let securityStatus = manager.hasConfiguredPassphrase ? "🔐 Passphrase sécurisée" : "⚠️ Passphrase non configurée"
        let hotkeyStatus = manager.isEnabled ? "⚡ Raccourcis actifs" : "❌ Raccourcis inactifs"
        
        alert.informativeText = """
        Version 1.0
        
        Cryptage militaire AES-256-GCM
        pour macOS avec sécurité renforcée
        
        État actuel :
        \(securityStatus)
        \(hotkeyStatus)
        
        Raccourcis disponibles :
        ⌃⇧E - Chiffrer la sélection
        ⌃⇧D - Déchiffrer la sélection
        (dans un champ éditable : remplacement sur place ;
        sinon presse-papier + témoin pour ⌃⇧E, aperçu pour ⌃⇧D)
        
        Sécurité :
        • Stockage Keychain avec biométrie
        • Effacement sécurisé de la mémoire
        • Session avec timeout automatique
        
        © 2025 Manicrypt
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        
        if !manager.hasConfiguredPassphrase {
            alert.addButton(withTitle: "Configurer")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                openSettings()
            }
        } else {
            alert.runModal()
        }
    }
    
    @objc private func encryptSelection() {
        let manager = GlobalHotkeyManager.shared
        if manager.canEnable {
            manager.processSelectedText(encrypt: true)
        } else {
            showSetupRequiredAlert()
        }
    }
    
    @objc private func decryptSelection() {
        let manager = GlobalHotkeyManager.shared
        if manager.canEnable {
            manager.processSelectedText(encrypt: false)
        } else {
            showSetupRequiredAlert()
        }
    }
    
    private func showSetupRequiredAlert() {
        let alert = NSAlert()
        alert.messageText = "Configuration requise"
        alert.informativeText = """
        Pour utiliser les raccourcis, vous devez :
        1. Configurer une passphrase sécurisée
        2. Autoriser l'accès à l'accessibilité
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Ouvrir Préférences")
        alert.addButton(withTitle: "Plus tard")
        
        if alert.runModal() == .alertFirstButtonReturn {
            openSettings()
        }
    }
    
    private func testCryptoIntegration() {
        print("🧪 Test d'intégration crypto Manicrypt...")
        
        let testText = "Hello from Manicrypt!"
        let testPassword = "test123"
        
        // Test de chiffrement
        if let result = swift_encrypt_data(testText, testPassword) {
            defer { free_crypto_result(result) }
            let cryptoResult = result.pointee
            if cryptoResult.success == 1 {
                print("✅ Chiffrement Manicrypt OK - Taille: \(cryptoResult.length) bytes")
                
                // Encoder en base64
                if let base64 = swift_base64_encode(cryptoResult.data, Int32(cryptoResult.length)) {
                    defer { free(base64) } // ✅ UNE SEULE libération avec defer
                    let base64String = String(cString: base64)
                    print("📝 Base64: \(base64String.prefix(30))...")
                    
                    // Test de déchiffrement
                    if let decodeResult = swift_base64_decode(base64) {
                        defer { free_crypto_result(decodeResult) }
                        let decodedData = decodeResult.pointee
                        if decodedData.success == 1 {
                            if let decryptResult = swift_decrypt_data(
                                decodedData.data,
                                Int32(decodedData.length),
                                testPassword
                            ) {
                                defer { free_crypto_result(decryptResult) }
                                let decryptData = decryptResult.pointee
                                if decryptData.success == 1 {
                                    // Ne jamais logger le contenu déchiffré, même en self-test.
                                    print("🎉 Manicrypt crypto backend opérationnel (round-trip OK)")
                                } else {
                                    let errorMsg = String(cString: decryptData.error_message)
                                    print("❌ Erreur déchiffrement: \(errorMsg)")
                                }
                            }
                        }
                    }
                }
            } else {
                let errorMsg = String(cString: cryptoResult.error_message)
                print("❌ Erreur chiffrement: \(errorMsg)")
            }
        }
    }
}

// MARK: - NSWindowDelegate
extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            print("🔄 Fermeture de la fenêtre des préférences")
            // ✅ NE PAS nettoyer les références - les garder pour réutilisation
            // La fenêtre sera réutilisée lors de la prochaine ouverture
        }
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === settingsWindow {
            print("🔄 Préparation à la fermeture des préférences")
            // ✅ Cacher la fenêtre au lieu de la fermer
            sender.orderOut(nil)
            return false // Empêcher la fermeture réelle
        }
        return true
    }
}
//
//// MARK: - PassphraseManagerView pour le menu
//struct PassphraseManagerView: View {
//    @State private var hasStoredPassphrase: Bool = false
//    @State private var showDeleteConfirmation: Bool = false
//    @State private var showAlert: Bool = false
//    @State private var alertTitle: String = ""
//    @State private var alertMessage: String = ""
//    
//    var body: some View {
//        VStack(spacing: 20) {
//            // Header
//            VStack(spacing: 8) {
//                Image(systemName: "key.icloud.fill")
//                    .font(.system(size: 40))
//                    .foregroundColor(.blue)
//                
//                Text("Gérer les passphrases")
//                    .font(.title2)
//                    .fontWeight(.bold)
//            }
//            
//            Divider()
//            
//            // Status
//            VStack(spacing: 16) {
//                HStack {
//                    Image(systemName: hasStoredPassphrase ? "checkmark.circle.fill" : "xmark.circle")
//                        .foregroundColor(hasStoredPassphrase ? .green : .gray)
//                    
//                    Text(hasStoredPassphrase ? "Passphrase stockée dans le Keychain" : "Aucune passphrase stockée")
//                        .font(.headline)
//                    
//                    Spacer()
//                }
//                .padding()
//                .background(hasStoredPassphrase ? Color.green.opacity(0.1) : Color.gray.opacity(0.1))
//                .cornerRadius(8)
//                
//                if hasStoredPassphrase {
//                    VStack(alignment: .leading, spacing: 8) {
//                        Label("Protégée par Touch ID / Face ID", systemImage: "faceid")
//                        Label("Stockée localement sur cet appareil uniquement", systemImage: "lock.desktopcomputer")
//                        Label("Non synchronisée avec iCloud", systemImage: "icloud.slash")
//                    }
//                    .font(.caption)
//                    .foregroundColor(.secondary)
//                    .padding()
//                    .background(Color.blue.opacity(0.05))
//                    .cornerRadius(8)
//                }
//            }
//            
//            // Actions
//            if hasStoredPassphrase {
//                VStack(spacing: 12) {
//                    Button(action: deleteStoredPassphrase) {
//                        HStack {
//                            Image(systemName: "trash")
//                            Text("Supprimer la passphrase stockée")
//                        }
//                        .frame(maxWidth: .infinity)
//                    }
//                    .buttonStyle(.bordered)
//                    .foregroundColor(.red)
//                    
//                    Text("⚠️ Attention: Supprimer la passphrase rendra toutes les données chiffrées avec celle-ci définitivement inaccessibles")
//                        .font(.caption)
//                        .foregroundColor(.orange)
//                        .multilineTextAlignment(.center)
//                }
//            }
//            
//            Spacer()
//            
//            // Help section
//            VStack(alignment: .leading, spacing: 8) {
//                Text("À propos du stockage des passphrases")
//                    .font(.headline)
//                
//                Text("""
//                • Les passphrases sont chiffrées en utilisant la Secure Enclave de votre appareil
//                • L'authentification biométrique est requise pour y accéder
//                • Les données ne quittent jamais votre appareil
//                • Vous ne pouvez avoir qu'une seule passphrase stockée à la fois
//                """)
//                .font(.caption)
//                .foregroundColor(.secondary)
//            }
//            .padding()
//            .background(Color.gray.opacity(0.1))
//            .cornerRadius(8)
//        }
//        .padding()
//        .frame(width: 400, height: 500)
//        .onAppear {
//            checkStoredPassphrase()
//        }
//        .alert(alertTitle, isPresented: $showAlert) {
//            Button("OK") { }
//        } message: {
//            Text(alertMessage)
//        }
//        .confirmationDialog(
//            "Supprimer la passphrase stockée ?",
//            isPresented: $showDeleteConfirmation,
//            titleVisibility: .visible
//        ) {
//            Button("Supprimer", role: .destructive) {
//                performDelete()
//            }
//            Button("Annuler", role: .cancel) { }
//        } message: {
//            Text("Cette action ne peut pas être annulée. Toutes les données chiffrées avec cette passphrase deviendront définitivement inaccessibles.")
//        }
//    }
//    
//    private func checkStoredPassphrase() {
//        hasStoredPassphrase = PassphraseManager.shared.hasStoredPassphrase()
//    }
//    
//    private func deleteStoredPassphrase() {
//        showDeleteConfirmation = true
//    }
//    
//    private func performDelete() {
//        PassphraseManager.shared.deleteFromKeychain()
//        hasStoredPassphrase = false
//        
//        showAlert(
//            title: "Passphrase supprimée",
//            message: "La passphrase stockée a été définitivement supprimée de votre Keychain."
//        )
//    }
//    
//    private func showAlert(title: String, message: String) {
//        alertTitle = title
//        alertMessage = message
//        showAlert = true
//    }
//}
