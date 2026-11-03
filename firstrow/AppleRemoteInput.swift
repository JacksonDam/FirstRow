#if os(macOS)
    import AppKit
    import AudioToolbox
    import CoreAudio
    import IOKit
    import IOKit.hid

    /// Key events First Row posts itself (Apple Remote, harness), handled like the keyboard's.
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

    /// Turns IR Apple Remote buttons into the arrow, Return and Escape keys the menus handle.
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

    /// Siri Remotes paired with the Mac. While First Row is in front it holds the remote, so
    /// Play/Pause doesn't also reach the Music app, and sets the Mac's volume itself.
    @MainActor
    final class SiriRemoteInput {
        static let shared = SiriRemoteInput()

        private var manager: IOHIDManager?
        private var remotes: [IOHIDDevice] = []
        private var pressedKeys: Set<UInt16> = []
        private var volumeRepeat: Timer?

        func start() {
            guard manager == nil else { return }
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(manager, [
                kIOHIDVendorIDKey: 0x4C,
                kIOHIDPrimaryUsagePageKey: kHIDPage_Consumer,
                kIOHIDPrimaryUsageKey: kHIDUsage_Csmr_ConsumerControl,
            ] as CFDictionary)
            // Matching also fires when a remote wakes and reconnects.
            IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in
                MainActor.assumeIsolatedIfPossible { SiriRemoteInput.shared.attach(device) }
            }, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, device in
                MainActor.assumeIsolatedIfPossible { SiriRemoteInput.shared.detach(device) }
            }, nil)
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            self.manager = manager
        }

        func stop() {
            guard let manager else { return }
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            self.manager = nil
            for device in remotes {
                IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            remotes.removeAll()
            releaseAll()
        }

        private func attach(_ device: IOHIDDevice) {
            guard !remotes.contains(where: { $0 === device }) else { return }
            // Only remotes have the clickpad ring (Menu Up), which keeps keyboards' media keys out.
            let ring = [kIOHIDElementUsagePageKey: kHIDPage_Consumer, kIOHIDElementUsageKey: kHIDUsage_Csmr_MenuUp] as CFDictionary
            guard let elements = IOHIDDeviceCopyMatchingElements(device, ring, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement],
                  !elements.isEmpty,
                  IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess
            else { return }
            IOHIDDeviceRegisterInputValueCallback(device, { _, _, _, value in
                let element = IOHIDValueGetElement(value)
                let page = IOHIDElementGetUsagePage(element)
                let usage = IOHIDElementGetUsage(element)
                let pressed = IOHIDValueGetIntegerValue(value) != 0
                MainActor.assumeIsolatedIfPossible {
                    SiriRemoteInput.shared.handle(page: page, usage: usage, pressed: pressed)
                }
            }, nil)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            remotes.append(device)
        }

        private func detach(_ device: IOHIDDevice) {
            guard let index = remotes.firstIndex(where: { $0 === device }) else { return }
            remotes.remove(at: index)
            releaseAll()
        }

        private func releaseAll() {
            for keyCode in pressedKeys {
                if let key = KeyCode(rawValue: keyCode) {
                    SyntheticKeyEvents.post(key, down: false)
                }
            }
            pressedKeys.removeAll()
            volumeRepeat?.invalidate()
            volumeRepeat = nil
        }

        private func handle(page: UInt32, usage: UInt32, pressed: Bool) {
            switch (Int(page), Int(usage)) {
            case (kHIDPage_Consumer, kHIDUsage_Csmr_VolumeIncrement):
                repeatVolumeStep(pressed ? 1 : 0)
                return
            case (kHIDPage_Consumer, kHIDUsage_Csmr_VolumeDecrement):
                repeatVolumeStep(pressed ? -1 : 0)
                return
            case (kHIDPage_Consumer, kHIDUsage_Csmr_Mute):
                if pressed {
                    SystemOutputVolume.toggleMute()
                    SystemOutputVolume.announce()
                }
                return
            default:
                break
            }
            guard let key = Self.key(page: page, usage: usage) else { return }
            if pressed {
                guard pressedKeys.insert(key.rawValue).inserted else { return }
            } else {
                guard pressedKeys.remove(key.rawValue) != nil else { return }
            }
            SyntheticKeyEvents.post(key, down: pressed)
        }

        /// Steps the volume now, then keeps stepping while the button is held, like the Mac's keys.
        private func repeatVolumeStep(_ direction: Int) {
            volumeRepeat?.invalidate()
            volumeRepeat = nil
            guard direction != 0 else { return }
            SystemOutputVolume.step(by: direction)
            SystemOutputVolume.announce()
            let timer = Timer(timeInterval: 0.12, repeats: true) { _ in
                MainActor.assumeIsolatedIfPossible {
                    SystemOutputVolume.step(by: direction)
                    SystemOutputVolume.announce()
                }
            }
            timer.fireDate = Date().addingTimeInterval(0.45)
            RunLoop.main.add(timer, forMode: .common)
            volumeRepeat = timer
        }

        static func key(page: UInt32, usage: UInt32) -> KeyCode? {
            switch (Int(page), Int(usage)) {
            case (kHIDPage_Consumer, kHIDUsage_Csmr_MenuUp): .upArrow
            case (kHIDPage_Consumer, kHIDUsage_Csmr_MenuDown): .downArrow
            case (kHIDPage_Consumer, kHIDUsage_Csmr_MenuLeft): .leftArrow
            case (kHIDPage_Consumer, kHIDUsage_Csmr_MenuRight): .rightArrow
            case (kHIDPage_Consumer, kHIDUsage_Csmr_Selection), (kHIDPage_Consumer, kHIDUsage_Csmr_MenuPick): .enter
            case (kHIDPage_GenericDesktop, kHIDUsage_GD_SystemAppMenu), (kHIDPage_Consumer, kHIDUsage_Csmr_Menu),
                 (kHIDPage_Consumer, kHIDUsage_Csmr_ACBack): .escape
            case (kHIDPage_Consumer, kHIDUsage_Csmr_PlayOrPause): .space
            default: nil
            }
        }
    }

    /// The default output device's volume, in sixteenths like the Mac's volume keys.
    enum SystemOutputVolume {
        // kAudioHardwareServiceDeviceProperty_VirtualMainVolume, which needs macOS 12 by name.
        private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

        static func step(by direction: Int) {
            guard let device = defaultOutputDevice() else { return }
            var address = AudioObjectPropertyAddress(mSelector: virtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectHasProperty(device, &address),
                  AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr
            else { return }
            var newVolume = min(1, max(0, ((volume * 16).rounded() + Float32(direction)) / 16))
            AudioObjectSetPropertyData(device, &address, 0, nil, size, &newVolume)
            if direction > 0 { setMuted(false, device: device) }
        }

        /// Tells the volume overlay the current level.
        static func announce() {
            guard let device = defaultOutputDevice() else { return }
            var volumeAddress = AudioObjectPropertyAddress(mSelector: virtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume) == noErr else { return }
            var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
            var muted: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted) != noErr { muted = 0 }
            NotificationCenter.default.post(name: .firstRowVolumeChanged, object: nil, userInfo: ["volume": muted != 0 ? 0 : Double(volume)])
        }

        static func toggleMute() {
            guard let device = defaultOutputDevice() else { return }
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return }
            setMuted(muted == 0, device: device)
        }

        private static func setMuted(_ muted: Bool, device: AudioObjectID) {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
            guard AudioObjectHasProperty(device, &address) else { return }
            var value: UInt32 = muted ? 1 : 0
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        }

        private static func defaultOutputDevice() -> AudioObjectID? {
            var device = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
                  device != kAudioObjectUnknown
            else { return nil }
            return device
        }
    }
#endif
