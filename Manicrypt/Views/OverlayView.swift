//
//  OverlayView.swift
//  Manicrypt
//
//  Vues flottantes de FEAT-001 (v3) :
//   - overlay de déchiffrement (zone non éditable) : clair, bouton Copier,
//     champ « autre passphrase » one-shot, états d'erreur ;
//   - HUD éphémère « Chiffré copié ✓ » (⌃⇧E en zone non éditable).
//
//  Le texte affiché (clair) ne vit qu'en mémoire, le temps de l'affichage.
//  Aucune écriture disque, aucun log. La passphrase alternative saisie ici
//  n'est ni persistée ni loggée.
//

import SwiftUI

// MARK: - État affiché

enum OverlayState: Equatable {
    /// HUD éphémère : le chiffré vient d'être copié dans le presse-papier.
    case encryptedHUD
    /// Overlay : texte clair déchiffré (copie manuelle seulement).
    case decrypted(String)
    /// Sélection vide ou capture ⌘C échouée.
    case emptySelection
    /// Sélection non déchiffrable (base64 / GCM invalides ou mauvaise passphrase).
    case notManicryptMessage
    /// Aucune passphrase de session configurée.
    case passphraseNotConfigured
    /// Erreur inattendue (message sans contenu sensible).
    case failure(String)
}

// MARK: - View model

/// Pilote les vues. Créé et détenu par `OverlayPanelController`, qui câble les
/// callbacks (fermer, copier, préférences, retenter avec une autre passphrase).
final class OverlayViewModel: ObservableObject {
    @Published private(set) var state: OverlayState = .emptySelection
    @Published private(set) var didCopy: Bool = false

    /// Saisie one-shot d'une passphrase alternative (jamais persistée ni loggée).
    @Published var altPassphrase: String = ""
    /// Vrai si le dernier essai avec la passphrase alternative a échoué.
    @Published private(set) var altFailed: Bool = false

    var closeHandler: () -> Void = {}
    var copyHandler: () -> Void = {}
    var openPreferencesHandler: () -> Void = {}
    /// Transmet la passphrase alternative au controller, qui retente le
    /// déchiffrement et rappelle `showRetrySuccess` / `markAltFailed`.
    var altSubmitHandler: (String) -> Void = { _ in }

    func present(_ state: OverlayState, alreadyCopied: Bool) {
        self.state = state
        self.didCopy = alreadyCopied
        self.altPassphrase = ""
        self.altFailed = false
    }

    /// Remet à zéro — libère aussi le texte affiché et la saisie alternative.
    func reset() {
        state = .emptySelection
        didCopy = false
        altPassphrase = ""
        altFailed = false
    }

    func close() { closeHandler() }

    func copyPlaintext() {
        copyHandler()
        didCopy = true
    }

    func openPreferences() {
        openPreferencesHandler()
        closeHandler()
    }

    func submitAltPassphrase() {
        let pass = altPassphrase
        guard !pass.isEmpty else { return }
        altSubmitHandler(pass)
    }

    // Appelés par le controller après un essai avec la passphrase alternative.
    func showRetrySuccess(_ plaintext: String) {
        state = .decrypted(plaintext)
        didCopy = false
        altPassphrase = ""
        altFailed = false
    }

    func markAltFailed() {
        altFailed = true
    }
}

// MARK: - Overlay (déchiffrement + erreurs)

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @State private var altExpanded = false

    private let cardWidth: CGFloat = 360

    var body: some View {
        Group {
            if case .encryptedHUD = viewModel.state {
                hud
            } else {
                card
            }
        }
        .padding(8) // marge pour que l'ombre ne soit pas rognée par le panel
    }

    // MARK: HUD éphémère

    private var hud: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(.green)
            Text("Chiffré copié ✓").font(.headline)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
    }

    // MARK: Carte (overlay complet)

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(16)
        .frame(width: cardWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: accent.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent.color)
            Text(accent.title).font(.headline)
            Spacer()
            Button(action: viewModel.close) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Fermer (Échap)")
        }
    }

    @ViewBuilder private var content: some View {
        switch viewModel.state {
        case .decrypted(let plain):
            resultBlock(text: plain)
            HStack {
                Button(action: viewModel.copyPlaintext) {
                    Label(viewModel.didCopy ? "Copié ✓" : "Copier",
                          systemImage: viewModel.didCopy ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.didCopy ? .green : .accentColor)
                Spacer()
            }
            DisclosureGroup("Utiliser une autre passphrase", isExpanded: $altExpanded) {
                alternatePassphraseField
            }
            .font(.callout)

        case .notManicryptMessage:
            messageBlock(
                title: "Ce n'est pas un message Manicrypt",
                detail: "La sélection n'a pas pu être déchiffrée avec la passphrase de session. Essayez une autre passphrase :"
            )
            alternatePassphraseField

        case .passphraseNotConfigured:
            messageBlock(
                title: "Passphrase non configurée",
                detail: "Configurez une passphrase de session pour utiliser les raccourcis."
            )
            Button("Ouvrir les Préférences", action: viewModel.openPreferences)
                .buttonStyle(.bordered)

        case .emptySelection:
            messageBlock(
                title: "Aucun texte capturé",
                detail: "Sélectionnez du texte, puis relancez le raccourci (⌃⇧E pour chiffrer, ⌃⇧D pour déchiffrer)."
            )

        case .failure(let message):
            messageBlock(title: "Opération impossible", detail: message)

        case .encryptedHUD:
            EmptyView() // rendu par `hud`, jamais ici
        }
    }

    // MARK: Passphrase alternative

    private var alternatePassphraseField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField("Autre passphrase", text: $viewModel.altPassphrase)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(viewModel.submitAltPassphrase)
                Button("Déchiffrer", action: viewModel.submitAltPassphrase)
                    .buttonStyle(.bordered)
                    .disabled(viewModel.altPassphrase.isEmpty)
            }
            if viewModel.altFailed {
                Text("Échec — cette passphrase ne déchiffre pas non plus la sélection.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Saisie ponctuelle : jamais enregistrée ni journalisée.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: Fragments

    private func resultBlock(text: String) -> some View {
        ScrollView {
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 220)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func messageBlock(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Accent d'en-tête

    private struct Accent {
        let icon: String
        let title: String
        let color: Color
    }

    private var accent: Accent {
        switch viewModel.state {
        case .decrypted:
            return Accent(icon: "lock.open.fill", title: "Déchiffré", color: .blue)
        case .encryptedHUD, .emptySelection, .notManicryptMessage,
             .passphraseNotConfigured, .failure:
            return Accent(icon: "exclamationmark.triangle.fill", title: "Manicrypt", color: .orange)
        }
    }
}
