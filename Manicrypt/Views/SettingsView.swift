//
//  SettingsView.swift
//  Manicrypt
//
//  Vue de configuration sécurisée pour les raccourcis globaux - CORRIGÉE
//

import SwiftUI
import LocalAuthentication

struct SettingsView: View {
    @StateObject private var hotkeyManager = GlobalHotkeyManager.shared
    @State private var globalPassphrase: String = ""
    @State private var confirmPassphrase: String = ""
    @State private var showAlert: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    @State private var permissionStatus: Bool = false
    @State private var biometryAvailable: Bool = false
    @State private var isConfiguring: Bool = false
    
    var body: some View {
        // ✅ CORRECTION: Conteneur avec taille fixe
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "keyboard.badge.ellipsis")
                            .font(.system(size: 40))
                            .foregroundColor(.blue)
                        
                        Text("Raccourcis Globaux")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("Chiffrez/déchiffrez dans n'importe quelle app")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)
                    
                    Divider()
                    
                    // État des prérequis
                    VStack(spacing: 12) {
                        Text("Prérequis")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        // Biométrie
                        HStack {
                            Image(systemName: biometryAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(biometryAvailable ? .green : .red)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Touch ID / Face ID")
                                    .font(.subheadline)
                                Text(biometryAvailable ? "Disponible" : "Non disponible - requis pour la sécurité")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                        }
                        .padding(12)
                        .background(biometryAvailable ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                        .cornerRadius(8)
                        
                        // Permissions d'accessibilité
                        HStack {
                            Image(systemName: permissionStatus ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(permissionStatus ? .green : .orange)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Accessibilité")
                                    .font(.subheadline)
                                Text(permissionStatus ? "Autorisé" : "Autorisation requise pour les raccourcis")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if !permissionStatus {
                                Button("Autoriser") {
                                    PermissionsHelper.shared.triggerAccessibilityRequest()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(12)
                        .background(permissionStatus ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }
                    
                    Divider()
                    
                    // Configuration de la passphrase
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Passphrase Sécurisée")
                            .font(.headline)
                        
                        if hotkeyManager.hasConfiguredPassphrase {
                            VStack(spacing: 12) {
                                HStack {
                                    Image(systemName: "lock.shield.fill")
                                        .foregroundColor(.green)
                                    Text("Passphrase configurée et sécurisée")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(12)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(8)
                                
                                HStack(spacing: 12) {
                                    Button("Modifier") {
                                        modifyPassphrase()
                                    }
                                    .buttonStyle(.bordered)
                                    
                                    Button("Supprimer") {
                                        deletePassphrase()
                                    }
                                    .buttonStyle(.bordered)
                                    .foregroundColor(.red)
                                }
                            }
                        } else {
                            VStack(spacing: 12) {
                                if !biometryAvailable {
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                        Text("Touch ID/Face ID requis pour sécuriser la passphrase")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                    .padding(12)
                                    .background(Color.orange.opacity(0.1))
                                    .cornerRadius(8)
                                }
                                
                                VStack(spacing: 8) {
                                    SecureField("Nouvelle passphrase (min 8 caractères)", text: $globalPassphrase)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .disabled(!biometryAvailable)
                                    
                                    SecureField("Confirmer passphrase", text: $confirmPassphrase)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .disabled(!biometryAvailable)
                                    
                                    Button(action: configurePassphrase) {
                                        if isConfiguring {
                                            HStack {
                                                ProgressView()
                                                    .scaleEffect(0.8)
                                                Text("Configuration...")
                                            }
                                        } else {
                                            Text("Configurer passphrase sécurisée")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!biometryAvailable || globalPassphrase.isEmpty || confirmPassphrase.isEmpty || isConfiguring)
                                }
                                
                                Text("⚠️ La passphrase sera chiffrée et stockée dans le Keychain avec protection biométrique")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Activation des raccourcis
                    VStack(alignment: .leading, spacing: 12) {
                        if hotkeyManager.canEnable {
                            VStack(spacing: 8) {
                                if hotkeyManager.isEnabled {
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                        Text("Raccourcis actifs")
                                            .foregroundColor(.green)
                                        Spacer()
                                        Button("Désactiver") {
                                            hotkeyManager.disableHotkeys()
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    .padding(12)
                                    .background(Color.green.opacity(0.1))
                                    .cornerRadius(8)
                                    
                                    VStack(alignment: .leading, spacing: 8) {
                                        Label("⌃⇧E : Chiffrer la sélection", systemImage: "lock.fill")
                                            .font(.system(.body, design: .monospaced))
                                        Label("⌃⇧D : Déchiffrer la sélection", systemImage: "lock.open.fill")
                                            .font(.system(.body, design: .monospaced))
                                    }
                                    .padding(12)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(8)
                                } else {
                                    Button("Activer les raccourcis") {
                                        hotkeyManager.requestPermissionsAndSetup()
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                        } else {
                            Text("Configurez d'abord la passphrase et autorisez l'accessibilité")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(12)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(8)
                        }
                    }
                    
                    Divider()
                    
                    // Instructions d'utilisation
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mode d'emploi")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("1. Sélectionnez du texte dans n'importe quelle application")
                            Text("2. Appuyez sur ⌃⇧E pour chiffrer ou ⌃⇧D pour déchiffrer")
                            Text("3. Authentifiez-vous avec Touch ID/Face ID au premier usage")
                            Text("4. Le texte est automatiquement remplacé")
                            Text("5. Session active pendant 10 minutes puis ré-authentification")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(12)
                        .background(Color.blue.opacity(0.05))
                        .cornerRadius(8)
                    }
                    
                    // Zone de danger
                    if hotkeyManager.hasConfiguredPassphrase {
                        Divider()
                        
                        VStack(spacing: 8) {
                            Text("Zone de danger")
                                .font(.headline)
                                .foregroundColor(.red)
                            
                            Button("Réinitialiser complètement Manicrypt") {
                                resetApplication()
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                            
                            Text("Supprime toutes les données, passphrases et préférences")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                    }
                    
                    // Espace en bas
                    Spacer(minLength: 20)
                }
                .padding(20)
            }
        }
        // ✅ CORRECTION: Taille fixe pour éviter les problèmes de redimensionnement
        .frame(width: 450, height: permissionStatus ? 840 : 750)
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            checkSystemCapabilities()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Rafraîchir les permissions quand l'app redevient active
            permissionStatus = PermissionsHelper.shared.hasAccessibilityPermission()
        }
    }
    
    // MARK: - Actions
    
    private func checkSystemCapabilities() {
        permissionStatus = PermissionsHelper.shared.hasAccessibilityPermission()
        biometryAvailable = SecureKeychainManager.shared.isBiometryAvailable()
    }
    
    private func configurePassphrase() {
        guard biometryAvailable else {
            showAlert(title: "Biométrie requise", message: "Touch ID ou Face ID est requis pour sécuriser votre passphrase")
            return
        }
        
        guard !globalPassphrase.isEmpty && !confirmPassphrase.isEmpty else {
            showAlert(title: "Champs requis", message: "Veuillez remplir tous les champs")
            return
        }
        
        guard globalPassphrase == confirmPassphrase else {
            showAlert(title: "Erreur", message: "Les passphrases ne correspondent pas")
            return
        }
        
        guard globalPassphrase.count >= 8 else {
            showAlert(title: "Passphrase trop courte", message: "La passphrase doit contenir au moins 8 caractères")
            return
        }
        
        isConfiguring = true
        
        Task {
            do {
                try SecureKeychainManager.shared.storeGlobalPassphrase(globalPassphrase)
                
                await MainActor.run {
                    // Nettoyer les champs
                    globalPassphrase = ""
                    confirmPassphrase = ""
                    isConfiguring = false
                    
                    // Mettre à jour l'état
                    hotkeyManager.hasConfiguredPassphrase = true
                    
                    showAlert(title: "Succès", message: "Passphrase configurée avec succès et stockée de manière sécurisée")
                }
            } catch {
                await MainActor.run {
                    isConfiguring = false
                    let errorMessage = SecureKeychainManager.shared.handleKeychainError(error)
                    showAlert(title: "Erreur", message: "Impossible de configurer la passphrase: \(errorMessage)")
                }
            }
        }
    }
    
    private func modifyPassphrase() {
        hotkeyManager.hasConfiguredPassphrase = false
        hotkeyManager.disableHotkeys()
        
        do {
            try SecureKeychainManager.shared.deleteGlobalPassphrase()
            showAlert(title: "Passphrase supprimée", message: "Vous pouvez maintenant configurer une nouvelle passphrase")
        } catch {
            let errorMessage = SecureKeychainManager.shared.handleKeychainError(error)
            showAlert(title: "Erreur", message: errorMessage)
        }
    }
    
    private func deletePassphrase() {
        let alert = NSAlert()
        alert.messageText = "Supprimer la passphrase ?"
        alert.informativeText = "Cette action supprimera définitivement votre passphrase sécurisée et désactivera les raccourcis globaux."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Supprimer")
        alert.addButton(withTitle: "Annuler")
        
        if alert.runModal() == .alertFirstButtonReturn {
            hotkeyManager.disableHotkeys()
            
            do {
                try SecureKeychainManager.shared.deleteGlobalPassphrase()
                hotkeyManager.hasConfiguredPassphrase = false
                showAlert(title: "Succès", message: "Passphrase supprimée avec succès")
            } catch {
                let errorMessage = SecureKeychainManager.shared.handleKeychainError(error)
                showAlert(title: "Erreur", message: errorMessage)
            }
        }
    }
    
    private func resetApplication() {
        let alert = NSAlert()
        alert.messageText = "Réinitialiser Manicrypt ?"
        alert.informativeText = "Cette action supprimera TOUTES les données de Manicrypt : passphrases, préférences, et raccourcis. Cette action est irréversible."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Réinitialiser")
        alert.addButton(withTitle: "Annuler")
        
        if alert.runModal() == .alertFirstButtonReturn {
            hotkeyManager.disableHotkeys()
            SecureKeychainManager.shared.cleanupAllSecureData()
            hotkeyManager.hasConfiguredPassphrase = false
            
            showAlert(title: "Réinitialisation complète", message: "Manicrypt a été complètement réinitialisé. Relancez l'application.")
            
            // Quitter l'application après 2 secondes
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
    
    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

#Preview {
    SettingsView()
        .frame(width: 450, height: 750)
}
