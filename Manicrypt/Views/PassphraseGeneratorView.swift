//
//  PassphraseGeneratorView.swift
//  Manicrypt
//
//  UI for secure passphrase generation with Keychain storage option
//  CORRIGÉ pour utiliser directement les fonctions C
//

import SwiftUI
import LocalAuthentication











struct PassphraseGeneratorView: View {
    @StateObject private var manager = PassphraseManager.shared
    @State private var wordCount: Int = 5
    @State private var capitalize: Bool = false
    @State private var includeDigit: Bool = false
    @State private var includeSymbol: Bool = false
    @State private var showAlert: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    @State private var debugInfo: String = "Pas de debug"
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)
                
                Text("Passphrase Generator (DEBUG)")
                    .font(.title2)
                    .fontWeight(.bold)
            }
            
            // ✅ SECTION DEBUG
            VStack(alignment: .leading, spacing: 8) {
                Text("🔍 Debug Info:")
                    .font(.headline)
                    .foregroundColor(.orange)
                
                Text(debugInfo)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(4)
                
                Button("Test Simple") {
                    testSimpleGeneration()
                }
                .buttonStyle(.bordered)
            }
            
            Divider()
            
            // Configuration normale...
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Passphrase Strength")
                        .font(.headline)
                    
                    Picker("Words", selection: $wordCount) {
                        Text("4 words (Basic)").tag(4)
                        Text("5 words (Good)").tag(5)
                        Text("7 words (Strong)").tag(7)
                    }
                    .pickerStyle(MenuPickerStyle())
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Additional Options")
                        .font(.headline)
                    
                    Toggle("Capitalize one word", isOn: $capitalize)
                    Toggle("Add random digit", isOn: $includeDigit)
                    Toggle("Add random symbol", isOn: $includeSymbol)
                }
            }
            .padding(.horizontal)
            
            // Generate button
            Button(action: generatePassphrase) {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text("Generate New Passphrase")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            // ✅ AFFICHAGE DEBUG DE LA PASSPHRASE
            if manager.isPassphraseGenerated {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Passphrase:")
                            .font(.headline)
                        
                        // ✅ MULTIPLE AFFICHAGES POUR DEBUG
                        Group {
                            Text("Raw: '\(manager.currentPassphrase)'")
                                .font(.caption)
                                .foregroundColor(.gray)
                            
                            Text("Count: \(manager.currentPassphrase.count) chars")
                                .font(.caption)
                                .foregroundColor(.gray)
                            
                            Text("Empty: \(manager.currentPassphrase.isEmpty)")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        
                        // Affichage principal
                        Text(manager.currentPassphrase)
                            .font(.system(.body, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                            .textSelection(.enabled)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                            )
                        
                        // Test d'affichage alternatif
                        TextField("Passphrase (editable)", text: .constant(manager.currentPassphrase))
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(.body, design: .monospaced))
                    }
                    
                    // Action buttons
                    HStack(spacing: 12) {
                        Button(action: copyPassphrase) {
                            HStack {
                                Image(systemName: "doc.on.doc")
                                Text("Copy")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: debugPassphrase) {
                            HStack {
                                Image(systemName: "ant.fill")
                                Text("Debug")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.orange)
                        
                        Button(action: dismissPassphrase) {
                            HStack {
                                Image(systemName: "xmark.circle")
                                Text("Dismiss")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    }
                }
                .transition(.asymmetric(
                    insertion: .scale.combined(with: .opacity),
                    removal: .opacity
                ))
            }
            
            Spacer()
        }
        .padding()
        .frame(width: 450, height: 700) // Plus haut pour le debug
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            updateDebugInfo()
        }
        .onChange(of: manager.currentPassphrase) { _ in
            updateDebugInfo()
        }
        .onChange(of: manager.isPassphraseGenerated) { _ in
            updateDebugInfo()
        }
    }
    
    // MARK: - Actions DEBUG
    
    private func updateDebugInfo() {
        debugInfo = """
        isPassphraseGenerated: \(manager.isPassphraseGenerated)
        currentPassphrase.count: \(manager.currentPassphrase.count)
        currentPassphrase.isEmpty: \(manager.currentPassphrase.isEmpty)
        sessionTimeRemaining: \(manager.sessionTimeRemaining)
        """
    }
    
    private func testSimpleGeneration() {
        if let testPassphrase = manager.testSimpleGeneration() {
            debugInfo = "Test réussi: '\(testPassphrase)'"
        } else {
            debugInfo = "Test échoué"
        }
    }
    
    private func debugPassphrase() {
        let passphrase = manager.currentPassphrase
        
        debugInfo = """
        === DEBUG PASSPHRASE ===
        Longueur: \(passphrase.count)
        Vide: \(passphrase.isEmpty)
        Premier char: \(passphrase.first.map(String.init) ?? "nil")
        Dernier char: \(passphrase.last.map(String.init) ?? "nil")
        UTF8 bytes: \(passphrase.utf8.count)
        Contient espaces: \(passphrase.contains(" "))
        Contient newlines: \(passphrase.contains("\n"))
        Raw: '\(passphrase)'
        """
        
        print("🔍 DEBUG COMPLETE:")
        print(debugInfo)
    }
    
    private func generatePassphrase() {
        withAnimation(.spring()) {
            let success = manager.generateNewPassphrase(
                wordCount: wordCount,
                capitalize: capitalize,
                includeDigit: includeDigit,
                includeSymbol: includeSymbol
            )
            
            if !success {
                showAlert(
                    title: "Generation Failed",
                    message: "Failed to generate secure passphrase. Check debug info."
                )
            }
            
            updateDebugInfo()
        }
    }
    
    private func copyPassphrase() {
        print("🔍 COPY: Tentative de copie...")
        print("   - Passphrase: '\(manager.currentPassphrase)'")
        manager.copyToClipboard()
        
        showAlert(
            title: "Copy Attempt",
            message: "Check console for copy debug info. Passphrase length: \(manager.currentPassphrase.count)"
        )
    }
    
    private func dismissPassphrase() {
        withAnimation(.easeOut(duration: 0.2)) {
            manager.clearCurrentPassphrase()
        }
        updateDebugInfo()
    }
    
    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}










//struct PassphraseGeneratorView: View {
//    @StateObject private var manager = PassphraseManager.shared
//    @State private var wordCount: Int = 5
//    @State private var capitalize: Bool = false
//    @State private var includeDigit: Bool = false
//    @State private var includeSymbol: Bool = false
//    @State private var showStorageDialog: Bool = false
//    @State private var showAlert: Bool = false
//    @State private var alertTitle: String = ""
//    @State private var alertMessage: String = ""
//    @State private var isStoringInKeychain: Bool = false
//    @State private var showCopiedFeedback: Bool = false
//    
//    // Timer formatting
//    private var timerDisplay: String {
//        let minutes = manager.sessionTimeRemaining / 60
//        let seconds = manager.sessionTimeRemaining % 60
//        return String(format: "%d:%02d", minutes, seconds)
//    }
//    
//    // Entropy calculation using C functions
//    private var entropyBits: Double {
//        manager.calculateEntropy(
//            wordCount: wordCount,
//            capitalize: capitalize,
//            includeDigit: includeDigit,
//            includeSymbol: includeSymbol
//        )
//    }
//    
//    private var securityRating: (rating: String, color: Color) {
//        let rating = manager.getSecurityRating(entropy: entropyBits)
//        let color: Color = {
//            switch rating.color {
//            case "red": return .red
//            case "orange": return .orange
//            case "yellow": return .yellow
//            case "green": return .green
//            case "blue": return .blue
//            default: return .gray
//            }
//        }()
//        return (rating.rating, color)
//    }
//    
//    var body: some View {
//        VStack(spacing: 20) {
//            // Header
//            VStack(spacing: 8) {
//                Image(systemName: "key.fill")
//                    .font(.system(size: 40))
//                    .foregroundColor(.blue)
//                
//                Text("Passphrase Generator")
//                    .font(.title2)
//                    .fontWeight(.bold)
//                
//                Text("Generate secure passphrases for encryption")
//                    .font(.caption)
//                    .foregroundColor(.secondary)
//            }
//            
//            Divider()
//            
//            // Configuration Section
//            VStack(alignment: .leading, spacing: 16) {
//                // Word count selector
//                VStack(alignment: .leading, spacing: 8) {
//                    Text("Passphrase Strength")
//                        .font(.headline)
//                    
//                    Picker("Words", selection: $wordCount) {
//                        Text("4 words (Basic)").tag(4)
//                        Text("5 words (Good)").tag(5)
//                        Text("7 words (Strong)").tag(7)
//                        Text("10 words (Very Strong)").tag(10)
//                        Text("15 words (Maximum)").tag(15)
//                    }
//                    .pickerStyle(MenuPickerStyle())
//                    
//                    // Security indicator
//                    HStack {
//                        Text("Entropy: ~\(Int(entropyBits)) bits")
//                            .font(.caption)
//                            .foregroundColor(.secondary)
//                        
//                        Spacer()
//                        
//                        HStack(spacing: 4) {
//                            Image(systemName: "shield.fill")
//                                .font(.caption)
//                            Text(securityRating.rating)
//                                .font(.caption)
//                                .fontWeight(.medium)
//                        }
//                        .foregroundColor(securityRating.color)
//                    }
//                }
//                
//                // Options
//                VStack(alignment: .leading, spacing: 12) {
//                    Text("Additional Options")
//                        .font(.headline)
//                    
//                    Toggle("Capitalize one word", isOn: $capitalize)
//                    Toggle("Add random digit", isOn: $includeDigit)
//                    Toggle("Add random symbol", isOn: $includeSymbol)
//                }
//            }
//            .padding(.horizontal)
//            
//            // Generate button
//            Button(action: generatePassphrase) {
//                HStack {
//                    Image(systemName: "wand.and.stars")
//                    Text("Generate New Passphrase")
//                }
//                .frame(maxWidth: .infinity)
//            }
//            .buttonStyle(.borderedProminent)
//            .controlSize(.large)
//            
//            // Generated passphrase display
//            if manager.isPassphraseGenerated {
//                VStack(spacing: 12) {
//                    // Timer
//                    HStack {
//                        Image(systemName: "timer")
//                            .font(.caption)
//                        Text("Auto-clear in \(timerDisplay)")
//                            .font(.caption)
//                            .monospacedDigit()
//                        Spacer()
//                    }
//                    .foregroundColor(.orange)
//                    
//                    // Passphrase display
//                    VStack(alignment: .leading, spacing: 8) {
//                        Text("Your Passphrase:")
//                            .font(.headline)
//                        
//                        Text(manager.currentPassphrase)
//                            .font(.system(.body, design: .monospaced))
//                            .padding()
//                            .frame(maxWidth: .infinity, alignment: .leading)
//                            .background(Color.blue.opacity(0.1))
//                            .cornerRadius(8)
//                            .textSelection(.enabled)
//                            .overlay(
//                                RoundedRectangle(cornerRadius: 8)
//                                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
//                            )
//                    }
//                    
//                    // Action buttons
//                    HStack(spacing: 12) {
//                        Button(action: copyPassphrase) {
//                            HStack {
//                                Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
//                                Text(showCopiedFeedback ? "Copied!" : "Copy Once")
//                            }
//                            .frame(maxWidth: .infinity)
//                        }
//                        .buttonStyle(.bordered)
//                        .disabled(showCopiedFeedback)
//                        
//                        Button(action: { showStorageDialog = true }) {
//                            HStack {
//                                Image(systemName: "lock.icloud")
//                                Text("Store in Keychain")
//                            }
//                            .frame(maxWidth: .infinity)
//                        }
//                        .buttonStyle(.borderedProminent)
//                        .disabled(isStoringInKeychain)
//                        
//                        Button(action: dismissPassphrase) {
//                            HStack {
//                                Image(systemName: "xmark.circle")
//                                Text("Dismiss")
//                            }
//                            .frame(maxWidth: .infinity)
//                        }
//                        .buttonStyle(.bordered)
//                        .foregroundColor(.red)
//                    }
//                }
//                .transition(.asymmetric(
//                    insertion: .scale.combined(with: .opacity),
//                    removal: .opacity
//                ))
//            }
//            
//            // Warning message
//            VStack(spacing: 8) {
//                Label("Important Security Notice", systemImage: "exclamationmark.triangle.fill")
//                    .font(.headline)
//                    .foregroundColor(.orange)
//                
//                Text("This passphrase is the ONLY way to decrypt your data. If you lose it and haven't stored it securely, your encrypted data will be permanently inaccessible.")
//                    .font(.caption)
//                    .foregroundColor(.secondary)
//                    .multilineTextAlignment(.center)
//            }
//            .padding()
//            .background(Color.orange.opacity(0.1))
//            .cornerRadius(8)
//            
//            Spacer()
//        }
//        .padding()
//        .frame(width: 400, height: 600)
//        .alert(alertTitle, isPresented: $showAlert) {
//            Button("OK") { }
//        } message: {
//            Text(alertMessage)
//        }
//        .confirmationDialog(
//            "Store Passphrase in Keychain?",
//            isPresented: $showStorageDialog,
//            titleVisibility: .visible
//        ) {
//            Button("Store with Touch ID / Face ID") {
//                Task {
//                    await storeInKeychain()
//                }
//            }
//            Button("Cancel", role: .cancel) { }
//        } message: {
//            Text("""
//            Your passphrase will be encrypted and stored in the macOS Keychain.
//            
//            • Protected by Touch ID / Face ID
//            • Only accessible on this device
//            • Never synced to iCloud
//            • Can be deleted anytime
//            
//            You'll need to authenticate with biometrics to access it.
//            """)
//        }
//    }
//    
//    // MARK: - Actions
//    
//    private func generatePassphrase() {
//        withAnimation(.spring()) {
//            let success = manager.generateNewPassphrase(
//                wordCount: wordCount,
//                capitalize: capitalize,
//                includeDigit: includeDigit,
//                includeSymbol: includeSymbol
//            )
//            
//            if !success {
//                showAlert(
//                    title: "Generation Failed",
//                    message: "Failed to generate secure passphrase. Please try again."
//                )
//            }
//        }
//    }
//    
//    private func copyPassphrase() {
//        manager.copyToClipboard()
//        
//        withAnimation {
//            showCopiedFeedback = true
//        }
//        
//        // Reset feedback after 2 seconds
//        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
//            withAnimation {
//                showCopiedFeedback = false
//            }
//        }
//        
//        // Show additional notice
//        showAlert(
//            title: "Copied to Clipboard",
//            message: "The passphrase has been copied and will be automatically cleared from the clipboard in 30 seconds for security."
//        )
//    }
//    
//    private func storeInKeychain() async {
//        isStoringInKeychain = true
//        
//        do {
//            try await manager.storeInKeychain()
//            
//            await MainActor.run {
//                isStoringInKeychain = false
//                showAlert(
//                    title: "Success",
//                    message: "Passphrase stored securely in Keychain with biometric protection. You can now dismiss this passphrase safely."
//                )
//                
//                // Auto-dismiss after successful storage
//                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
//                    dismissPassphrase()
//                }
//            }
//        } catch {
//            await MainActor.run {
//                isStoringInKeychain = false
//                showAlert(
//                    title: "Storage Failed",
//                    message: error.localizedDescription
//                )
//            }
//        }
//    }
//    
//    private func dismissPassphrase() {
//        withAnimation(.easeOut(duration: 0.2)) {
//            manager.clearCurrentPassphrase()
//        }
//    }
//    
//    private func showAlert(title: String, message: String) {
//        alertTitle = title
//        alertMessage = message
//        showAlert = true
//    }
//}

#Preview {
    PassphraseGeneratorView()
}
