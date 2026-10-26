import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Library.shared.importFromDocumentsFolder()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var root: RootViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let root = RootViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        self.root = root
        if !connectionOptions.urlContexts.isEmpty { handle(connectionOptions.urlContexts) }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handle(URLContexts)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        Library.shared.importFromDocumentsFolder()
    }

    private func handle(_ contexts: Set<UIOpenURLContext>) {
        let urls = contexts.map(\.url).filter { $0.isFileURL }
        guard !urls.isEmpty else { return }
        // Opened-in-place documents are only readable inside this window.
        let accessed = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        root?.importAndOpen(urls)
        for (url, ok) in accessed where ok { url.stopAccessingSecurityScopedResource() }
    }
}
