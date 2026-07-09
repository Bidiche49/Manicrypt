//
//  FocusContextDetector.swift
//  Manicrypt
//
//  Détection, via l'Accessibility API, du contexte de la sélection au moment
//  d'un raccourci (FEAT-001 v3) : la cible focusée est-elle un champ texte
//  ÉDITABLE (→ remplacement in-place possible) ou non ?
//
//  Règle STRICTE : au moindre doute (échec AX, rôle inattendu, valeur non
//  modifiable, app opaque type Electron) → `.nonEditable`. On ne colle jamais
//  (⌘V) à l'aveugle dans une cible dont on n'a pas prouvé l'éditabilité.
//

import Cocoa
import ApplicationServices

enum FocusContext {
    /// Champ texte prouvé éditable : remplacement in-place autorisé.
    case editable
    /// Tout le reste (zone lecture seule, indéterminé, échec AX).
    case nonEditable
}

final class FocusContextDetector {
    static let shared = FocusContextDetector()
    private init() {}

    /// Rôles considérés comme candidats à l'édition. La confirmation vient
    /// ensuite de l'éditabilité réelle de l'attribut valeur.
    private let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String
    ]

    /// Détermine le contexte de l'élément focusé au niveau système.
    /// N'a de sens que si la permission Accessibilité est accordée (déjà requise
    /// par les raccourcis globaux).
    func currentContext() -> FocusContext {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusStatus == .success, let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return .nonEditable
        }
        // Type vérifié ci-dessus : le cast ne peut pas échouer (pas de crash).
        let element = focused as! AXUIElement

        // 1) Rôle texte ?
        guard let role = copyStringAttribute(element, kAXRoleAttribute),
              editableRoles.contains(role) else {
            return .nonEditable
        }

        // 2) L'attribut valeur est-il réellement modifiable ? C'est le signal le
        //    plus fiable de « je peux écrire ici » : un AXTextArea en lecture
        //    seule (page web, mail reçu) renverra false.
        var settable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        guard settableStatus == .success, settable.boolValue else {
            return .nonEditable
        }

        return .editable
    }

    // MARK: - Utilitaire

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var valueRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef)
        guard status == .success else { return nil }
        return valueRef as? String
    }
}
