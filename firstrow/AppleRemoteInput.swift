#if os(macOS)
    import AppKit
    import IOKit
    import IOKit.hid

    /// Key events made by First Row itself (the Apple Remote, the debug harness), delivered
    /// through the same path as the keyboard's.
    enum SyntheticKeyEvents {
        static func post(_ key: KeyCode, down: Bool) {
            let characters: String = switch key {
            case .enter: "\r"
            case .escape: "\u{1b}"
            case .delete: "\u{7f}"
            case .space: " "
            default: ""
            }
            // Window number 0: the event reaches the app's key monitors whichever window is key.
            guard let event = NSEvent.keyEvent(
                with: down ? .keyDown : .keyUp,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: key.rawValue,
            ) else { return }
            NSApplication.shared.postEvent(event, atStart: false)
        }
    }

    /// The infrared Apple Remote (the white A1156 and the aluminium A1294), on Macs with an IR
    /// receiver. Its buttons become the keys First Row already understands: + and - are up and
    /// down, ⏮ and ⏭ are left and right, the centre (play) button is Return, which also plays and
    /// pauses during playback, and Menu goes back like Escape.
    ///
    /// While First Row is in front the receiver is opened exclusively, so the remote stops
    /// changing the volume or opening Music; it is released whenever First Row is in the
    /// background. Macs without a receiver are unaffected.
    @MainActor
    final class AppleRemoteInput {
        static let shared = AppleRemoteInput()

        private var devices: [IOHIDDevice] = []
        private var pressedKeys: Set<UInt16> = []

        func start() {
            guard devices.isEmpty else { return }
            var iterator: io_iterator_t = 0
            // Port 0 is the default main port on every macOS version.
            guard IOServiceGetMatchingServices(0, IOServiceMatching("AppleIRController"), &iterator) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
                // Exclusive first, so the system doesn't act on the buttons too; shared if that's refused.
                if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) != kIOReturnSuccess,
                   IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess
                {
                    continue
                }
                IOHIDDeviceRegisterInputValueCallback(device, { _, _, _, value in
                    let element = IOHIDValueGetElement(value)
                    let page = IOHIDElementGetUsagePage(element)
                    let usage = IOHIDElementGetUsage(element)
                    let pressed = IOHIDValueGetIntegerValue(value) != 0
                    DispatchQueue.main.async {
                        MainActor.assumeIsolatedIfPossible {
                            AppleRemoteInput.shared.handle(page: page, usage: usage, pressed: pressed)
                        }
                    }
                }, nil)
                IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                devices.append(device)
            }
        }

        func stop() {
            for device in devices {
                IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            devices.removeAll()
            for keyCode in pressedKeys {
                if let key = KeyCode(rawValue: keyCode) {
                    SyntheticKeyEvents.post(key, down: false)
                }
            }
            pressedKeys.removeAll()
        }

        private func handle(page: UInt32, usage: UInt32, pressed: Bool) {
            guard let key = Self.key(page: page, usage: usage) else { return }
            if pressed {
                guard pressedKeys.insert(key.rawValue).inserted else { return }
            } else {
                guard pressedKeys.remove(key.rawValue) != nil else { return }
            }
            SyntheticKeyEvents.post(key, down: pressed)
        }

        /// The remote reports Consumer page usages (or Generic Desktop menu usages on some receivers).
        static func key(page: UInt32, usage: UInt32) -> KeyCode? {
            switch (Int(page), Int(usage)) {
            case (kHIDPage_Consumer, kHIDUsage_Csmr_VolumeIncrement), (kHIDPage_Consumer, kHIDUsage_Csmr_MenuUp),
                 (kHIDPage_GenericDesktop, kHIDUsage_GD_SystemMenuUp):
                .upArrow
            case (kHIDPage_Consumer, kHIDUsage_Csmr_VolumeDecrement), (kHIDPage_Consumer, kHIDUsage_Csmr_MenuDown),
                 (kHIDPage_GenericDesktop, kHIDUsage_GD_SystemMenuDown):
                .downArrow
            case (kHIDPage_Consumer, kHIDUsage_Csmr_ScanPreviousTrack), (kHIDPage_Consumer, kHIDUsage_Csmr_Rewind),
                 (kHIDPage_Consumer, kHIDUsage_Csmr_MenuLeft), (kHIDPage_GenericDesktop, kHIDUsage_GD_SystemMenuLeft):
                .leftArrow
            case (kHIDPage_Consumer, kHIDUsage_Csmr_ScanNextTrack), (kHIDPage_Consumer, kHIDUsage_Csmr_FastForward),
                 (kHIDPage_Consumer, kHIDUsage_Csmr_MenuRight), (kHIDPage_GenericDesktop, kHIDUsage_GD_SystemMenuRight):
                .rightArrow
            case (kHIDPage_Consumer, kHIDUsage_Csmr_PlayOrPause), (kHIDPage_Consumer, kHIDUsage_Csmr_Play),
                 (kHIDPage_Consumer, kHIDUsage_Csmr_MenuPick), (kHIDPage_GenericDesktop, kHIDUsage_GD_SystemMenuSelect):
                .enter
            case (kHIDPage_Consumer, kHIDUsage_Csmr_Menu), (kHIDPage_Consumer, kHIDUsage_Csmr_MenuEscape),
                 (kHIDPage_GenericDesktop, kHIDUsage_GD_SystemAppMenu), (kHIDPage_GenericDesktop, kHIDUsage_GD_SystemMenuExit):
                .escape
            default:
                nil
            }
        }
    }
#endif
