//
//  QAXSecureTextElementPolicy.swift
//  leanring-buddy
//
//  Secure-text (password) classification of an ACTUAL Accessibility element.
//
//  A real macOS password field (AppKit NSSecureTextField, SwiftUI SecureField, and WebKit
//  <input type=password> alike) reports kAXRoleAttribute == "AXTextField" and
//  kAXSubroleAttribute == "AXSecureTextField" (kAXSecureTextFieldSubrole — the SDK defines
//  AXSecureTextField only as a SUBROLE). A request for role "AXTextField" therefore resolves to
//  password fields too, so the role a caller asked for can never decide whether the resolved
//  element is secure. This policy classifies the element itself, from its own attributes.
//
//  macOS masks a secure field's AXValue, but the mask has exactly the password's length, and
//  AXSelectedTextRange / AXNumberOfCharacters can expose that length as well. Q therefore
//  enforces the boundary itself instead of relying on what macOS happens to return.
//

import ApplicationServices
import Foundation

/// What one Accessibility attribute read produced, reduced to the distinctions secure-text
/// classification needs. Mirrors the absence-vs-failure discipline of the existing
/// AXRequired/AXContainsProtectedContent reads: kAXErrorNoValue / kAXErrorAttributeUnsupported
/// are genuine absence, every other AXError is a failed read.
nonisolated public enum QAXAttributeObservation: Equatable, Sendable {
    case string(String)
    case boolean(Bool)
    /// kAXErrorNoValue or kAXErrorAttributeUnsupported: the element genuinely has no such attribute.
    case absent
    /// The read succeeded but returned a value of an unexpected type.
    case malformed
    /// Any other AXError (for example kAXErrorCannotComplete or kAXErrorInvalidUIElement).
    case readFailed(axErrorCode: Int32)
}

/// Whether an actual Accessibility element is a secure-text (password) element.
nonisolated public enum QAXSecureTextClassification: Equatable, Sendable {
    case secure
    case notSecure
    /// The element's secure-text status could not be established. Security-sensitive paths must
    /// treat this exactly like `.secure` — never as "not secure".
    case indeterminate
}

nonisolated public enum QAXSecureTextElementPolicy {
    /// kAXSecureTextFieldSubrole. Also honored when an element reports it as its ROLE, the
    /// representation custom elements and the existing literal-role coverage use.
    public static let secureTextFieldIdentifier = "AXSecureTextField"

    /// NSAccessibilityContainsProtectedContentAttribute (macOS 10.9+). It has no HIServices C
    /// constant, so the wire-format string is used, as QBridgeAdapters already does. Apps opt in
    /// through NSAccessibilitySetMayContainProtectedContent, and standard password fields do not
    /// expose it, so it is only ever an ADDITIONAL secure signal: `true` makes an element secure,
    /// while `false` or absence never overrides the secure-text subrole.
    public static let containsProtectedContentAttributeName = "AXContainsProtectedContent"

    /// The only target label a denial may carry for a secure element. It names the protected
    /// representation and never includes the element's value, length, or selection.
    public static let secureTargetDenialLabel = "AXSecureTextField"

    /// The target label a denial carries when secure-text status could not be established.
    public static let indeterminateTargetDenialLabel = "AXSecureTextField (unverified)"

    /// Decides the classification from already-observed attributes. Order matters: any positive
    /// secure evidence wins first, so a failed read of some OTHER attribute can never downgrade a
    /// field that already proved itself secure. Only when no secure evidence exists does an
    /// unreadable or malformed attribute make the result indeterminate rather than "not secure".
    public static func classify(
        role: QAXAttributeObservation,
        subrole: QAXAttributeObservation,
        containsProtectedContent: QAXAttributeObservation
    ) -> QAXSecureTextClassification {
        if role == .string(secureTextFieldIdentifier) || subrole == .string(secureTextFieldIdentifier) {
            return .secure
        }
        if containsProtectedContent == .boolean(true) {
            return .secure
        }

        // Every Accessibility element has a role; without a readable one nothing can be decided.
        guard case .string = role else {
            return .indeterminate
        }

        // A plain text field genuinely has no subrole (kAXErrorAttributeUnsupported, observed
        // cross-process); any other string (e.g. AXSearchField) is a known non-secure subrole.
        switch subrole {
        case .string, .absent:
            break
        case .boolean, .malformed, .readFailed:
            return .indeterminate
        }

        switch containsProtectedContent {
        case .boolean(false), .absent:
            break
        case .boolean(true):
            return .secure
        case .string, .malformed, .readFailed:
            return .indeterminate
        }

        return .notSecure
    }

    /// Classifies an actual Accessibility element from its own role, subrole, and
    /// protected-content attributes.
    public static func classify(element: AXUIElement) -> QAXSecureTextClassification {
        classify(
            role: observeStringAttribute(kAXRoleAttribute, of: element),
            subrole: observeStringAttribute(kAXSubroleAttribute, of: element),
            containsProtectedContent: observeBooleanAttribute(containsProtectedContentAttributeName, of: element)
        )
    }

    /// Same as `classify(element:)` for an element whose role the caller has already read (the
    /// screen reader's hot walk), saving one Accessibility call per element.
    public static func classify(element: AXUIElement, knownRole: String) -> QAXSecureTextClassification {
        classify(
            role: .string(knownRole),
            subrole: observeStringAttribute(kAXSubroleAttribute, of: element),
            containsProtectedContent: observeBooleanAttribute(containsProtectedContentAttributeName, of: element)
        )
    }

    /// Classifies from role and subrole only, deliberately ignoring AXContainsProtectedContent.
    /// Used solely by `ui.read_element_protected_content_state`, whose whole purpose is to REPORT
    /// that flag (a boolean, never content): treating a `true` flag as a refusal would leave it
    /// unable to ever report `true`. A real password field is still refused through its subrole.
    public static func classifySecureTextRepresentation(element: AXUIElement) -> QAXSecureTextClassification {
        classify(
            role: observeStringAttribute(kAXRoleAttribute, of: element),
            subrole: observeStringAttribute(kAXSubroleAttribute, of: element),
            containsProtectedContent: .absent
        )
    }

    /// The denial label for a classification that is not `.notSecure`.
    public static func denialLabel(for classification: QAXSecureTextClassification) -> String {
        classification == .indeterminate ? indeterminateTargetDenialLabel : secureTargetDenialLabel
    }

    static func observeStringAttribute(_ attributeName: String, of element: AXUIElement) -> QAXAttributeObservation {
        var value: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(element, attributeName as CFString, &value)
        switch copyResult {
        case .success:
            guard let stringValue = value as? String else { return .malformed }
            return .string(stringValue)
        case .noValue, .attributeUnsupported:
            return .absent
        default:
            return .readFailed(axErrorCode: copyResult.rawValue)
        }
    }

    static func observeBooleanAttribute(_ attributeName: String, of element: AXUIElement) -> QAXAttributeObservation {
        var value: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(element, attributeName as CFString, &value)
        switch copyResult {
        case .success:
            guard let booleanValue = value as? Bool else { return .malformed }
            return .boolean(booleanValue)
        case .noValue, .attributeUnsupported:
            return .absent
        default:
            return .readFailed(axErrorCode: copyResult.rawValue)
        }
    }
}
