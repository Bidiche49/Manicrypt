//
//  TransparentReadingPanelController.swift
//  Manicrypt
//
//  Panneau flottant de lecture du mode transparent (FEAT-002, brique 4).
//
//  Réutilise le PATTERN de panneau non-activant de FEAT-001
//  (OverlayPanelController) — .nonactivatingPanel, .floating,
//  becomesKeyOnlyIfNeeded — mais avec une logique propre : le panneau VIT tant
//  que la conversation liée est active (il ne se ferme pas au clic extérieur,
//  contrairement à l'overlay ponctuel), il est ancré au bord de la fenêtre
//  WhatsApp, et son contenu (fil déchiffré) est rafraîchi.
//
//  Rafraîchissement : immédiat sur changement d'état d'activité + polling léger
//  (lecture AX locale, négligeable) tant que le panneau est visible, ce qui
//  couvre le scroll et l'arrivée de nouveaux messages sans dépendre d'events AX
//  de scroll (non garantis). Le panneau se retire dès que l'état n'est plus
//  actif (conv non liée, WhatsApp en arrière-plan/quitté, déliaison).
//
//  Le clair déchiffré ne vit qu'en mémoire, le temps de l'affichage.
//

import Cocoa
import SwiftUI

final class TransparentReadingPanelController {
    static let shared = TransparentReadingPanelController()

    private var panel: NSPanel?
    private let viewModel = TransparentReadingViewModel()
    private var refreshTimer: Timer?

    /// Signature de la dernière bulle affichée (direction + clair), pour détecter
    /// l'arrivée d'un NOUVEAU message en bas du fil et re-coller le scroll.
    /// Réinitialisée quand le panneau se masque.
    private var lastBottomSignature: String?

    /// Cadence de rafraîchissement pendant que le panneau est visible.
    private let refreshInterval: TimeInterval = 1.0

    private init() {
        viewModel.copyHandler = { [weak self] text in self?.copyPlaintext(text) }
        viewModel.closeHandler = { [weak self] in self?.userDidDismiss() }
    }

    /// Masquage manuel de la session courante : le panneau ne se ré-affichera
    /// pas tant que l'état ne rebascule pas actif (nouvelle activation de conv).
    private var dismissedForCurrentActivation = false

    // MARK: - Démarrage

    func start() {
        assert(Thread.isMainThread)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activityStateDidChange),
            name: ConversationActivityMonitor.stateDidChangeNotification,
            object: nil
        )
        syncWithActivityState()
        print("📖 [Transparent] Panneau de lecture prêt")
    }

    // MARK: - Synchronisation avec l'état d'activité

    @objc private func activityStateDidChange() {
        DispatchQueue.main.async { [weak self] in self?.syncWithActivityState() }
    }

    private func syncWithActivityState() {
        if ConversationActivityMonitor.shared.state.isActive {
            // Réarmer l'affichage sauf si masqué manuellement. On teste `isRevealed`
            // (et non la visibilité fenêtre) pour ré-ouvrir même pendant l'animation
            // de fermeture différée.
            if !viewModel.isRevealed && !dismissedForCurrentActivation {
                showPanel()
            }
        } else {
            if viewModel.isRevealed { hidePanel() }
            dismissedForCurrentActivation = false
        }
    }

    // MARK: - Affichage / masquage

    private func showPanel() {
        ensurePanel()
        // Déverrouiller la passphrase si besoin (partagée avec l'intercepteur).
        TransparentSessionManager.shared.unlock()
        // Partir de l'état replié (glyphe chiffré) puis peupler et animer
        // l'émergence au tour de run-loop suivant.
        viewModel.isRevealed = false
        viewModel.headerSealed = 1
        refresh()
        panel?.orderFrontRegardless()
        startRefreshTimer()
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.isRevealed = true
        }
        // Morph du glyphe d'en-tête APRÈS l'ouverture du panneau (sinon il se
        // joue pendant que le panneau est encore transparent et en train de
        // grandir, donc invisible).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            guard let self = self, self.viewModel.isRevealed else { return }
            withAnimation(.easeInOut(duration: 0.5)) { self.viewModel.headerSealed = 0 }
        }
    }

    /// Durée du morph de fermeture avant le retrait effectif du panneau (doit
    /// couvrir l'animation `isRevealed → false` de la vue).
    private let closeAnimationDuration: TimeInterval = 0.3

    private func hidePanel() {
        stopRefreshTimer()
        // Rejouer l'animation à l'envers (le panneau se rétracte sur le glyphe
        // qui se referme), puis retirer réellement la fenêtre.
        withAnimation(.easeInOut(duration: 0.25)) { viewModel.headerSealed = 1 }
        viewModel.isRevealed = false
        let panelRef = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + closeAnimationDuration) { [weak self] in
            guard let self = self, !self.viewModel.isRevealed else { return } // ré-ouvert entre-temps
            panelRef?.orderOut(nil)
            self.viewModel.bubbles = []
            self.viewModel.undecryptableCount = 0
            self.viewModel.freshBubbleID = nil
            // Prochaine ouverture : re-coller en bas dès le premier contenu.
            self.lastBottomSignature = nil
        }
    }

    /// Masquage à la demande de l'utilisateur (bouton ✕) : reste masqué jusqu'à
    /// la prochaine activation de conversation.
    private func userDidDismiss() {
        dismissedForCurrentActivation = true
        hidePanel()
    }

    // MARK: - Rafraîchissement du fil

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Relit les bulles visibles, déchiffre les jetons MC1., met à jour la vue
    /// et repositionne le panneau au bord de WhatsApp.
    private func refresh() {
        guard case .active(let title) = ConversationActivityMonitor.shared.state else { return }
        guard TransparentSessionManager.shared.isUnlocked else {
            TransparentSessionManager.shared.unlock()
            return
        }
        viewModel.conversationTitle = title

        var decrypted: [DecryptedBubble] = []
        var undecryptable = 0
        var occurrences: [String: Int] = [:]

        for bubble in ConversationAXReader.shared.visibleBubbles() {
            let tokens = ManicryptMessageFormat.encryptedTokens(in: bubble.rawLabel)
            guard !tokens.isEmpty else { continue }
            for token in tokens {
                if let plaintext = TransparentSessionManager.shared.decryptWire(token) {
                    let isOutgoing = bubble.direction == .outgoing
                    // Id stable par contenu : distingue une vraie insertion
                    // (nouveau message) d'un rafraîchissement identique. Le rang
                    // d'occurrence dédoublonne deux messages identiques visibles.
                    let base = "\(isOutgoing ? "o" : "i")|\(plaintext)"
                    let occurrence = occurrences[base, default: 0]
                    occurrences[base] = occurrence + 1
                    decrypted.append(DecryptedBubble(
                        id: "\(base)#\(occurrence)",
                        isOutgoing: isOutgoing,
                        plaintext: plaintext
                    ))
                } else {
                    undecryptable += 1
                }
            }
        }

        // Nouveau message en bas du fil (envoi/réception) : la dernière bulle
        // change d'id. On distingue le PREMIER remplissage (panneau qui s'ouvre :
        // pas d'animation par-bulle, l'ouverture du panneau s'en charge) d'un vrai
        // nouveau message arrivé alors que le fil était déjà peuplé.
        let newBottomID = decrypted.last?.id
        let isGenuineNewMessage = newBottomID != nil
            && newBottomID != lastBottomSignature
            && lastBottomSignature != nil
        viewModel.freshBubbleID = isGenuineNewMessage ? newBottomID : nil

        if decrypted != viewModel.bubbles { viewModel.bubbles = decrypted }
        if undecryptable != viewModel.undecryptableCount { viewModel.undecryptableCount = undecryptable }

        // Re-coller le scroll en bas dès qu'un nouveau message apparaît en bas
        // (y compris au premier remplissage) ; un rafraîchissement identique ne
        // le touche pas, préservant un défilement manuel vers l'historique.
        if let newBottomID = newBottomID, newBottomID != lastBottomSignature {
            lastBottomSignature = newBottomID
            viewModel.scrollToBottomToken &+= 1
        } else if newBottomID == nil {
            lastBottomSignature = nil
        }

        // Laisser SwiftUI recalculer sa taille avec le nouveau contenu, puis
        // ajuster le panneau et le repositionner (évite un panneau figé à 200 px).
        DispatchQueue.main.async { [weak self] in
            self?.resizePanelToFit()
            self?.repositionPanel()
        }
    }

    /// Ajuste la taille du panneau au contenu SwiftUI (hauteur plafonnée par la
    /// vue à la moitié de l'écran).
    private func resizePanelToFit() {
        guard let panel = panel, let hosting = panel.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 1 { size.width = 336 }
        if size.height < 1 { size.height = 120 }
        panel.setContentSize(size)
    }

    // MARK: - Copie manuelle

    private func copyPlaintext(_ text: String) {
        // Copie initiée par l'utilisateur (clic sur une bulle) — seule voie par
        // laquelle le clair atteint le presse-papier.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Panneau & position

    private func ensurePanel() {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: TransparentReadingView(viewModel: viewModel))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 336, height: 200),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // Ne prend le focus que si un contrôle l'exige (sélection de texte) : on
        // ne vole pas le focus de WhatsApp pour la lecture courante.
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // ombre portée par la carte SwiftUI
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        self.panel = panel
    }

    /// Ancre le panneau contre le bord droit de la fenêtre WhatsApp (ou à
    /// gauche si la place manque), aligné en haut. Repli : bord droit de l'écran.
    private func repositionPanel() {
        guard let panel = panel else { return }
        panel.layoutIfNeeded()
        let size = panel.frame.size
        let gap: CGFloat = 8

        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        guard let wa = ConversationAXReader.shared.whatsAppWindowFrame() else {
            // Repli : coin haut-droit de l'écran.
            let origin = NSPoint(x: visible.maxX - size.width - gap,
                                 y: visible.maxY - size.height - gap)
            panel.setFrameOrigin(origin)
            return
        }

        // À droite de WhatsApp par défaut.
        var x = wa.maxX + gap
        if x + size.width > visible.maxX {
            // Pas de place à droite → à gauche de la fenêtre.
            x = wa.minX - size.width - gap
            if x < visible.minX {
                // Ni à droite ni à gauche → chevaucher le bord droit interne.
                x = visible.maxX - size.width - gap
            }
        }
        // Aligné sur le haut de la fenêtre WhatsApp.
        var y = wa.maxY - size.height
        if y < visible.minY { y = visible.minY + gap }
        if y + size.height > visible.maxY { y = visible.maxY - size.height - gap }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
