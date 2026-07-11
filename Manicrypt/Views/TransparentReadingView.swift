//
//  TransparentReadingView.swift
//  Manicrypt
//
//  Panneau de lecture du mode transparent (FEAT-002, brique 4) : affiche le
//  fil DÉCHIFFRÉ des bulles MC1. visibles dans la conversation liée, ancré au
//  bord de la fenêtre WhatsApp.
//
//  Le clair n'existe qu'en mémoire, le temps de l'affichage. Aucune écriture
//  disque, aucun log du contenu. La copie ne se fait que sur clic explicite.
//
//  Animations (retour utilisateur 2026-07-11) :
//  - ouverture/fermeture : le panneau émerge du glyphe de marque (coin haut-
//    gauche) pendant que le glyphe passe chiffré → déchiffré ; inverse à la
//    fermeture ;
//  - nouveau message : la bulle concernée joue un bref morph glyphe
//    chiffré → déchiffré + défloutage, puis affiche le clair. Uniquement pour un
//    VRAI nouveau message (envoyé ou reçu), jamais au (re)déchiffrement d'un
//    message déjà présent ni au scroll.
//

import SwiftUI

// MARK: - Modèle d'une ligne du fil

struct DecryptedBubble: Identifiable, Equatable {
    /// Identité stable par contenu (direction + clair + rang d'occurrence), pour
    /// que SwiftUI distingue une VRAIE insertion (nouveau message) d'un simple
    /// rafraîchissement au contenu identique.
    let id: String
    let isOutgoing: Bool
    let plaintext: String
}

// MARK: - View model

final class TransparentReadingViewModel: ObservableObject {
    @Published var conversationTitle: String = ""
    @Published var bubbles: [DecryptedBubble] = []
    /// Bulles MC1. visibles non déchiffrables avec la passphrase de liaison
    /// (mauvaise clé / corrompues) — signalées sans exposer de contenu.
    @Published var undecryptableCount: Int = 0
    /// Incrémenté quand un nouveau message apparaît en bas du fil : la vue
    /// re-colle le scroll en bas (les rafraîchissements sans nouveau message ne
    /// le touchent pas, préservant un défilement manuel).
    @Published var scrollToBottomToken: Int = 0
    /// Id de la bulle fraîchement arrivée (vrai nouveau message) à animer, ou
    /// `nil`. Positionné par le contrôleur, jamais au scroll / re-déchiffrement.
    @Published var freshBubbleID: String?
    /// Pilote l'animation d'ouverture/fermeture du panneau (émergence du glyphe).
    @Published var isRevealed: Bool = false
    /// État du glyphe d'en-tête (1 = chiffré, 0 = déchiffré). Animé SÉPARÉMENT de
    /// l'ouverture par le contrôleur, une fois le panneau visible, pour que le
    /// morph soit perceptible (sinon il se joue pendant que le panneau est encore
    /// transparent et en train de grandir).
    @Published var headerSealed: Double = 1

    var copyHandler: (String) -> Void = { _ in }
    var closeHandler: () -> Void = {}
}

// MARK: - Vue

struct TransparentReadingView: View {
    @ObservedObject var viewModel: TransparentReadingViewModel

    private let panelWidth: CGFloat = 320
    private let bottomAnchorID = "manicrypt.reading.bottom"

    private var maxFeedHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.5
    }

    var body: some View {
        card
            // Émergence depuis le coin haut-gauche (le glyphe), synchronisée avec
            // le morph du glyphe d'en-tête (chiffré ↔ déchiffré).
            .scaleEffect(viewModel.isRevealed ? 1 : 0.16, anchor: .topLeading)
            .opacity(viewModel.isRevealed ? 1 : 0)
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: viewModel.isRevealed)
            .padding(8)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: panelWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Glyphe de marque : morph chiffré → déchiffré piloté par le
            // contrôleur APRÈS l'ouverture (headerSealed), pour être visible.
            CrochetsGlyph(sealed: viewModel.headerSealed, color: .green)
                .frame(width: 26, height: 26)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Lecture protégée").font(.subheadline).fontWeight(.semibold)
                if !viewModel.conversationTitle.isEmpty {
                    Text(viewModel.conversationTitle)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button(action: viewModel.closeHandler) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Masquer le panneau")
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        if viewModel.bubbles.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.bubbles) { bubble in
                            BubbleRow(bubble: bubble,
                                      isFresh: bubble.id == viewModel.freshBubbleID,
                                      onCopy: viewModel.copyHandler)
                        }
                        if viewModel.undecryptableCount > 0 {
                            Text("\(viewModel.undecryptableCount) message(s) chiffré(s) non lisible(s) avec cette passphrase.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                        Color.clear.frame(height: 1).id(bottomAnchorID)
                    }
                    .padding(12)
                }
                .frame(maxHeight: maxFeedHeight)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: viewModel.scrollToBottomToken) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
                .onAppear { proxy.scrollTo(bottomAnchorID, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary).font(.system(size: 15))
            Text("Aucun message Manicrypt visible dans cette conversation. Faites défiler jusqu'à un message chiffré.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

// MARK: - Ligne de bulle (avec révélation animée d'un nouveau message)

private struct BubbleRow: View {
    let bubble: DecryptedBubble
    /// Vrai uniquement pour un message fraîchement arrivé (envoi/réception) :
    /// joue une fois le morph glyphe + défloutage. Faux au premier remplissage,
    /// au scroll et au re-déchiffrement → affichage direct, sans animation.
    let isFresh: Bool
    let onCopy: (String) -> Void

    @State private var textRevealed = false
    @State private var glyphSealed: Double = 1
    @State private var glyphOpacity: Double = 0

    private var accent: Color { bubble.isOutgoing ? .green : .blue }

    var body: some View {
        HStack {
            if bubble.isOutgoing { Spacer(minLength: 24) }
            Text(bubble.plaintext)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity,
                       alignment: bubble.isOutgoing ? .trailing : .leading)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(
                    accent.opacity(bubble.isOutgoing ? 0.16 : 0.10),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .blur(radius: textRevealed ? 0 : 7)
                .overlay {
                    // Glyphe toujours présent pendant l'animation : son opacité
                    // (et non sa présence) est animée, pour qu'il morphe VISIBLEMENT
                    // du chiffré au déchiffré avant de s'effacer.
                    CrochetsGlyph(sealed: glyphSealed, color: accent)
                        .frame(width: 30, height: 30)
                        .frame(width: 22, height: 22)
                        .opacity(glyphOpacity)
                        .allowsHitTesting(false)
                }
                .onTapGesture { onCopy(bubble.plaintext) }
                .help("Cliquer pour copier")
            if !bubble.isOutgoing { Spacer(minLength: 24) }
        }
        .onAppear { playIfFresh() }
    }

    /// Séquence, pour un vrai nouveau message : glyphe chiffré affiché → morph
    /// visible chiffré → déchiffré → défloutage du texte + fondu du glyphe.
    /// Sinon (premier remplissage, scroll, re-déchiffrement) : affichage direct.
    private func playIfFresh() {
        guard isFresh else {
            glyphSealed = 0
            glyphOpacity = 0
            textRevealed = true
            return
        }
        // État initial : glyphe chiffré bien visible sur le texte flouté.
        glyphSealed = 1
        glyphOpacity = 1
        textRevealed = false
        // 1) Morph chiffré → déchiffré, assez lent pour être perçu.
        withAnimation(.easeInOut(duration: 0.42)) { glyphSealed = 0 }
        // 2) Une fois le morph terminé, révéler le texte et estomper le glyphe.
        withAnimation(.easeOut(duration: 0.3).delay(0.44)) {
            textRevealed = true
            glyphOpacity = 0
        }
    }
}
