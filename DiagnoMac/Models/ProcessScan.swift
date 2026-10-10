import DiagnoCore
import Foundation

/// A running program the security scan thinks is worth a look.
struct SuspiciousProcess: Identifiable, Sendable {
    let facts: ProcessFacts
    let assessment: ProcessAssessment
    /// Started by you rather than by the system, so DiagnoMac can stop it without asking for a password.
    let ownedByYou: Bool

    var id: String { "\(facts.pid):\(facts.path)" }
    var concern: ProcessConcern { assessment.concern }
    var severity: Severity { concern == .suspicious ? .critical : .warning }
    var name: String { facts.name }
    var path: String { facts.path }

    /// How the signature reads in a sentence.
    var signedBy: String {
        switch facts.trust {
        case .apple: "Apple"
        case .appStore: "the Mac App Store"
        case .developerID(let team): team.map { "a registered developer (\($0))" } ?? "a registered developer"
        case .otherCertificate: "a developer's own certificate"
        case .adHoc: "nobody (self-made signature)"
        case .unsigned: "nobody"
        case .invalid: "nobody (the signature is broken)"
        }
    }
}

struct ProcessScanResult: Sendable {
    var scannedAt: Date
    /// Programs looked at.
    var checked: Int
    var fromApple: Int
    var fromDevelopers: Int
    var flagged: [SuspiciousProcess]
    /// Programs skipped because you said they're fine.
    var trustedByYou: Int

    var suspicious: [SuspiciousProcess] { flagged.filter { $0.concern == .suspicious } }
    var worthChecking: [SuspiciousProcess] { flagged.filter { $0.concern == .worthChecking } }
}
