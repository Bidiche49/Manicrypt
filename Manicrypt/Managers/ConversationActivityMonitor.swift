//
//  ConversationActivityMonitor.swift
//  Manicrypt
//
//  Détection d'activité du mode transparent (FEAT-002, brique 2) : la
//  conversation LIÉE est-elle actuellement au premier plan dans WhatsApp ?
//
//  Machine à états binaire — .active(titre) / .inactive — alimentée par trois
//  sources combinées (contrainte POC : l'arbre AX n'existe qu'au premier plan) :
//  - NSWorkspace : activation/désactivation/terminaison de WhatsApp. Toute app
//    autre que WhatsApp au premier plan ⇒ inactif, sans lecture AX.
//  - AXObserver sur WhatsApp (chemin rapide) : un changement de conversation
//    émet une rafale de 6–8 AXLayoutChanged + un AXFocusedUIElementChanged
//    (POC §Q4), sans le nom de la conversation → l'événement n'est qu'un
//    déclencheur, débouncé 200 ms, suivi d'une relecture du titre.
//  - Réconciliation périodique (filet de sécurité) : toutes les 2 s quand
//    WhatsApp est au premier plan ET qu'une liaison existe, relecture du titre.
//    Garantit la convergence de l'état même si l'observer est mort, et sert de
//    détecteur de surdité (voir ci-dessous).
//
//  Robustesse observer (bug constaté au Checkpoint 2, 2026-07-11) : après une
//  RELANCE de WhatsApp, un AXObserverAddNotification immédiat peut être refusé
//  ou rester silencieusement inopérant (serveur AX Catalyst pas prêt). D'où :
//  codes retour vérifiés + retries espacés, et ré-attachement automatique si la
//  réconciliation détecte un changement d'état qu'aucun événement AX n'a signalé.
//
//  Fail-safe : tout état indéterminé (titre illisible, arbre en reconstruction,
//  permission absente, pas de liaison) ⇒ .inactive. Aucun traitement des
//  briques 3-4 ne doit avoir lieu hors de l'état .active.
//

import Cocoa
import ApplicationServices

final class ConversationActivityMonitor {
    static let shared = ConversationActivityMonitor()

    /// Postée à chaque bascule d'état (main thread).
    static let stateDidChangeNotification = Notification.Name("ManicryptTransparentModeStateDidChange")

    enum State: Equatable {
        case inactive
        case active(conversationTitle: String)

        var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    private(set) var state: State = .inactive

    /// Debounce des rafales AX (POC : 6–8 events par switch de conversation).
    private let debounceInterval: TimeInterval = 0.2
    /// Cap anti-famine : une rafale continue (animations) ne repousse jamais la
    /// relecture au-delà de ce délai après le premier événement en attente.
    private let maxDebouncePostponement: TimeInterval = 0.6
    /// Cadence du polling de disponibilité de l'arbre AX après activation :
    /// on relit le titre toutes les `readinessPollStep` au lieu d'attendre un
    /// délai fixe, et on bascule dès que l'arbre est lisible (souvent bien avant
    /// 1 s). Plafonné à `maxReadinessWait` (fail-safe : au-delà, inactif).
    private let readinessPollStep: TimeInterval = 0.075
    private let maxReadinessWait: TimeInterval = 1.5
    /// Période du filet de réconciliation (actif seulement WhatsApp au premier
    /// plan + liaison existante ; la lecture parcourt ~350 nœuds, négligeable).
    private let reconciliationInterval: TimeInterval = 2.0
    /// Tentatives d'attachement de l'observer avant de ne compter que sur la
    /// réconciliation périodique.
    private let maxAttachRetries = 5

    private var started = false
    private var axObserver: AXObserver?
    private var observedPid: pid_t?
    private var observerHealthy = false
    private var attachRetryCount = 0
    private var lastAXEventAt: Date?
    private var firstPendingEventAt: Date?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var pendingReevaluation: DispatchWorkItem?
    private var reconciliationTimer: Timer?

    private init() {}

    // MARK: - Cycle de vie

    /// Démarre la surveillance (idempotent, main thread). Ne fait rien de
    /// coûteux tant qu'aucune liaison n'existe et que WhatsApp n'est pas devant.
    func start() {
        assert(Thread.isMainThread)
        guard !started else { return }
        started = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handleApplicationActivation(note)
        })
        workspaceTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handleApplicationTermination(note)
        })

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bindingDidChange),
            name: ConversationBindingManager.bindingDidChangeNotification,
            object: nil
        )

        // État initial : WhatsApp peut déjà être au premier plan.
        if ConversationAXReader.shared.isWhatsAppFrontmost() {
            attachAXObserverIfNeeded()
            startReconciliationTimer()
            pollReadinessThenReevaluate(reason: "démarrage")
        }
        print("👁️ [Transparent] Surveillance d'activité démarrée")
    }

    // MARK: - Événements NSWorkspace

    private func handleApplicationActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        if app.bundleIdentifier == ConversationAXReader.whatsAppBundleID {
            // Nouveau cycle d'activation : re-créditer les tentatives d'attachement.
            attachRetryCount = 0
            attachAXObserverIfNeeded()
            startReconciliationTimer()
            // Basculer dès que l'arbre AX est lisible (polling), sans attendre
            // un délai fixe : nettement plus réactif dans le cas courant.
            pollReadinessThenReevaluate(reason: "WhatsApp activé")
        } else {
            // Autre app au premier plan : inactif immédiat, sans lecture AX.
            stopReconciliationTimer()
            pendingReevaluation?.cancel()
            setState(.inactive, reason: "app au premier plan ≠ WhatsApp")
        }
    }

    private func handleApplicationTermination(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == ConversationAXReader.whatsAppBundleID else {
            return
        }
        detachAXObserver()
        stopReconciliationTimer()
        pendingReevaluation?.cancel()
        setState(.inactive, reason: "WhatsApp quitté")
    }

    @objc private func bindingDidChange() {
        scheduleReevaluation(after: 0.05, reason: "liaison modifiée")
    }

    // MARK: - Réévaluation débouncée

    /// Déclencheur AX (rafale au switch de conv) → une seule relecture différée.
    fileprivate func handleAXEvent() {
        lastAXEventAt = Date()

        // Anti-famine : si la rafale dure depuis trop longtemps, lire maintenant
        // au lieu de repousser encore.
        if let first = firstPendingEventAt,
           Date().timeIntervalSince(first) > maxDebouncePostponement {
            pendingReevaluation?.cancel()
            reevaluate(reason: "événement AX (rafale longue)")
            return
        }
        if firstPendingEventAt == nil { firstPendingEventAt = Date() }
        scheduleReevaluation(after: debounceInterval, reason: "événement AX")
    }

    /// Après une activation, l'arbre AX profond de WhatsApp met un temps variable
    /// (UIKit lazy) à se (re)construire. Plutôt qu'attendre un délai fixe, on
    /// sonde la lisibilité du titre par petits pas et on bascule dès qu'il est
    /// lisible — souvent bien avant 1 s. Au-delà du plafond, réévaluation finale
    /// (fail-safe : titre illisible ⇒ inactif).
    private func pollReadinessThenReevaluate(reason: String, deadline: Date? = nil) {
        pendingReevaluation?.cancel()

        let cap = deadline ?? Date().addingTimeInterval(maxReadinessWait)

        // Conditions terminales : plus besoin d'attendre l'arbre.
        let stillWaiting = ConversationBindingManager.shared.currentBinding() != nil
            && ConversationAXReader.shared.isWhatsAppFrontmost()
            && ConversationAXReader.shared.currentConversationTitle() == nil
            && Date() < cap

        guard stillWaiting else {
            reevaluate(reason: reason)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.pollReadinessThenReevaluate(reason: reason, deadline: cap)
        }
        pendingReevaluation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + readinessPollStep, execute: work)
    }

    private func scheduleReevaluation(after delay: TimeInterval, reason: String) {
        pendingReevaluation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reevaluate(reason: reason)
        }
        pendingReevaluation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Source de vérité de l'état. Chaque garde qui échoue ⇒ inactif (fail-safe).
    private func reevaluate(reason: String) {
        firstPendingEventAt = nil

        guard let binding = ConversationBindingManager.shared.currentBinding() else {
            setState(.inactive, reason: "aucune conversation liée")
            return
        }
        guard ConversationAXReader.shared.isWhatsAppFrontmost() else {
            setState(.inactive, reason: "WhatsApp en arrière-plan")
            return
        }
        guard let title = ConversationAXReader.shared.currentConversationTitle() else {
            // Arbre pas (encore) lisible, pas de conv ouverte, ou id AX disparu.
            setState(.inactive, reason: "titre de conversation illisible")
            return
        }
        if binding.bundleID == ConversationAXReader.whatsAppBundleID,
           title == binding.conversationTitle {
            setState(.active(conversationTitle: title), reason: reason)
        } else {
            setState(.inactive, reason: "conversation active non liée")
        }
    }

    private func setState(_ newState: State, reason: String) {
        guard newState != state else { return }
        state = newState
        switch newState {
        case .active(let title):
            print("🟢 [Transparent] ACTIF — conversation liée au premier plan « \(title) » (\(reason))")
        case .inactive:
            print("⚪️ [Transparent] inactif — \(reason)")
        }
        NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: nil)
    }

    // MARK: - Réconciliation périodique (filet + détecteur de surdité)

    private func startReconciliationTimer() {
        guard reconciliationTimer == nil else { return }
        reconciliationTimer = Timer.scheduledTimer(
            withTimeInterval: reconciliationInterval,
            repeats: true
        ) { [weak self] _ in
            self?.reconcile()
        }
    }

    private func stopReconciliationTimer() {
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil
    }

    private func reconcile() {
        guard ConversationAXReader.shared.isWhatsAppFrontmost(),
              ConversationBindingManager.shared.currentBinding() != nil else {
            return
        }
        let stateBefore = state
        reevaluate(reason: "réconciliation périodique")

        // L'état a changé sans qu'aucun événement AX récent ne l'ait signalé :
        // l'observer est sourd (cas typique : registration faite trop tôt après
        // une relance de WhatsApp) → le ré-attacher.
        let observerSilent = lastAXEventAt.map {
            Date().timeIntervalSince($0) > reconciliationInterval * 2
        } ?? true
        if state != stateBefore, observerSilent {
            print("⚠️ [Transparent] Changement d'état sans événement AX — observer sourd, ré-attachement")
            attachRetryCount = 0
            attachAXObserver(force: true)
        }
    }

    // MARK: - AXObserver

    private func attachAXObserverIfNeeded() {
        attachAXObserver(force: false)
    }

    /// Attache l'observer AX au process WhatsApp courant. Recréé si le pid a
    /// changé (relance de WhatsApp), si l'attachement précédent était en échec,
    /// ou sur demande (force). Les codes retour d'enregistrement sont VÉRIFIÉS :
    /// un refus (serveur AX pas prêt juste après lancement) déclenche un retry
    /// espacé au lieu d'un observer silencieusement mort.
    private func attachAXObserver(force: Bool) {
        guard let app = ConversationAXReader.shared.whatsAppApplication() else { return }
        let pid = app.processIdentifier
        if !force, axObserver != nil, observedPid == pid, observerHealthy { return }
        detachAXObserver()

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon = refcon else { return }
            Unmanaged<ConversationActivityMonitor>.fromOpaque(refcon)
                .takeUnretainedValue()
                .handleAXEvent()
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer = observer else {
            print("⚠️ [Transparent] AXObserverCreate a échoué (pid \(pid))")
            scheduleAttachRetry()
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Stratégie POC §Q4 : ces deux notifications couvrent le switch de conv ;
        // AXTitleChanged ne se déclenche jamais chez WhatsApp (ne pas s'y fier).
        var allRegistered = true
        for notification in [kAXLayoutChangedNotification, kAXFocusedUIElementChangedNotification] {
            let error = AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
            if error != .success {
                allRegistered = false
                print("⚠️ [Transparent] Enregistrement \(notification) refusé (AXError \(error.rawValue), pid \(pid))")
            }
        }
        guard allRegistered else {
            // Observer inutilisable : ne pas le garder, réessayer plus tard.
            scheduleAttachRetry()
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        observedPid = pid
        observerHealthy = true
        attachRetryCount = 0
        lastAXEventAt = nil
        print("👁️ [Transparent] Observer AX attaché à WhatsApp (pid \(pid))")
    }

    private func scheduleAttachRetry() {
        observerHealthy = false
        guard attachRetryCount < maxAttachRetries else {
            print("⚠️ [Transparent] Observer AX indisponible après \(maxAttachRetries) tentatives — la réconciliation périodique prend le relais")
            return
        }
        attachRetryCount += 1
        let delay = TimeInterval(attachRetryCount) // backoff linéaire 1 s, 2 s…
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self,
                  ConversationAXReader.shared.whatsAppApplication() != nil else {
                return
            }
            self.attachAXObserver(force: true)
        }
    }

    private func detachAXObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        axObserver = nil
        observedPid = nil
        observerHealthy = false
    }
}
