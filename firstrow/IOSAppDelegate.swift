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
                // Upright only on a foldable (the view controller says when).
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

    /// Hosts First Row full screen. A foldable can also stand upright, and First Row keeps its
    /// landscape shape on it: across the middle, or on the half above the fold when it's half
    /// folded.
    final class FirstRowViewController: UIViewController {
        private let appController = FirstRowAppController()
        private var didStart = false
        #if os(iOS)
            /// A screen that folds, so held upright it turns upright too (but not closed, on the
            /// outside screen, which is like any iPhone's).
            private var isFoldable = false
            private var isClosed = false
            /// Folded part way: held upright, First Row goes on the half above the fold.
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
                            self?.hingeChanged(
                                hasHinge: update.hinge != nil,
                                closed: update.hinge?.status == .closed,
                                halfFolded: update.hinge?.status == .partiallyOpen,
                            )
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

            /// All of the screen held sideways. Upright, First Row keeps its landscape shape: on
            /// the part above the fold when half folded, otherwise across the middle, with black
            /// above and below.
            private var drawingFrame: CGRect {
                let bounds = view.bounds
                guard bounds.height > bounds.width else { return bounds }
                #if compiler(>=6.4)
                    if #available(iOS 27.1, *), isHalfFolded,
                       let fold = view.reservedRegions(kind: .division, options: .includeInactive).first(where: { $0.frame.width > $0.frame.height }),
                       fold.frame.minY > bounds.height / 4
                    {
                        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: fold.frame.minY - bounds.minY)
                    }
                #endif
                // As wide as it is upright, and as tall as the screen's sideways shape makes that.
                let screen = view.window?.windowScene?.screen.bounds.size ?? bounds.size
                let shape = min(screen.width, screen.height) / max(screen.width, screen.height)
                let height = (bounds.width * shape).rounded()
                return CGRect(x: bounds.minX, y: (bounds.midY - height / 2).rounded(), width: bounds.width, height: height)
            }

            private func hingeChanged(hasHinge: Bool, closed: Bool, halfFolded: Bool) {
                if hasHinge != isFoldable || closed != isClosed {
                    isFoldable = hasHinge
                    isClosed = closed
                    if #available(iOS 16.0, *) {
                        setNeedsUpdateOfSupportedInterfaceOrientations()
                    } else {
                        UIViewController.attemptRotationToDeviceOrientation()
                    }
                }
                guard halfFolded != isHalfFolded else {
                    view.setNeedsLayout()
                    return
                }
                isHalfFolded = halfFolded
                // Upright, it moves between the middle and the top half.
                UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
                    self.view.setNeedsLayout()
                    self.view.layoutIfNeeded()
                }
            }
        #endif

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            #if os(iOS)
                // A hinge found before it was on screen can't have turned it yet.
                if isFoldable, #available(iOS 16.0, *) { setNeedsUpdateOfSupportedInterfaceOrientations() }
            #endif
            guard !didStart else { return }
            didStart = true
            appController.start()
        }

        #if os(iOS)
            override var prefersStatusBarHidden: Bool { true }
            override var prefersHomeIndicatorAutoHidden: Bool { true }
            override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
                // An open foldable turns upright, keeping its landscape shape there (held upside
                // down it stays as it is, as on any iPhone). Closed, it's sideways as ever.
                isFoldable && !isClosed ? .allButUpsideDown : .landscape
            }
        #endif
    }
#endif
