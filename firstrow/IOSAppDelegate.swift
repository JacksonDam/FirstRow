#if os(iOS) || os(tvOS)
    import AVFoundation
    import UIKit

    /// Scene-based, since iOS and tvOS 27 won't launch apps without the scene life cycle.
    final class IOSAppDelegate: UIResponder, UIApplicationDelegate {
        func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
            #if os(tvOS)
                // Mix with other audio, or each interface sound stops the Apple Music player.
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            #endif
            return true
        }

        func application(_: UIApplication, configurationForConnecting session: UISceneSession, options _: UIScene.ConnectionOptions) -> UISceneConfiguration {
            let configuration = UISceneConfiguration(name: "Default", sessionRole: session.role)
            configuration.delegateClass = FirstRowSceneDelegate.self
            return configuration
        }

        #if os(iOS)
            func application(_: UIApplication, supportedInterfaceOrientationsFor _: UIWindow?) -> UIInterfaceOrientationMask {
                // Upright only on a half-folded foldable (the view controller says when).
                .all
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

    /// Hosts First Row full screen or, on a foldable half folded and held upright, on the half
    /// above the fold.
    final class FirstRowViewController: UIViewController {
        private let appController = FirstRowAppController()
        private var didStart = false
        #if os(iOS)
            /// Folded part way, so it can stand upright with First Row on the top half.
            private var isHalfFolded = false
        #endif

        /// What First Row draws in.
        var drawingView: UIView { appController.hostView }

        override func loadView() {
            #if os(iOS)
                let container = UIView()
                container.backgroundColor = .black
                container.addSubview(appController.hostView)
                view = container
                #if compiler(>=6.4)
                    if #available(iOS 27.1, *) {
                        container.addInteraction(UIHingeInteraction { [weak self] _, update in
                            self?.hingeChanged(halfFolded: update.hinge?.status == .partiallyOpen)
                        })
                    }
                #endif
            #else
                view = appController.hostView
            #endif
        }

        #if os(iOS)
            override func viewDidLayoutSubviews() {
                super.viewDidLayoutSubviews()
                let frame = drawingFrame
                if appController.hostView.frame != frame { appController.hostView.frame = frame }
            }

            /// All of the screen, or the part above the fold when the fold goes across it.
            private var drawingFrame: CGRect {
                let bounds = view.bounds
                #if compiler(>=6.4)
                    if #available(iOS 27.1, *),
                       let fold = view.reservedRegions(kind: .division).first(where: { $0.isActive && $0.frame.width > $0.frame.height }),
                       fold.frame.minY > bounds.height / 4
                    {
                        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: fold.frame.minY - bounds.minY)
                    }
                #endif
                return bounds
            }

            private func hingeChanged(halfFolded: Bool) {
                view.setNeedsLayout()
                guard halfFolded != isHalfFolded else { return }
                isHalfFolded = halfFolded
                if #available(iOS 16.0, *) {
                    setNeedsUpdateOfSupportedInterfaceOrientations()
                } else {
                    UIViewController.attemptRotationToDeviceOrientation()
                }
            }
        #endif

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !didStart else { return }
            didStart = true
            appController.start()
        }

        #if os(iOS)
            override var prefersStatusBarHidden: Bool { true }
            override var prefersHomeIndicatorAutoHidden: Bool { true }
            override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
                isHalfFolded ? .all : .landscape
            }
        #endif
    }
#endif
