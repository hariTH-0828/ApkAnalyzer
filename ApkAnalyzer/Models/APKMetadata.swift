import Foundation
import UIKit

struct APKMetadata {
    // App Information
    let appName: String
    let packageName: String
    let versionName: String
    let versionCode: String
    let minSDK: String
    let targetSDK: String
    let deviceCompatibility: [String]

    // Features and Permissions
    let permissions: [String]
    let usesFeatures: [String]
    let notRequiredFeatures: [String]

    // Signature
    let signer: String
    let v1SchemeVerified: String

    // Icon
    let iconPath: String?
    var icon: UIImage?
}
