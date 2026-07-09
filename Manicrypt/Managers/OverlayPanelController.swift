//
//  OverlayPanelController.swift
//  Manicrypt
//
//  Panneau flottant non-activant de FEAT-001 (v3). Deux modes de présentation :
//   - HUD éphémère « Chiffré copié ✓ » (⌃⇧E en zone non éditable), auto-fermé ;
//   - overlay de déchiffrement (⌃⇧D en zone non éditable), avec relance possible
//     via une passphrase alternative.
//
//  Contraintes clés :
//  - Le focus reste dans l'app d'origine : le panel est `.nonactivatingPanel`
//    et ne devient jamais key. Échap et le clic extérieur sont détectés via des
//    moniteurs d'événements *globaux* (l'app active reste celle de l'utilisateur).
//  - Le clair déchiffré n'est copié que sur action explicite de l'utilisateur.
//

import Cocoa
import SwiftUI

final class OverlayPanelController {
    static let shared = OverlayPanelController()

    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()

    /// Clair courant (mode déchiffré), conservé hors du view model pour piloter la
    /// copie manuelle. Effacé à la fermeture.
    private var pendingPlaintext: String?
    /// Relance de déchiffrement avec une passphrase alternative (renvoie le clair
    /// ou `nil`). Câblée par `GlobalHotkeyManager` au moment de présenter ⌃⇧D.
    private var currentRetry: ((String) -> String?)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hudTimer: Timer?

    private init() {
        viewModel.closeHandler = { [weak self] in self?.close() }
        viewModel.copyHandler = { [weak self] in self?.copyPendingPlaintext() }
        viewModel.altSubmitHandler = { [weak self] pass in self?.attemptAlternate(pass) }
        viewModel.openPreferencesHandler = {
            NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
        }
    }

    // MARK: - API de présentation

    /// ⌃⇧E en zone non éditable : chiffré déjà déposé au presse-papier, HUD bref.
    func showEncryptedHUD() {
        pendingPlaintext = nil
        currentRetry = nil
        present(state: .encryptedHUD, alreadyCopied: true, installMonitors: false, autoDismiss: 1.5)
    }

    /// ⌃⇧D : clair affiché seulement. `retry` retente avec une autre passphrase.
    func showDecryptSuccess(_ plaintext: String, retry: @escaping (String) -> String?) {
        pendingPlaintext = plaintext
        currentRetry = retry
        present(state: .decrypted(plaintext), alreadyCopied: false)
    }

    /// ⌃⇧D dont le déchiffrement a échoué avec la passphrase de session : erreur +
    /// proposition de saisir une autre passphrase.
    func showDecryptFailure(retry: @escaping (String) -> String?) {
        pendingPlaintext = nil
        currentRetry = retry
        present(state: .notManicryptMessage)
    }

    /// Erreurs sans relance possible (sélection vide, passphrase absente, échec).
    func showError(_ state: OverlayState) {
        pendingPlaintext = nil
        currentRetry = nil
        present(state: state)
    }

    // MARK: - Cycle de vie

    private func present(state: OverlayState,
                         alreadyCopied: Bool = false,
                         installMonitors: Bool = true,
                         autoDismiss: TimeInterval? = nil) {
        assert(Thread.isMainThread, "L'overlay doit être présenté sur le main thread")
        ensurePanel()
        hudTimer?.invalidate()
        hudTimer = nil

        viewModel.present(state, alreadyCopied: alreadyCopied)
        if installMonitors { startMonitors() } else { stopMonitors() }

        // Laisser SwiftUI calculer sa taille, puis dimensionner/positionner avant
        // d'afficher (évite un flash au coin de l'écran).
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.resizePanelToFit()
            self.positionPanelNearCursor()
            panel.orderFrontRegardless()

            // Annuler tout timer HUD armé par un `present` antérieur du même tour de
            // run-loop (sinon son auto-fermeture pourrait fermer CETTE présentation).
            self.hudTimer?.invalidate()
            self.hudTimer = nil
            if let autoDismiss {
                self.hudTimer = Timer.scheduledTimer(withTimeInterval: autoDismiss, repeats: false) { [weak self] _ in
                    self?.close()
                }
            }
        }
    }

    func close() {
        hudTimer?.invalidate()
        hudTimer = nil
        stopMonitors()
        panel?.orderOut(nil)
        pendingPlaintext = nil
        currentRetry = nil
        viewModel.reset() // libère le texte affiché
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let hosting = NSHostingView(rootView: OverlayView(viewModel: viewModel))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 376, height: 120),
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
        // Ne prend le statut key que si un contrôle l'exige (SecureField) : on ne
        // vole donc pas le focus applicatif pour les cas courants.
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // l'ombre est portée par la carte/HUD SwiftUI
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
        size.height = min(max(size.height, 60), 520)
        panel.setContentSize(size)
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

    // MARK: - Copie manuelle / passphrase alternative

    private func copyPendingPlaintext() {
        guard let plaintext = pendingPlaintext else { return }
        // Copie initiée par l'utilisateur (bouton « Copier ») — seule voie par
        // laquelle le clair peut atteindre le presse-papier.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plaintext, forType: .string)
    }

    private func attemptAlternate(_ passphrase: String) {
        guard let retry = currentRetry else { return }
        if let plaintext = retry(passphrase) {
            pendingPlaintext = plaintext
            viewModel.showRetrySuccess(plaintext)
            DispatchQueue.main.async { [weak self] in self?.resizePanelToFit() }
        } else {
            viewModel.markAltFailed()
        }
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

        // Local : au cas où le panel aurait le focus (ex. saisie passphrase).
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
