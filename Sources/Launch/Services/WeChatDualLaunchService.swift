import Foundation

enum WeChatDualLaunchPolicy {
    static let primaryBundleIdentifier = "com.tencent.xinWeChat"
    static let companionBundleIdentifier = "com.tencent.xinWeChat2"

    static func isPrimaryBundleIdentifier(_ identifier: String?) -> Bool {
        identifier == primaryBundleIdentifier
    }

    static func isCompanionBundleIdentifier(_ identifier: String?) -> Bool {
        identifier == companionBundleIdentifier
    }

}
