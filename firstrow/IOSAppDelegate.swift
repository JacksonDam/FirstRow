#if os(iOS) || os(tvOS)
    import UIKit

    final class IOSAppDelegate: UIResponder, UIApplicationDelegate {
        var window: UIWindow?

        func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.backgroundColor = .black
            window.rootViewController = FirstRowViewController()
            window.makeKeyAndVisible()
            self.window = window
            return true
        }

        #if os(iOS)
            func application(_: UIApplication, supportedInterfaceOrientationsFor _: UIWindow?) -> UIInterfaceOrientationMask {
                .landscape
            }
        #endif
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
