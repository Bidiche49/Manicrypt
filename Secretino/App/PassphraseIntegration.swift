//
//  PassphraseIntegration.swift
//  Secretino
//
//  Integration helpers and menu bar additions for passphrase generator
//

import SwiftUI
import AppKit

// MARK: - Window Management Functions
struct PassphraseWindowManager {
    static func showPassphraseGenerator() {
        showWindow(content: PassphraseGeneratorView())
    }
    
    static func showPassphraseRetriever() {
        showWindow(content: RetrievePassphraseView(), size: NSSize(width: 350, height: 300))
    }
    
    static func showPassphraseManager() {
        showWindow(content: PassphraseManagerView())
    }
    
    private static func showWindow<Content: View>(content: Content, size: NSSize = NSSize(width: 400, height: 600)) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Secretino - Passphrase Generator"
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        
        // Keep window reference to prevent deallocation
        objc_setAssociatedObject(window, "keepAlive", window, .OBJC_ASSOCIATION_RETAIN)
    }
}

// MARK: - Passphrase Manager View
struct PassphraseManagerView: View {
    @State private var hasStoredPassphrase: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var showAlert: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "key.icloud.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)
                
                Text("Manage Passphrases")
                    .font(.title2)
                    .fontWeight(.bold)
            }
            
            Divider()
            
            // Status
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: hasStoredPassphrase ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(hasStoredPassphrase ? .green : .gray)
                    
                    Text(hasStoredPassphrase ? "Passphrase stored in Keychain" : "No stored passphrase")
                        .font(.headline)
                    
                    Spacer()
                }
                .padding()
                .background(hasStoredPassphrase ? Color.green.opacity(0.1) : Color.gray.opacity(0.1))
                .cornerRadius(8)
                
                if hasStoredPassphrase {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Protected by Touch ID / Face ID", systemImage: "faceid")
                        Label("Stored locally on this device only", systemImage: "lock.desktopcomputer")
                        Label("Not synced to iCloud", systemImage: "icloud.slash")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding()
                    .background(Color.blue.opacity(0.05))
                    .cornerRadius(8)
                }
            }
            
            // Actions
            if hasStoredPassphrase {
                VStack(spacing: 12) {
                    Button(action: deleteStoredPassphrase) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Delete Stored Passphrase")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                    
                    Text("⚠️ Warning: Deleting the passphrase will make any data encrypted with it permanently inaccessible")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            
            Spacer()
            
            // Help section
            VStack(alignment: .leading, spacing: 8) {
                Text("About Passphrase Storage")
                    .font(.headline)
                
                Text("""
                • Passphrases are encrypted using your device's Secure Enclave
                • Biometric authentication is required for access
                • Data never leaves your device
                • You can have only one stored passphrase at a time
                """)
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
        }
        .padding()
        .frame(width: 400, height: 500)
        .onAppear {
            checkStoredPassphrase()
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
        .confirmationDialog(
            "Delete Stored Passphrase?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                performDelete()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This action cannot be undone. Any data encrypted with this passphrase will become permanently inaccessible.")
        }
    }
    
    private func checkStoredPassphrase() {
        hasStoredPassphrase = PassphraseManager.shared.hasStoredPassphrase()
    }
    
    private func deleteStoredPassphrase() {
        showDeleteConfirmation = true
    }
    
    private func performDelete() {
        PassphraseManager.shared.deleteFromKeychain()
        hasStoredPassphrase = false
        
        showAlert(
            title: "Passphrase Deleted",
            message: "The stored passphrase has been permanently removed from your Keychain."
        )
    }
    
    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

// MARK: - Quick Access Button for Main View
struct PassphraseQuickAccessButton: View {
    @State private var showGenerator: Bool = false
    
    var body: some View {
        Button(action: { showGenerator = true }) {
            HStack {
                Image(systemName: "key.fill")
                Text("Generate Passphrase")
            }
        }
        .buttonStyle(.bordered)
        .sheet(isPresented: $showGenerator) {
            PassphraseGeneratorView()
        }
    }
}

// MARK: - Integration with SecretinoView
extension SecretinoView {
    /// Add this to the main SecretinoView to provide quick access to passphrase generator
    var passphraseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Need a strong passphrase?")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                PassphraseQuickAccessButton()
            }
        }
        .padding(.horizontal)
    }
}
