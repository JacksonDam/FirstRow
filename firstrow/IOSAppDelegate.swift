#if os(iOS) || os(tvOS)
    import UIKit

    /// Scene-based, since iOS and tvOS 27 won't launch apps without the scene life cycle.
    final class IOSAppDelegate: UIResponder, UIApplicationDelegate {
        func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
            true
        }

        func application(_: UIApplication, configurationForConnecting session: UISceneSession, options _: UIScene.ConnectionOptions) -> UISceneConfiguration {
            let configuration = UISceneConfiguration(name: "Default", sessionRole: session.role)
            configuration.delegateClass = FirstRowSceneDelegate.self
            return configuration
        }

        #if os(iOS)
            func application(_: UIApplication, supportedInterfaceOrientationsFor _: UIWindow?) -> UIInterfaceOrientationMask {
                .landscape
            }
        #endif
    }

    /// Puts First Row's window on the scene.
    final class FirstRowSceneDelegate: UIResponder, UIWindowSceneDelegate {
        var window: UIWindow?

        func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
            guard let windowScene = scene as? UIWindowScene else { return }
            let window = UIWindow(windowScene: windowScene)
            window.backgroundColor = .black
            window.rootViewController = FirstRowViewController()
            window.makeKeyAndVisible()
            self.window = window
        }
    }

    /// Hosts First Row full screen.
    final class FirstRowViewController: UIViewController {
        private let appController = FirstRowAppController()
        private var didStart = false

        override func loadView() {
            view = appController.hostView
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !didStart else { return }
            didStart = true
            appController.start()
        }

        #if os(iOS)
            override var prefersStatusBarHidden: Bool { true }
            override var prefersHomeIndicatorAutoHidden: Bool { true }
            override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
        #endif
    }
#endif
