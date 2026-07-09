//
//  OverlayView.swift
//  Manicrypt
//
//  Vue de l'overlay flottant de chiffrement/déchiffrement (FEAT-001).
//  Affiche le résultat d'une opération ⌃⇧E / ⌃⇧D sans jamais modifier
//  la sélection source. Aucune écriture disque, aucun log du texte en clair.
//

import SwiftUI

// MARK: - État affiché par l'overlay

/// Contenu courant de l'overlay. Le texte (chiffré ou clair) vit uniquement
/// en mémoire, le temps de l'affichage — jamais persisté ni loggé.
enum OverlayState: Equatable {
    /// ⌃⇧E : chiffré, déjà copié dans le presse-papier.
    case encrypted(String)
    /// ⌃⇧D : clair, affiché seulement (copie manuelle via le bouton).
    case decrypted(String)
    /// Sélection vide ou capture ⌘C échouée.
    case emptySelection
    /// Sélection non déchiffrable (base64 ou GCM invalides).
    case notManicryptMessage
    /// Aucune passphrase configurée dans le Keychain.
    case passphraseNotConfigured
    /// Erreur inattendue (message déjà « safe », sans contenu sensible).
    case failure(String)
}

// MARK: - View model

/// Pilote l'overlay. Créé et détenu par `OverlayPanelController`.
/// Les callbacks (fermer, copier, préférences) sont câblés par le controller
/// pour garder toute logique presse-papier / navigation hors de la vue.
final class OverlayViewModel: ObservableObject {
    @Published private(set) var state: OverlayState = .emptySelection
    /// Témoin visuel « Copié ✓ » (vrai d'emblée en mode chiffré).
    @Published private(set) var didCopy: Bool = false

    var closeHandler: () -> Void = {}
    var copyHandler: () -> Void = {}
    var openPreferencesHandler: () -> Void = {}

    func present(_ state: OverlayState, alreadyCopied: Bool) {
        self.state = state
        self.didCopy = alreadyCopied
    }

    /// Remet l'overlay dans un état neutre — libère aussi le texte affiché.
    func reset() {
        state = .emptySelection
        didCopy = false
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
}

// MARK: - Vue

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel

    private let cardWidth: CGFloat = 360

    var body: some View {
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
        .padding(8) // marge pour que l'ombre ne soit pas rognée par le panel
    }

    // MARK: En-tête

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: accent.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent.color)
            Text(accent.title)
                .font(.headline)
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

    // MARK: Corps

    @ViewBuilder private var content: some View {
        switch viewModel.state {
        case .encrypted(let cipher):
            resultBlock(text: cipher, monospaced: true, tint: .green)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Copié ✓ — collez avec ⌘V où vous voulez.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .decrypted(let plain):
            resultBlock(text: plain, monospaced: false, tint: .blue)
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

        case .emptySelection:
            messageBlock(
                title: "Aucun texte capturé",
                detail: "Sélectionnez du texte, puis relancez le raccourci (⌃⇧E pour chiffrer, ⌃⇧D pour déchiffrer)."
            )

        case .notManicryptMessage:
            messageBlock(
                title: "Ce n'est pas un message Manicrypt",
                detail: "La sélection n'a pas pu être déchiffrée. Vérifiez que c'est bien un texte chiffré avec la même passphrase."
            )

        case .passphraseNotConfigured:
            messageBlock(
                title: "Passphrase non configurée",
                detail: "Configurez une passphrase de session pour utiliser les raccourcis."
            )
            Button("Ouvrir les Préférences", action: viewModel.openPreferences)
                .buttonStyle(.bordered)

        case .failure(let message):
            messageBlock(title: "Opération impossible", detail: message)
        }
    }

    // MARK: Fragments

    private func resultBlock(text: String, monospaced: Bool, tint: Color) -> some View {
        ScrollView {
            Text(text)
                .font(.system(.body, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 220)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    // MARK: Accent (icône / titre / couleur d'en-tête selon l'état)

    private struct Accent {
        let icon: String
        let title: String
        let color: Color
    }

    private var accent: Accent {
        switch viewModel.state {
        case .encrypted:
            return Accent(icon: "lock.fill", title: "Chiffré", color: .green)
        case .decrypted:
            return Accent(icon: "lock.open.fill", title: "Déchiffré", color: .blue)
        case .emptySelection, .notManicryptMessage, .passphraseNotConfigured, .failure:
            return Accent(icon: "exclamationmark.triangle.fill", title: "Manicrypt", color: .orange)
        }
    }
}
