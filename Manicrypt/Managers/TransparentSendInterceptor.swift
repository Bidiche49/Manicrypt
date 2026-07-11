//
//  TransparentSendInterceptor.swift
//  Manicrypt
//
//  Chiffrement à l'envoi du mode transparent (FEAT-002, brique 3).
//
//  Architecture actée (Checkpoint 0, 2026-07-11) : CGEventTap sur Return →
//  lire le champ de saisie (AX) → chiffrer MC1. → réécrire le champ via AX
//  SYNCHRONEMENT dans le callback du tap → laisser passer le Return. WhatsApp
//  lit le champ au moment du Return (prouvé par le POC : un set AX sans
//  textViewDidChange part quand même), donc le message envoyé est le chiffré.
//
//  FAIL-SAFE ABSOLU : un message ne doit JAMAIS partir en clair dans une
//  conversation liée. Tout doute (titre invérifiable alors que l'état dit
//  « actif », passphrase indisponible, échec de chiffrement, réécriture non
//  confirmée) ⇒ le Return est AVALÉ (l'envoi n'a pas lieu) + alerte. Les cas
//  sûrs par nature (conv non liée, champ vide, focus hors composer, message
//  déjà chiffré) laissent passer le Return sans traitement.
//
//  Défense en profondeur : l'état du moniteur d'activité peut avoir jusqu'à
//  ~2 s de retard (réconciliation) → le titre de la conversation est RE-vérifié
//  ici, au moment exact du Return, avant toute décision.
//
//  Le tap n'est activé que quand l'état est .active : en dehors, aucun
//  événement clavier ne transite par Manicrypt (zéro latence ajoutée).
//

import Cocoa
import Carbon.HIToolbox
import ApplicationServices

final class TransparentSendInterceptor {
    static let shared = TransparentSendInterceptor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    // MARK: - Cycle de vie

    func start() {
        assert(Thread.isMainThread)
        guard eventTap == nil else { return }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activityStateDidChange),
            name: ConversationActivityMonitor.stateDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bindingDidChange),
            name: ConversationBindingManager.bindingDidChangeNotification,
            object: nil
        )

        createEventTap()
        syncTapWithActivityState()
        print("🛡️ [Transparent] Intercepteur d'envoi prêt")
    }

    private func createEventTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<TransparentSendInterceptor>.fromOpaque(refcon)
                    .takeUnretainedValue()
                    .handleEvent(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            // Sans tap, PAS de chiffrement à l'envoi possible : ne jamais
            // laisser croire que la protection est en place.
            print("❌ [Transparent] Création du CGEventTap impossible (permission Accessibilité ?)")
            DispatchQueue.main.async {
                OverlayPanelController.shared.showError(.failure(
                    "Mode transparent indisponible : impossible d'intercepter le clavier. Vérifiez la permission Accessibilité."
                ))
            }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)

        eventTap = tap
        runLoopSource = source
    }

    // MARK: - Synchronisation avec l'état d'activité

    @objc private func activityStateDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.syncTapWithActivityState()
        }
    }

    private func syncTapWithActivityState() {
        guard let tap = eventTap else { return }
        let isActive = ConversationActivityMonitor.shared.state.isActive
        CGEvent.tapEnable(tap: tap, enable: isActive)
        if isActive {
            // Déverrouille la passphrase partagée hors du callback du tap.
            TransparentSessionManager.shared.unlock { unlocked in
                if !unlocked {
                    OverlayPanelController.shared.showError(.failure(
                        "Conversation protégée : passphrase indisponible. Les envois seront bloqués tant que l'authentification n'a pas abouti."
                    ))
                }
            }
        }
    }

    @objc private func bindingDidChange() {
        DispatchQueue.main.async { [weak self] in
            TransparentSessionManager.shared.clear()
            self?.syncTapWithActivityState()
        }
    }

    // MARK: - Callback du tap (synchrone, main run loop)

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Le système désactive un tap trop lent ou pendant une saisie sécurisée :
        // ré-armer, sinon le mode transparent meurt silencieusement.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap, ConversationActivityMonitor.shared.state.isActive {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter else {
            return Unmanaged.passUnretained(event)
        }
        // Shift+Return = nouvelle ligne ; les autres combinaisons modifiées ne
        // sont pas l'envoi standard → ne pas traiter.
        let flags = event.flags
        if flags.contains(.maskShift) || flags.contains(.maskCommand)
            || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            return Unmanaged.passUnretained(event)
        }

        return processReturnKey(event: event)
    }

    private func processReturnKey(event: CGEvent) -> Unmanaged<CGEvent>? {
        // 1) État du moniteur : hors état actif, comportement intact.
        //    (Le tap est en principe désactivé hors état actif — ceinture.)
        guard ConversationActivityMonitor.shared.state.isActive else {
            return Unmanaged.passUnretained(event)
        }
        // 2) Course à la désactivation : l'utilisateur vient de quitter WhatsApp
        //    et l'état n'a pas encore basculé.
        guard ConversationAXReader.shared.isWhatsAppFrontmost() else {
            return Unmanaged.passUnretained(event)
        }
        // 3) Return n'envoie un message que si le focus est dans le composer
        //    (dans la recherche, un modal, etc., il fait autre chose).
        guard let focused = ConversationAXReader.shared.focusedElement(),
              ConversationAXReader.shared.stringAttribute(focused, "AXIdentifier")
                == ConversationAXReader.AXID.composer else {
            return Unmanaged.passUnretained(event)
        }
        // 4) Défense en profondeur : re-vérifier la conversation MAINTENANT.
        guard let binding = ConversationBindingManager.shared.currentBinding() else {
            return Unmanaged.passUnretained(event)
        }
        guard let currentTitle = ConversationAXReader.shared.currentConversationTitle() else {
            // L'état dit « conv liée active » mais le titre est invérifiable :
            // doute ⇒ bloquer (jamais de clair au bénéfice du doute).
            return swallowAndAlert("Conversation invérifiable au moment de l'envoi — message bloqué par précaution. Réessayez.")
        }
        guard currentTitle == binding.conversationTitle else {
            // Conversation non liée : comportement strictement inchangé.
            return Unmanaged.passUnretained(event)
        }
        // 5) Lire le brouillon. Champ vide : Return est inoffensif.
        guard let draft = ConversationAXReader.shared.stringAttribute(focused, kAXValueAttribute as String),
              !draft.isEmpty else {
            return Unmanaged.passUnretained(event)
        }
        // 6) Déjà chiffré (collé depuis le mode manuel) : ne pas sur-chiffrer.
        if ManicryptMessageFormat.isEncryptedMessage(draft) {
            return Unmanaged.passUnretained(event)
        }
        // 7) Chiffrer. Passphrase absente = session pas prête ⇒ bloquer.
        guard TransparentSessionManager.shared.isUnlocked else {
            DispatchQueue.main.async { TransparentSessionManager.shared.unlock() }
            return swallowAndAlert("Passphrase non déverrouillée — message bloqué. Authentifiez-vous puis réessayez.")
        }
        guard let wire = TransparentSessionManager.shared.encryptToWire(draft) else {
            return swallowAndAlert("Échec du chiffrement — le message n'a PAS été envoyé.")
        }
        // 8) Réécrire le champ, SYNCHRONEMENT, et vérifier la réécriture avant
        //    de relâcher le Return (sinon course → clair envoyé).
        let setStatus = AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, wire as CFString)
        guard setStatus == .success,
              ConversationAXReader.shared.stringAttribute(focused, kAXValueAttribute as String) == wire else {
            return swallowAndAlert("Réécriture du champ impossible — envoi bloqué pour ne pas partir en clair.")
        }
        // 9) Le Return part : WhatsApp lit le champ (chiffré) et l'envoie.
        print("🔒 [Transparent] Message chiffré à l'envoi (\(wire.count) caractères)")
        return Unmanaged.passUnretained(event)
    }

    /// Avale le Return (l'envoi n'a pas lieu) et alerte l'utilisateur.
    private func swallowAndAlert(_ message: String) -> Unmanaged<CGEvent>? {
        print("🚫 [Transparent] Return avalé : \(message)")
        DispatchQueue.main.async {
            OverlayPanelController.shared.showError(.failure(message))
        }
        return nil
    }
}
