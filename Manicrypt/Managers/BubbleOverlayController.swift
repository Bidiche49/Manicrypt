//
//  BubbleOverlayController.swift
//  Manicrypt
//
//  Overlay par-bulle du mode transparent (IMP-005).
//
//  Pose une fenêtre non-activante sur CHAQUE bulle MC1. visible de la conv liée,
//  affichant le clair (+ heure/statut, scrollable). Modèle « snap au repos » :
//  - positionné quand l'affichage est statique ;
//  - masqué pendant un scroll (frames qui bougent) puis re-posé à l'arrêt — PAS
//    de suivi continu (limite AX/Catalyst, cf. IMP-005) ;
//  - le message fraîchement arrivé joue un morph de glyphe.
//
//  Calage (limite AX prouvée : seule la frame de LIGNE pleine largeur est
//  exposée, pas la bulle) : hauteur = hauteur de ligne (fidèle) ; largeur =
//  estimation calibrée (les bulles MC1. sont ~toujours à la largeur max car le
//  ciphertext est long) ; alignement droite (sortant) / gauche (entrant).
//
//  Coexiste avec le panneau de lecture jusqu'à validation ou abandon.
//

import Cocoa
import SwiftUI

final class BubbleOverlayController {
    static let shared = BubbleOverlayController()

    // MARK: Calibration (ajustable visuellement)
    /// Largeur d'une bulle à sa largeur MAX, en fraction de la largeur de la
    /// FENÊTRE WhatsApp (les bulles MC1. sont ~toujours à cette largeur).
    private let maxBubbleWidthFraction: CGFloat = 0.46
    /// Padding droit de la bulle sortante = distance bord bulle → bord droit du
    /// panneau de conversation (doit matcher WhatsApp).
    private let rightPadding: CGFloat = 14
    /// Padding gauche des bulles entrantes.
    private let leftPadding: CGFloat = 14
    /// Rognage vertical (la ligne inclut l'espacement inter-messages).
    private let verticalInset: CGFloat = 3
    /// Bandes à exclure en haut (barre de navigation) et en bas (chatbar) de la
    /// fenêtre WhatsApp : une bulle hors de la zone de chat visible n'est pas
    /// overlayée.
    private let topChromeInset: CGFloat = 60
    private let bottomChromeInset: CGFloat = 64
    /// Déplacement de frame au-delà duquel on considère qu'un scroll a lieu.
    private let scrollThreshold: CGFloat = 3
    /// Cadence de re-lecture (détection scroll + repositionnement au repos).
    private let tickInterval: TimeInterval = 0.2
    /// Délai après le dernier événement molette avant de re-poser les overlays
    /// (anti-clignotement pendant un scroll continu).
    private let scrollSettleDelay: TimeInterval = 0.18

    private struct Overlay {
        let panel: NSPanel
        let viewModel: BubbleOverlayItemViewModel
    }

    /// Fenêtres actives, indexées par signature de message (direction + clair).
    private var overlays: [String: Overlay] = [:]
    /// Dernières frames par signature, pour détecter un scroll entre deux ticks.
    private var lastFrames: [String: CGRect] = [:]
    private var reusePool: [NSPanel] = []
    private var timer: Timer?
    /// Signature du message fraîchement arrivé à animer une fois (nouveau message).
    private var pendingFreshSignature: String?
    /// Instant du dernier événement molette (hors app), pour masquer sans latence.
    private var lastScrollAt: Date = .distantPast
    private var scrollMonitor: Any?

    private init() {}

    func start() {
        assert(Thread.isMainThread)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleActivityChange),
            name: ConversationActivityMonitor.stateDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleNewMessage),
            name: TransparentReadingPanelController.newMessageDidAppearNotification, object: nil)
        // Moniteur molette GLOBAL : masque les overlays à l'instant même où un
        // scroll démarre (dans WhatsApp), sans attendre le tick → zéro latence.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
            self?.handleScrollWheel()
        }
        syncWithActivityState()
        print("🫧 [Transparent] Overlay par-bulle prêt")
    }

    private func handleScrollWheel() {
        guard ConversationActivityMonitor.shared.state.isActive else { return }
        lastScrollAt = Date()
        // Masquage immédiat (les overlays se re-poseront à l'arrêt du scroll).
        for overlay in overlays.values { overlay.panel.orderOut(nil) }
    }

    // MARK: - État

    @objc private func handleActivityChange() {
        DispatchQueue.main.async { [weak self] in self?.syncWithActivityState() }
    }

    private func syncWithActivityState() {
        if ConversationActivityMonitor.shared.state.isActive {
            startTimer()
        } else {
            stopTimer()
            hideAll()
        }
    }

    @objc private func handleNewMessage() {
        // Le nouveau message = bulle la plus basse déchiffrable ; sa signature
        // sera marquée « fraîche » (animée) au prochain tick.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let located = ConversationAXReader.shared.visibleBubblesLocated()
            if let bottom = self.decryptableItems(in: located).last {
                self.pendingFreshSignature = bottom.signature
            }
            self.tick()
        }
    }

    // MARK: - Boucle

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private struct Item {
        let signature: String
        let plaintext: String
        let meta: String
        let isOutgoing: Bool
        let rowFrame: CGRect
    }

    private func decryptableItems(in bubbles: [ConversationAXReader.LocatedBubble]) -> [Item] {
        var items: [Item] = []
        var occurrences: [String: Int] = [:]
        for bubble in bubbles {
            // Premier jeton MC1. de la bulle qui se déchiffre.
            let tokens = ManicryptMessageFormat.encryptedTokens(in: bubble.rawLabel)
            var decoded: (token: String, plaintext: String)?
            for token in tokens {
                if let plaintext = TransparentSessionManager.shared.decryptWire(token) {
                    decoded = (token, plaintext); break
                }
            }
            guard let decoded = decoded else { continue }
            let isOutgoing = bubble.direction == .outgoing
            // Rang d'occurrence : deux messages identiques ne se marchent plus
            // dessus (chacun garde son overlay).
            let base = "\(isOutgoing ? "o" : "i")|\(decoded.plaintext)"
            let occ = occurrences[base, default: 0]
            occurrences[base] = occ + 1
            items.append(Item(
                signature: "\(base)#\(occ)",
                plaintext: decoded.plaintext,
                meta: Self.metadata(from: bubble.rawLabel, token: decoded.token),
                isOutgoing: isOutgoing,
                rowFrame: bubble.screenFrame
            ))
        }
        return items
    }

    private func tick() {
        guard ConversationActivityMonitor.shared.state.isActive,
              TransparentSessionManager.shared.isUnlocked else { hideAll(); return }

        let items = decryptableItems(in: ConversationAXReader.shared.visibleBubblesLocated())
        let currentFrames = Dictionary(items.map { ($0.signature, $0.rowFrame) }) { a, _ in a }

        // Scroll en cours ? Molette récente (masquage instantané déjà fait par
        // le moniteur) OU une bulle commune a bougé depuis le dernier tick.
        var scrolling = Date().timeIntervalSince(lastScrollAt) < scrollSettleDelay
        for (sig, frame) in currentFrames {
            if let previous = lastFrames[sig],
               abs(previous.minY - frame.minY) > scrollThreshold
                || abs(previous.minX - frame.minX) > scrollThreshold {
                scrolling = true
                break
            }
        }
        lastFrames = currentFrames

        if scrolling {
            // Pendant le scroll : masquer sans détruire (re-snap au repos).
            for overlay in overlays.values { overlay.panel.orderOut(nil) }
            return
        }

        // Repos : (re)poser un overlay par bulle visible, calé sur la fenêtre.
        // Sans frame fenêtre exploitable, on ne pose rien (placement non fiable).
        guard let wa = ConversationAXReader.shared.whatsAppWindowFrame() else {
            for overlay in overlays.values { overlay.panel.orderOut(nil) }
            return
        }

        var seen = Set<String>()
        for item in items {
            guard let rect = bubbleRect(for: item.rowFrame, isOutgoing: item.isOutgoing, window: wa) else {
                continue // bulle hors de la zone de chat visible
            }
            seen.insert(item.signature)
            let fresh = (item.signature == pendingFreshSignature)
            place(item, rect: rect, animate: fresh)
        }
        pendingFreshSignature = nil

        // Retirer les overlays des bulles qui ne sont plus visibles.
        for (sig, overlay) in overlays where !seen.contains(sig) {
            overlay.panel.orderOut(nil)
            recycle(overlay.panel)
            overlays[sig] = nil
        }
    }

    // MARK: - Placement

    /// Rect de l'overlay, ancré sur la FENÊTRE WhatsApp (la frame de ligne AX
    /// déborde et n'est pas fiable en X) : largeur max, aligné au bord droit
    /// (sortant) / gauche (entrant) avec le padding de la vraie bulle ; hauteur
    /// prise sur la ligne. `nil` si la bulle est hors de la zone de chat visible.
    private func bubbleRect(for rowFrame: CGRect, isOutgoing: Bool, window wa: CGRect) -> CGRect? {
        // Zone de chat visible (hors navbar et chatbar).
        let chatMinY = wa.minY + bottomChromeInset
        let chatMaxY = wa.maxY - topChromeInset
        guard chatMaxY > chatMinY else { return nil }

        // Vertical depuis la ligne, clippé à la zone de chat.
        let rawTop = rowFrame.maxY - verticalInset
        let rawBottom = rowFrame.minY + verticalInset
        let top = min(rawTop, chatMaxY)
        let bottom = max(rawBottom, chatMinY)
        let height = top - bottom
        guard height >= 16 else { return nil } // trop clippée → hors zone

        let width = wa.width * maxBubbleWidthFraction
        let x = isOutgoing
            ? wa.maxX - rightPadding - width
            : wa.minX + leftPadding
        return CGRect(x: x, y: bottom, width: width, height: height)
    }

    private func place(_ item: Item, rect: CGRect, animate: Bool) {
        let overlay = overlays[item.signature] ?? makeOverlay(for: item.signature)

        let vm = overlay.viewModel
        vm.plaintext = item.plaintext
        vm.meta = item.meta
        vm.isOutgoing = item.isOutgoing

        // Le clair déborde-t-il de la bulle ? Si NON, l'overlay est transparent
        // à la souris → la molette scrolle la conversation WhatsApp dessous.
        // Si OUI, il capte la souris pour scroller son propre contenu.
        let needsScroll = contentOverflows(item.plaintext, hasMeta: !item.meta.isEmpty, in: rect)
        vm.isScrollable = needsScroll
        overlay.panel.ignoresMouseEvents = !needsScroll

        if animate {
            vm.animateEntry = true
            vm.revealToken &+= 1
        }
        overlay.panel.setFrame(rect, display: true)
        overlay.panel.orderFrontRegardless()
    }

    /// Estime si le clair (+ ligne meta) dépasse la hauteur de l'overlay pour sa
    /// largeur — donc s'il a besoin de scroller. Biais FRANC vers le passthrough :
    /// le ciphertext base64 étant toujours plus long que le clair, une bulle
    /// courte ne déborde jamais ; on ne marque « scrollable » qu'au-delà d'une
    /// marge nette, pour ne pas capter la souris à tort.
    private func contentOverflows(_ text: String, hasMeta: Bool, in rect: CGRect) -> Bool {
        let hPadding: CGFloat = 20   // 10 + 10 (cf. BubbleOverlayItemView)
        let vPadding: CGFloat = 12   // 6 + 6
        let metaHeight: CGFloat = hasMeta ? 16 : 0
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: max(rect.width - hPadding, 20), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let needed = ceil(bounding.height) + metaHeight + vPadding
        // Marge de 24 px : seul un vrai débordement (clair plus long que la
        // bulle chiffrée) rend l'overlay scrollable.
        return needed > rect.height + 24
    }

    private func makeOverlay(for signature: String) -> Overlay {
        let vm = BubbleOverlayItemViewModel()
        let panel: NSPanel
        if let reused = reusePool.popLast() {
            panel = reused
            (panel.contentView as? NSHostingView<BubbleOverlayItemView>)?.rootView = BubbleOverlayItemView(viewModel: vm)
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            // Réglé par `place` selon que le contenu déborde (scroll) ou non.
            panel.ignoresMouseEvents = true
            panel.contentView = NSHostingView(rootView: BubbleOverlayItemView(viewModel: vm))
        }
        let overlay = Overlay(panel: panel, viewModel: vm)
        overlays[signature] = overlay
        return overlay
    }

    private func recycle(_ panel: NSPanel) {
        if reusePool.count < 30 { reusePool.append(panel) }
    }

    private func hideAll() {
        for overlay in overlays.values {
            overlay.panel.orderOut(nil)
            recycle(overlay.panel)
        }
        overlays.removeAll()
        lastFrames.removeAll()
        pendingFreshSignature = nil
    }

    // MARK: - Parsing heure/statut

    /// Extrait la portion « heure · statut » du label composé, après le jeton
    /// MC1. (ex. « Your message, MC1.xxx, 10Julyat12:24, Sent to X, Delivered »
    /// → « 10Julyat12:24 · Sent to X · Delivered »).
    private static func metadata(from rawLabel: String, token: String) -> String {
        guard let range = rawLabel.range(of: token) else { return "" }
        let tail = rawLabel[range.upperBound...]
        let parts = tail
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }
}
