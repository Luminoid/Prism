import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let root = RootCatalogViewController()
        let nav = UINavigationController(rootViewController: root)
        nav.navigationBar.prefersLargeTitles = true
        // The whole app is dark (`UIUserInterfaceStyle` in Info.plist): a camera UI over a
        // live preview.
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window
    }
}
