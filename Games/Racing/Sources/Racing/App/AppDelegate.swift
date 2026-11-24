import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {}

final class AppSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var audio: GameAudio?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        if TrackVideoRecorder.runFromLaunchArguments() {
            window.rootViewController = UIViewController()
        } else {
            audio = .shared
            window.rootViewController = MenuNavigationController(rootViewController: MenuViewController())
        }
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) { audio?.setSceneActive(true) }
    func sceneWillResignActive(_ scene: UIScene) { audio?.setSceneActive(false) }
}

/// Menus push and pop with the system slide; the bar is hidden because every screen draws
/// its own header, and the edge swipe still goes back.
final class MenuNavigationController: UINavigationController, UIGestureRecognizerDelegate {
    override func viewDidLoad() {
        super.viewDidLoad()
        setNavigationBarHidden(true, animated: false)
        interactivePopGestureRecognizer?.delegate = self
        overrideUserInterfaceStyle = .dark
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { viewControllers.count > 1 }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var childForStatusBarHidden: UIViewController? { topViewController }
}
