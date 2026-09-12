import Foundation

private struct TouchIdentityCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private final class SemanticTouchIdentity: NSObject {
    let token: String

    init(token: String) {
        self.token = token
    }

    override var hash: Int {
        token.hashValue
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? SemanticTouchIdentity)?.token == token
    }
}

@main
private enum TouchIdentityChecks {
    static func main() throws {
        let original = StableTouchIdentityKey(
            SemanticTouchIdentity(token: "same-contact")
        )
        let equivalentWrapper = StableTouchIdentityKey(
            SemanticTouchIdentity(token: "same-contact")
        )
        let differentContact = StableTouchIdentityKey(
            SemanticTouchIdentity(token: "different-contact")
        )
        let stableIDs = [original: 42]
        guard original == equivalentWrapper,
              stableIDs[equivalentWrapper] == 42,
              original != differentContact,
              stableIDs[differentContact] == nil else {
            throw TouchIdentityCheckFailure(
                description: "Touch identity did not preserve protocol equality and hashing"
            )
        }
        print("Launch touch-identity checks passed (1/1)")
    }
}
