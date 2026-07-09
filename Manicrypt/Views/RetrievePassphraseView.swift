//
//  RetrievePassphraseView.swift
//  Manicrypt
//
//  Created by Nicolazic Tardy on 08/07/2025.
//

import SwiftUI
import LocalAuthentication

// MARK: - Retrieve Passphrase View
struct RetrievePassphraseView: View {
    @State private var isRetrieving: Bool = false
    @State private var retrievedPassphrase: String = ""
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            if PassphraseManager.shared.hasStoredPassphrase() {
                VStack(spacing: 16) {
                    Image(systemName: "lock.icloud.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)
                    
                    Text("Stored Passphrase Found")
                        .font(.headline)
                    
                    Button(action: retrievePassphrase) {
                        if isRetrieving {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            HStack {
                                Image(systemName: "faceid")
                                Text("Retrieve with Touch ID / Face ID")
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRetrieving)
                    
                    if !retrievedPassphrase.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Retrieved Passphrase:")
                                .font(.headline)
                            
                            Text(retrievedPassphrase)
                                .font(.system(.body, design: .monospaced))
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(8)
                                .textSelection(.enabled)
                        }
                        
                        Button("Clear") {
                            withAnimation {
                                retrievedPassphrase = ""
                            }
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "lock.icloud")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    
                    Text("No Stored Passphrase")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text("Generate a new passphrase first")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }
    
    private func retrievePassphrase() {
        isRetrieving = true
        
        Task {
            do {
                let passphrase = try await PassphraseManager.shared.retrieveFromKeychain()
                
                await MainActor.run {
                    isRetrieving = false
                    withAnimation {
                        retrievedPassphrase = passphrase
                    }
                }
            } catch {
                await MainActor.run {
                    isRetrieving = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}
