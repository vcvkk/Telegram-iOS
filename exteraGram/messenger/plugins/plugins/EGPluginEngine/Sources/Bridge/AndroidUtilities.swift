import Foundation
import UIKit

@objc public final class AndroidUtilities: NSObject {
    @objc public static func runOnUIThread(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    @objc public static func runOnUIThread(_ block: @escaping () -> Void, delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000.0, execute: block)
    }

    @objc public static func dp(_ value: Float) -> CGFloat {
        return CGFloat(value)
    }

    @objc public static func displaySize() -> CGSize {
        return UIScreen.main.bounds.size
    }
}
