import Foundation

/// Hashes NSTouch's documented NSObjectProtocol identity without assuming that
/// the implementation subclasses NSObject. NSProxy-style identities are valid:
/// equality and hashing are delegated to the protocol contract itself.
struct StableTouchIdentityKey: Hashable {
    private let value: any NSObjectProtocol

    init(_ value: any NSObjectProtocol) {
        self.value = value
    }

    static func == (
        lhs: StableTouchIdentityKey,
        rhs: StableTouchIdentityKey
    ) -> Bool {
        lhs.value.isEqual(rhs.value)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(value.hash)
    }
}
