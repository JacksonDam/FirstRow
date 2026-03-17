#if os(iOS)
    import UIKit

    final class IOSAppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _: UIApplication,
            supportedInterfaceOrientationsFor _: UIWindow?,
        ) -> UIInterfaceOrientationMask {
            .landscape
        }
    }
#endif
