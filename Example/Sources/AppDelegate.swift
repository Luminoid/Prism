import PrismCore
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // The Example is a "what's happening under the hood" surface, so Prism's debug lines
        // (every configure, start, switch, setter, format swap and capture entry) are on.
        // Apps keep the default `.info`; errors and faults are written at any threshold.
        PRMLog.minimumLevel = .debug
        return true
    }
}
