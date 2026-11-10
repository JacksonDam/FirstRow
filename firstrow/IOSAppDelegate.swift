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
            let controller = FirstRowViewController()
            #if os(iOS)
                // Before it goes on screen, so it comes up the right way round on a foldable.
                controller.watchHinge(of: window)
            #endif
            window.rootViewController = controller
            window.makeKeyAndVisible()
            self.window = window
        }
    }

    /// Hosts First Row full screen. A foldable can also stand upright, where First Row lays itself
    /// out for the two halves: the show above the fold and the menu below it.
    final class FirstRowViewController: UIViewController {
        private let appController = FirstRowAppController()
        private var didStart = false
        #if os(iOS)
            /// A screen that folds, so held upright it turns upright too (but not closed, on the
            /// outside screen, which is like any iPhone's).
            private var isFoldable = false
            private var isClosed = false
            /// The stance the scene was last laid out for.
            private var stance: UprightStance?
        #endif

        /// What First Row draws in.
        var drawingView: UIView { appController.hostView }

        override func loadView() {
            #if os(iOS)
                let container = UIView()
                container.backgroundColor = .black
                // What waits off the edge of the screen stays out of sight while it turns.
                container.clipsToBounds = true
                container.addSubview(appController.hostView)
                view = container
            #else
                view = appController.hostView
            #endif
        }

        #if os(iOS)
            /// Follows the fold of the screen the window is on, where it has one.
            func watchHinge(of window: UIWindow) {
                #if compiler(>=6.4)
                    if #available(iOS 27.1, *) {
                        // The hinge reports once the window is up, after the system has asked
                        // which ways round it can go. Until then: no iPhone's screen is this
                        // large across unless it has unfolded.
                        isFoldable = UIDevice.current.userInterfaceIdiom == .phone && min(window.bounds.width, window.bounds.height) >= 600
                        window.addInteraction(UIHingeInteraction { [weak self] _, update in
                            self?.hingeChanged(hasHinge: update.hinge != nil, closed: update.hinge?.status == .closed)
                        })
                    }
                #endif
            }

            override func viewDidLayoutSubviews() {
                super.viewDidLayoutSubviews()
                let host = appController.hostView
                let frame = view.bounds
                let stance = uprightStance
                guard host.frame != frame || stance != self.stance else { return }
                host.frame = frame
                // Turning or folding, the system moves the view over a moment: the scene takes
                // that long, on the same curve, to reach its new arrangement.
                var glide: GlideTiming?
                if didStart, UIView.inheritedAnimationDuration > 0 {
                    glide = GlideTiming(matching: host.layer.animation(forKey: "bounds.size") ?? host.layer.animation(forKey: "position"))
                        ?? .easeInOut(duration: UIView.inheritedAnimationDuration)
                }
                self.stance = stance
                appController.relayout(upright: stance, glide: glide)
            }

            override func viewSafeAreaInsetsDidChange() {
                super.viewSafeAreaInsetsDidChange()
                view.setNeedsLayout()
            }

            /// Open and held upright, what the scene has to work with: the screen's shape, the
            /// strip the fold takes and the room the system keeps at the ends. Nil any other way.
            private var uprightStance: UprightStance? {
                let bounds = view.bounds
                guard isFoldable, !isClosed, bounds.height > bounds.width else { return nil }
                var fold: ClosedRange<CGFloat>?
                #if compiler(>=6.4)
                    if #available(iOS 27.1, *),
                       let region = view.reservedRegions(kind: .division, options: .includeInactive).first(where: { $0.frame.width > $0.frame.height }),
                       region.frame.minY > bounds.height / 4, region.frame.maxY < bounds.height * 3 / 4
                    {
                        fold = region.frame.minY ... region.frame.maxY
                    }
                #endif
                let insets = view.safeAreaInsets
                return UprightStance(screenSize: bounds.size, fold: fold, safeTop: insets.top, safeBottom: insets.bottom)
            }

            private func hingeChanged(hasHinge: Bool, closed: Bool) {
                if hasHinge != isFoldable || closed != isClosed {
                    isFoldable = hasHinge
                    isClosed = closed
                    if #available(iOS 16.0, *) {
                        setNeedsUpdateOfSupportedInterfaceOrientations()
                    } else {
                        UIViewController.attemptRotationToDeviceOrientation()
                    }
                }
                viewIfLoaded?.setNeedsLayout()
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
                // An open foldable turns upright, with its own arrangement there (held upside
                // down it stays as it is, as on any iPhone). Closed, it's sideways as ever.
                isFoldable && !isClosed ? .allButUpsideDown : .landscape
            }
        #endif
    }
#endif
