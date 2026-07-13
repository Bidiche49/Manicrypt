//
//  BubbleOverlayView.swift
//  Manicrypt
//
//  Overlay par-bulle du mode transparent (IMP-005).
//
//  Une instance par bulle MC1. visible : une carte qui remplit la fenêtre
//  d'overlay (elle-même positionnée sur la bulle chiffrée), affiche le clair
//  (scrollable si plus long que la bulle) + l'heure/statut, avec un bref morph
//  de glyphe chiffré → déchiffré pour un message fraîchement arrivé.
//
//  Limite AX (prouvée) : la largeur/forme exacte de la bulle n'est pas exposée
//  (seule la ligne pleine largeur l'est) → la largeur est une estimation
//  calibrée ; la hauteur, elle, vient de la ligne et est fidèle.
//
//  Le clair n'existe qu'en mémoire, le temps de l'affichage.
//

import SwiftUI

final class BubbleOverlayItemViewModel: ObservableObject {
    @Published var plaintext: String = ""
    @Published var meta: String = ""          // heure · statut (parsés du label)
    @Published var isOutgoing: Bool = true
    /// Incrémenté pour (re)jouer le morph d'arrivée (nouveau message uniquement).
    @Published var revealToken: Int = 0
    /// Faux pour un affichage direct (bulle déjà présente / re-snap au scroll).
    @Published var animateEntry: Bool = false
    /// Vrai seulement si le clair déborde de la bulle : le scroll interne est
    /// alors autorisé (sinon désactivé — la molette scrolle WhatsApp dessous).
    @Published var isScrollable: Bool = false
}

struct BubbleOverlayItemView: View {
    @ObservedObject var viewModel: BubbleOverlayItemViewModel

    @State private var textRevealed = true
    @State private var glyphSealed: Double = 0
    @State private var glyphOpacity: Double = 0

    private var accent: Color { viewModel.isOutgoing ? .green : .blue }

    var body: some View {
        VStack(alignment: viewModel.isOutgoing ? .trailing : .leading, spacing: 3) {
            ScrollView {
                Text(viewModel.plaintext)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity,
                           alignment: viewModel.isOutgoing ? .trailing : .leading)
            }
            // Ne scrolle (et ne capte la molette) que si le clair déborde.
            .scrollDisabled(!viewModel.isScrollable)
            .scrollBounceBehavior(.basedOnSize)
            if !viewModel.meta.isEmpty {
                Text(viewModel.meta)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity,
                           alignment: viewModel.isOutgoing ? .trailing : .leading)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(accent.opacity(0.30), lineWidth: 1)
        )
        .blur(radius: textRevealed ? 0 : 7)
        .overlay {
            CrochetsGlyph(sealed: glyphSealed, color: accent)
                .frame(width: 34, height: 34)
                .frame(width: 24, height: 24)
                .opacity(glyphOpacity)
                .allowsHitTesting(false)
        }
        .onChange(of: viewModel.revealToken) { _, _ in playEntry() }
        .onAppear { syncInitial() }
    }

    private func syncInitial() {
        if viewModel.animateEntry { playEntry() }
        else { textRevealed = true; glyphOpacity = 0; glyphSealed = 0 }
    }

    /// Morph chiffré → déchiffré visible, puis défloutage du texte.
    private func playEntry() {
        glyphSealed = 1
        glyphOpacity = 1
        textRevealed = false
        withAnimation(.easeInOut(duration: 0.4)) { glyphSealed = 0 }
        withAnimation(.easeOut(duration: 0.28).delay(0.42)) {
            textRevealed = true
            glyphOpacity = 0
        }
    }
}
