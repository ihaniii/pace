//
//  QAXSecureTextElementPolicyTests.swift
//  leanring-buddyTests
//
//  Decision table for QAXSecureTextElementPolicy.classify(role:subrole:containsProtectedContent:).
//  Pure policy — no Accessibility calls. The real-element classification (a genuine
//  NSSecureTextField reporting role AXTextField + subrole AXSecureTextField) is covered
//  cross-process in QSecureTextFieldProtectionTests.
//

import ApplicationServices
import Testing
@testable import Pace

@Suite("QAXSecureTextElementPolicyTests")
struct QAXSecureTextElementPolicyTests {

    private let textFieldRole = QAXAttributeObservation.string("AXTextField")
    private let secureSubrole = QAXAttributeObservation.string("AXSecureTextField")

    private func failedRead(_ axError: AXError) -> QAXAttributeObservation {
        .readFailed(axErrorCode: axError.rawValue)
    }

    // MARK: - Secure evidence

    @Test("The real macOS password-field representation (role AXTextField, subrole AXSecureTextField) is secure")
    func secureSubroleIsSecure() {
        #expect(QAXSecureTextElementPolicy.classify(role: textFieldRole, subrole: secureSubrole, containsProtectedContent: .absent) == .secure)
    }

    @Test("An element reporting AXSecureTextField as its ROLE (legacy/custom representation) is secure")
    func secureRoleIsSecure() {
        #expect(QAXSecureTextElementPolicy.classify(role: .string("AXSecureTextField"), subrole: .absent, containsProtectedContent: .absent) == .secure)
    }

    @Test("Positive secure evidence wins even when another attribute could not be read")
    func secureEvidenceIsNeverDowngradedByAFailedRead() {
        #expect(QAXSecureTextElementPolicy.classify(role: failedRead(.cannotComplete), subrole: secureSubrole, containsProtectedContent: .absent) == .secure)
        #expect(QAXSecureTextElementPolicy.classify(role: textFieldRole, subrole: secureSubrole, containsProtectedContent: failedRead(.failure)) == .secure)
        #expect(QAXSecureTextElementPolicy.classify(role: .string("AXSecureTextField"), subrole: failedRead(.invalidUIElement), containsProtectedContent: .malformed) == .secure)
    }

    // MARK: - Known non-secure representations

    @Test("A plain text field (no subrole: kAXErrorAttributeUnsupported/kAXErrorNoValue) is not secure")
    func plainTextFieldIsNotSecure() {
        #expect(QAXSecureTextElementPolicy.classify(role: textFieldRole, subrole: .absent, containsProtectedContent: .absent) == .notSecure)
    }

    @Test("A search field (subrole AXSearchField) is not secure")
    func searchFieldIsNotSecure() {
        #expect(QAXSecureTextElementPolicy.classify(role: textFieldRole, subrole: .string("AXSearchField"), containsProtectedContent: .absent) == .notSecure)
    }

    // MARK: - Indeterminate (never fails open)

    @Test("A non-string subrole or role is indeterminate, never not-secure")
    func malformedAttributesAreIndeterminate() {
        #expect(QAXSecureTextElementPolicy.classify(role: textFieldRole, subrole: .malformed, containsProtectedContent: .absent) == .indeterminate)
        #expect(QAXSecureTextElementPolicy.classify(role: textFieldRole, subrole: .boolean(true), containsProtectedContent: .absent) == .indeterminate)
        #expect(QAXSecureTextElementPolicy.classify(role: .malformed, subrole: .absent, containsProtectedContent: .absent) == .indeterminate)
    }

    @Test("A subrole that cannot be read because of an AX API error is indeterminate", arguments: [
        AXError.cannotComplete, AXError.invalidUIElement, AXError.failure, AXError.notImplemented, AXError.apiDisabled
    ])
    func subroleReadErrorIsIndeterminate(axError: AXError) {
        #expect(QAXSecureTextElementPolicy.classify(role: textFieldRole, subrole: failedRead(axError), containsProtectedContent: .absent) == .indeterminate)
    }

    @Test("A role that cannot be read, or is genuinely absent, is indeterminate", arguments: [
        QAXAttributeObservation.readFailed(axErrorCode: AXError.cannotComplete.rawValue),
        QAXAttributeObservation.readFailed(axErrorCode: AXError.invalidUIElement.rawValue),
        QAXAttributeObservation.absent
    ])
    func roleReadFailureIsIndeterminate(role: QAXAttributeObservation) {
        #expect(QAXSecureTextElementPolicy.classify(role: role, subrole: .absent, containsProtectedContent: .absent) == .indeterminate)
    }

    // MARK: - AXContainsProtectedContent

    @Test("AXContainsProtectedContent == true makes an otherwise plain element secure")
    func protectedContentTrueIsSecure() {
        #expect(QAXSecureTextElementPolicy.classify(role: textFieldRole, subrole: .absent, containsProtectedContent: .boolean(true)) == .secure)
    }

    @Test("AXContainsProtectedContent == false never overrides the secure-text subrole")
    func protectedContentFalseDoesNotOverrideSecureSubrole() {
        #expect(QAXSecureTextElementPolicy.classify(role: textFieldRole, subrole: secureSubrole, containsProtectedContent: .boolean(false)) == .secure)
        #expect(QAXSecureTextElementPolicy.classify(role: textFieldRole, subrole: .absent, containsProtectedContent: .boolean(false)) == .notSecure)
    }

    @Test("An absent AXContainsProtectedContent leaves the decision to role/subrole — absence never proves an element is not secure")
    func protectedContentAbsentDefersToRoleAndSubrole() {
        #expect(QAXSecureTextElementPolicy.classify(role: textFieldRole, subrole: secureSubrole, containsProtectedContent: .absent) == .secure)
        #expect(QAXSecureTextElementPolicy.classify(role: textFieldRole, subrole: .absent, containsProtectedContent: .absent) == .notSecure)
    }

    @Test("An unreadable or malformed AXContainsProtectedContent never fails open")
    func protectedContentReadFailureIsIndeterminate() {
        #expect(QAXSecureTextElementPolicy.classify(role: textFieldRole, subrole: .absent, containsProtectedContent: failedRead(.cannotComplete)) == .indeterminate)
        #expect(QAXSecureTextElementPolicy.classify(role: textFieldRole, subrole: .absent, containsProtectedContent: .malformed) == .indeterminate)
        #expect(QAXSecureTextElementPolicy.classify(role: textFieldRole, subrole: .absent, containsProtectedContent: .string("yes")) == .indeterminate)
    }

    // MARK: - Denial labels

    @Test("Denial labels name only the protected representation — never a value, length, or selection")
    func denialLabels() {
        #expect(QAXSecureTextElementPolicy.denialLabel(for: .secure) == "AXSecureTextField")
        #expect(QAXSecureTextElementPolicy.denialLabel(for: .indeterminate) == "AXSecureTextField (unverified)")
        #expect(QAXInteractionError.secureFieldReadDenied(QAXSecureTextElementPolicy.denialLabel(for: .secure)) == .secureFieldReadDenied("AXSecureTextField"))
    }
}
