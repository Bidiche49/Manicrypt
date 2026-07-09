//
//  OverlayPanelController.swift
//  Manicrypt
//
//  Panneau flottant non-activant qui affiche le résultat des raccourcis
//  ⌃⇧E / ⌃⇧D (FEAT-001).
//
//  Contraintes clés :
//  - Le focus reste dans l'app d'origine : le panel est `.nonactivatingPanel`
//    et ne devient jamais key. Échap et le clic extérieur sont détectés via des
//    moniteurs d'événements *globaux* (l'app active reste celle de l'utilisateur).
//  - Le texte affiché (chiffré ou clair) ne vit qu'en mémoire, le temps de
//    l'affichage. Le clair déchiffré n'est copié que sur action explicite.
//

import Cocoa
import SwiftUI

final class OverlayPanelController {
    static let shared = OverlayPanelController()

    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()

    /// Clair courant (mode déchiffré), conservé hors du view model pour que la
    /// copie manuelle reste pilotée ici. Effacé dès la fermeture.
    private var pendingPlaintext: String?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {
        viewModel.closeHandler = { [weak self] in self?.close() }
        viewModel.copyHandler = { [weak self] in self?.copyPendingPlaintext() }
        viewModel.openPreferencesHandler = {
            NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
        }
    }

    // MARK: - API de présentation

    /// ⌃⇧E : chiffré déjà déposé dans le presse-papier par l'appelant.
    func showEncrypted(_ cipher: String) {
        pendingPlaintext = nil
        present(state: .encrypted(cipher), alreadyCopied: true)
    }

    /// ⌃⇧D : clair affiché seulement, jamais copié automatiquement.
    func showDecrypted(_ plaintext: String) {
        pendingPlaintext = plaintext
        present(state: .decrypted(plaintext), alreadyCopied: false)
    }

    /// États d'erreur (sélection vide, non déchiffrable, passphrase manquante…).
    func showError(_ state: OverlayState) {
        pendingPlaintext = nil
        present(state: state, alreadyCopied: false)
    }

    // MARK: - Cycle de vie

    private func present(state: OverlayState, alreadyCopied: Bool) {
        assert(Thread.isMainThread, "L'overlay doit être présenté sur le main thread")
        ensurePanel()
        viewModel.present(state, alreadyCopied: alreadyCopied)
        startMonitors()

        // Laisser SwiftUI calculer sa taille, puis dimensionner/positionner
        // avant d'afficher (évite un flash au coin de l'écran).
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.resizePanelToFit()
            self.positionPanelNearCursor()
            panel.orderFrontRegardless()
        }
    }

    func close() {
        stopMonitors()
        panel?.orderOut(nil)
        pendingPlaintext = nil
        viewModel.reset() // libère le texte affiché
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let hosting = NSHostingView(rootView: OverlayView(viewModel: viewModel))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 376, height: 160),
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
        // Ne prend le statut key que si un contrôle l'exige : on ne vole donc
        // pas le focus de l'app d'origine.
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // l'ombre est portée par la carte SwiftUI
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting

        self.panel = panel
    }

    // MARK: - Taille & position

    private func resizePanelToFit() {
        guard let panel = panel, let hosting = panel.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 1 { size.width = 376 }
        size.height = min(max(size.height, 96), 480)

        // Conserver le coin haut-gauche pour éviter un « saut » au resize.
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(topLeft)
    }

    private func positionPanelNearCursor() {
        guard let panel = panel else { return }

        let mouse = NSEvent.mouseLocation // coordonnées globales, origine bas-gauche
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size

        // Par défaut : sous et légèrement à droite du curseur.
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 12)

        if origin.x + size.width > visible.maxX { origin.x = visible.maxX - size.width - 8 }
        if origin.x < visible.minX { origin.x = visible.minX + 8 }

        // Pas de place en dessous → basculer au-dessus du curseur.
        if origin.y < visible.minY { origin.y = mouse.y + 12 }
        if origin.y + size.height > visible.maxY { origin.y = visible.maxY - size.height - 8 }

        panel.setFrameOrigin(origin)
    }

    // MARK: - Copie manuelle du clair

    private func copyPendingPlaintext() {
        guard let plaintext = pendingPlaintext else { return }
        // Copie initiée par l'utilisateur (bouton « Copier ») — la seule voie
        // par laquelle le clair peut atteindre le presse-papier.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plaintext, forType: .string)
    }

    // MARK: - Moniteurs Échap / clic extérieur

    private func startMonitors() {
        stopMonitors()

        // Global : l'app d'origine garde le focus, on observe donc ses événements.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.handleMonitorEvent(event)
        }

        // Local : au cas où le panel aurait le focus (ex. déclenché depuis le menu).
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.handleMonitorEvent(event)
            return event
        }
    }

    private func stopMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handleMonitorEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 { close() } // 53 = Échap
        case .leftMouseDown, .rightMouseDown:
            guard let panel = panel else { return }
            // Coordonnées écran du clic ; ferme si hors du panel.
            if !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
                close()
            }
        default:
            break
        }
    }
}
