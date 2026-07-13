//
//  ConversationAXReader.swift
//  Manicrypt
//
//  Lecture ciblée de l'arbre Accessibility de WhatsApp Desktop (FEAT-002).
//
//  Contraintes empiriques (POC axprobe, 2026-07) intégrées au design :
//  - L'arbre AX profond n'existe QUE quand WhatsApp est au premier plan, et met
//    ~1 s à se (re)construire après activation → toute lecture qui suit une
//    activation passe par un délai de stabilisation.
//  - Les chemins d'index sont instables → localisation par AXIdentifier
//    exclusivement, avec budget de parcours borné.
//  - Aucun identifiant technique de conversation n'est exposé : le titre affiché
//    (AXDescription du bouton d'en-tête) est la seule clé disponible.
//  Les AXIdentifier observés ne sont pas contractuels (MAJ WhatsApp = casse
//  possible) → chaque échec de localisation est remonté comme erreur typée,
//  jamais en crash ni en valeur par défaut silencieuse.
//

import Cocoa
import ApplicationServices

final class ConversationAXReader {
    static let shared = ConversationAXReader()

    /// Bundle de WhatsApp Desktop (Mac Catalyst) — pilote V1.
    static let whatsAppBundleID = "net.whatsapp.WhatsApp"

    /// Identifiants AX observés sur WhatsApp Desktop 26.25.77 (POC axprobe).
    enum AXID {
        static let conversationTitle = "NavigationBar_HeaderViewButton"
        static let composer = "ChatBar_ComposerTextView"
        static let messagesTable = "ChatMessagesTableView"
        static let bubble = "WAMessageBubbleTableViewCell"
    }

    enum ReaderError: Error {
        case accessibilityNotTrusted   // permission AX absente
        case appNotRunning             // WhatsApp non lancé
        case titleUnavailable          // pas de conversation ouverte, ou id AX disparu (MAJ WhatsApp ?)

        var userMessage: String {
            switch self {
            case .accessibilityNotTrusted:
                return "La permission Accessibilité est requise. Ouvrez Réglages Système ▸ Confidentialité et sécurité ▸ Accessibilité et activez Manicrypt."
            case .appNotRunning:
                return "WhatsApp n'est pas lancé. Ouvrez WhatsApp, affichez la conversation à protéger, puis réessayez."
            case .titleUnavailable:
                return "Impossible de lire le titre de la conversation. Vérifiez qu'une conversation est bien ouverte dans WhatsApp (pas seulement la liste), puis réessayez. Si le problème persiste après une mise à jour de WhatsApp, la structure de l'app a peut-être changé."
            }
        }
    }

    /// Polling de disponibilité de l'arbre AX après activation : on sonde le
    /// titre par petits pas et on répond dès qu'il est lisible (souvent bien
    /// avant 1 s), plutôt qu'un délai fixe. Plafonné à `maxReadinessWait`.
    private let readinessPollStep: TimeInterval = 0.075
    private let maxReadinessWait: TimeInterval = 1.5

    /// Budget de parcours de l'arbre (l'arbre complet observé fait ~350 nœuds ;
    /// large marge sans risque d'emballement).
    private let walkBudget = 20_000

    private init() {}

    // MARK: - État de l'app cible

    func whatsAppApplication() -> NSRunningApplication? {
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.whatsAppBundleID)
            .first
    }

    func isWhatsAppFrontmost() -> Bool {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.whatsAppBundleID
    }

    // MARK: - Lectures directes (supposent WhatsApp frontmost, arbre construit)

    /// Titre de la conversation active : AXDescription du bouton d'en-tête.
    /// `nil` si l'élément est introuvable (pas de conv ouverte, app en fond,
    /// arbre pas encore construit, ou identifiant disparu).
    func currentConversationTitle() -> String? {
        guard let app = appElement() else { return nil }
        guard let button = findElement(byIdentifier: AXID.conversationTitle, in: app) else {
            return nil
        }
        let title = stringAttribute(button, kAXDescriptionAttribute as String)
        return (title?.isEmpty == false) ? title : nil
    }

    /// Élément AX localisé par identifiant depuis la racine de l'app, ou `nil`.
    /// Exposé pour les briques suivantes (composer, table de messages).
    func element(withIdentifier identifier: String) -> AXUIElement? {
        guard let app = appElement() else { return nil }
        return findElement(byIdentifier: identifier, in: app)
    }

    /// Élément actuellement focalisé DANS WhatsApp (pas au niveau système).
    /// Sert à l'intercepteur d'envoi : Return n'envoie un message que si le
    /// focus est dans le composer.
    func focusedElement() -> AXUIElement? {
        guard let app = appElement() else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        // Type vérifié ci-dessus : le cast ne peut pas échouer.
        return (value as! AXUIElement)
    }

    // MARK: - Lecture des bulles (brique 4)

    /// Direction d'une bulle, déduite du préfixe du label AX composé.
    enum BubbleDirection {
        case outgoing   // « Your message, … »
        case incoming   // « message, … »
        case unknown
    }

    /// Une bulle visible : sa direction + le label AX brut (déjà nettoyé des
    /// marqueurs bidi). L'extraction des jetons MC1. se fait en aval via
    /// `ManicryptMessageFormat.encryptedTokens(in:)`.
    struct VisibleBubble {
        let direction: BubbleDirection
        let rawLabel: String
    }

    /// Bulles actuellement rendues dans la table de messages, dans l'ordre de
    /// l'arbre (haut → bas). Liste virtualisée : seules les cellules visibles
    /// sont présentes. Suppose WhatsApp frontmost (arbre construit).
    func visibleBubbles() -> [VisibleBubble] {
        guard let app = appElement(),
              let table = findElement(byIdentifier: AXID.messagesTable, in: app) else {
            return []
        }
        var bubbles: [VisibleBubble] = []
        collectBubbles(in: table, into: &bubbles)
        return bubbles
    }

    private func collectBubbles(in element: AXUIElement, into bubbles: inout [VisibleBubble]) {
        if stringAttribute(element, "AXIdentifier") == AXID.bubble {
            let raw = stringAttribute(element, kAXDescriptionAttribute as String)
                ?? stringAttribute(element, kAXValueAttribute as String)
            if let raw = raw {
                let cleaned = Self.stripBidiMarks(raw)
                bubbles.append(VisibleBubble(direction: Self.direction(of: cleaned), rawLabel: cleaned))
            }
        }
        for child in childrenOf(element) {
            collectBubbles(in: child, into: &bubbles)
        }
    }

    /// Bulle visible localisée : mêmes infos que `VisibleBubble` + la frame ÉCRAN
    /// (coordonnées Cocoa, origine bas-gauche) de la cellule. Sert à l'overlay
    /// par-bulle (IMP-005). La frame est celle de la cellule pleine largeur ; la
    /// bulle réellement peinte est alignée à droite (sortant) ou à gauche
    /// (entrant) dans cette largeur.
    struct LocatedBubble {
        let direction: BubbleDirection
        let rawLabel: String
        let screenFrame: CGRect
    }

    /// Bulles visibles avec leur frame écran (haut → bas). WhatsApp frontmost.
    func visibleBubblesLocated() -> [LocatedBubble] {
        guard let app = appElement(),
              let table = findElement(byIdentifier: AXID.messagesTable, in: app) else {
            return []
        }
        var bubbles: [LocatedBubble] = []
        collectLocatedBubbles(in: table, into: &bubbles)
        return bubbles
    }

    private func collectLocatedBubbles(in element: AXUIElement, into bubbles: inout [LocatedBubble]) {
        if stringAttribute(element, "AXIdentifier") == AXID.bubble {
            let raw = stringAttribute(element, kAXDescriptionAttribute as String)
                ?? stringAttribute(element, kAXValueAttribute as String)
            if let raw = raw, let frame = screenFrame(of: element) {
                let cleaned = Self.stripBidiMarks(raw)
                bubbles.append(LocatedBubble(direction: Self.direction(of: cleaned),
                                             rawLabel: cleaned, screenFrame: frame))
            }
        }
        for child in childrenOf(element) {
            collectLocatedBubbles(in: child, into: &bubbles)
        }
    }

    /// Frame ÉCRAN (Cocoa, origine bas-gauche) d'un élément AX, ou `nil`.
    func screenFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef,
              CFGetTypeID(posValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: position.x,
                      y: primary.frame.maxY - position.y - size.height,
                      width: size.width, height: size.height)
    }

    /// Retire les marqueurs directionnels invisibles (LRM/RLM/isolats bidi) dont
    /// WhatsApp préfixe/entoure ses labels d'accessibilité.
    static func stripBidiMarks(_ text: String) -> String {
        let bidi: Set<Character> = ["\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}",
                                    "\u{202C}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"]
        return String(text.unicodeScalars.filter { !bidi.contains(Character($0)) })
    }

    private static func direction(of cleanedLabel: String) -> BubbleDirection {
        let trimmed = cleanedLabel.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Your message") { return .outgoing }
        if trimmed.hasPrefix("message") { return .incoming }
        return .unknown
    }

    // MARK: - Géométrie fenêtre (ancrage du panneau, brique 4)

    /// Rect ÉCRAN (coordonnées Cocoa, origine bas-gauche) de la fenêtre
    /// principale de WhatsApp, pour ancrer le panneau de lecture à son bord.
    /// `nil` si indisponible.
    func whatsAppWindowFrame() -> CGRect? {
        guard let app = appElement() else { return nil }
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &windowRef) != .success {
            // Repli : première fenêtre.
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement], let first = windows.first else {
                return nil
            }
            windowRef = first
        }
        guard let value = windowRef, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef,
              CFGetTypeID(posValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        // AX : origine haut-gauche de l'écran principal → Cocoa : bas-gauche.
        guard let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: position.x,
                      y: primary.frame.maxY - position.y - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: - Lecture avec activation (flux de liaison, brique 1)

    /// Lit le titre de la conversation active en amenant WhatsApp au premier
    /// plan si nécessaire (l'arbre AX n'existe pas en arrière-plan), en laissant
    /// l'arbre se stabiliser, puis rappelle sur le main thread.
    /// Ne déclenche PAS le prompt de permission : l'appelant décide.
    func readActiveConversationTitle(completion: @escaping (Result<String, ReaderError>) -> Void) {
        assert(Thread.isMainThread)

        guard AXIsProcessTrusted() else {
            completion(.failure(.accessibilityNotTrusted))
            return
        }
        guard let app = whatsAppApplication() else {
            completion(.failure(.appNotRunning))
            return
        }

        let readNow = { [weak self] in
            guard let self else { return }
            if let title = self.currentConversationTitle() {
                completion(.success(title))
            } else {
                completion(.failure(.titleUnavailable))
            }
        }

        if isWhatsAppFrontmost() {
            readNow()
        } else {
            app.activate(options: [])
            // Sonder l'arbre jusqu'à ce que le titre soit lisible (réactif),
            // plafonné pour ne pas boucler si aucune conv n'est ouverte.
            pollTitleUntilReadable(deadline: Date().addingTimeInterval(maxReadinessWait),
                                   completion: completion)
        }
    }

    /// Rappelle `completion` dès que le titre devient lisible, ou en échec au
    /// plafond (aucune conversation ouverte / arbre indisponible).
    private func pollTitleUntilReadable(deadline: Date,
                                        completion: @escaping (Result<String, ReaderError>) -> Void) {
        if let title = currentConversationTitle() {
            completion(.success(title))
        } else if Date() >= deadline {
            completion(.failure(.titleUnavailable))
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + readinessPollStep) { [weak self] in
                self?.pollTitleUntilReadable(deadline: deadline, completion: completion)
            }
        }
    }

    // MARK: - Primitives AX

    private func appElement() -> AXUIElement? {
        guard let app = whatsAppApplication() else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    /// Recherche en profondeur du premier élément portant l'AXIdentifier donné.
    /// Budget borné : un arbre anormalement grand ne bloque jamais l'app.
    private func findElement(byIdentifier identifier: String, in root: AXUIElement) -> AXUIElement? {
        var budget = walkBudget
        return findElement(byIdentifier: identifier, in: root, budget: &budget)
    }

    private func findElement(byIdentifier identifier: String,
                             in element: AXUIElement,
                             budget: inout Int) -> AXUIElement? {
        guard budget > 0 else { return nil }
        budget -= 1

        if stringAttribute(element, "AXIdentifier") == identifier {
            return element
        }
        for child in childrenOf(element) {
            if let hit = findElement(byIdentifier: identifier, in: child, budget: &budget) {
                return hit
            }
        }
        return nil
    }

    func childrenOf(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let children = ref as? [AXUIElement] else {
            return []
        }
        return children
    }

    func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }
}
