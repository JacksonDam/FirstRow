#if os(macOS)
    import AppKit
    import AudioToolbox
    import CoreAudio
    import IOKit
    import IOKit.hid

    /// Key events First Row posts itself (Apple Remote, harness), handled like the keyboard's.
    enum SyntheticKeyEvents {
        private static let lock = NSLock()
        /// Posted events still on their way, with where they came from.
        private nonisolated(unsafe) static var pending: [(key: UInt16, down: Bool, source: MenuInputSource, time: TimeInterval)] = []

        /// Where a key event came from: a remote's (posted here), or the keyboard.
        static func source(of event: NSEvent) -> MenuInputSource {
            guard event.windowNumber == 0 else { return .keyboard }
            let down = event.type == .keyDown
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            defer { lock.unlock() }
            pending.removeAll { now - $0.time > 2 }
            guard let index = pending.firstIndex(where: { $0.key == event.keyCode && $0.down == down }) else { return .keyboard }
            return pending.remove(at: index).source
        }

        static func post(_ key: KeyCode, down: Bool, source: MenuInputSource = .keyboard) {
            if source != .keyboard {
                lock.lock()
                pending.append((key.rawValue, down, source, ProcessInfo.processInfo.systemUptime))
                if pending.count > 64 { pending.removeFirst(pending.count - 64) }
                lock.unlock()
            }
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

        /// Set by the app: whether a quick tap of ⏮ or ⏭ should change song (music's Now Playing)
        /// instead of moving left or right.
        var tapsChangeSong: @MainActor () -> Bool = { false }
        /// Set by the app: whether + and - should change the volume instead of moving up and down
        /// (on the playback screens, which don't use up and down).
        var plusMinusChangeVolume: @MainActor () -> Bool = { false }

        private var devices: [IOHIDDevice] = []
        private var pressedKeys: Set<UInt16> = []
        /// The key each held button sent, so its release lifts the same key.
        private var keyForButton: [UInt32: KeyCode] = [:]
        /// The + or - buttons held down for the volume (one press can arrive as two usages).
        private var volumeButtons: Set<UInt32> = []
        private let volumeHold = VolumeButtonHold()

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
                    SyntheticKeyEvents.post(key, down: false, source: .siriRemote)
                }
            }
            pressedKeys.removeAll()
            keyForButton.removeAll()
            volumeButtons.removeAll()
            volumeHold.end()
        }

        func handle(page: UInt32, usage: UInt32, pressed: Bool) {
            let button = page << 16 | usage
            if pressed {
                guard var key = Self.key(page: page, usage: usage) else { return }
                if key == .upArrow || key == .downArrow, plusMinusChangeVolume() {
                    let direction = key == .upArrow ? 1 : -1
                    if volumeHold.direction != direction { volumeHold.begin(direction) }
                    volumeButtons.insert(button)
                    return
                }
                // Tap ⏮/⏭ to change song; holding them (sent as Rewind/Fast Forward) still scrubs.
                if Self.isSkipTap(page: page, usage: usage), tapsChangeSong() {
                    key = key == .rightArrow ? .downArrow : .upArrow
                }
                guard pressedKeys.insert(key.rawValue).inserted else { return }
                keyForButton[button] = key
                SyntheticKeyEvents.post(key, down: true, source: .appleRemote)
            } else {
                if volumeButtons.remove(button) != nil {
                    if volumeButtons.isEmpty { volumeHold.end() }
                    return
                }
                guard let key = keyForButton.removeValue(forKey: button) else { return }
                pressedKeys.remove(key.rawValue)
                SyntheticKeyEvents.post(key, down: false, source: .appleRemote)
            }
        }

        /// A quick press of ⏮ or ⏭; the receiver reports holding them as Rewind or Fast Forward instead.
        static func isSkipTap(page: UInt32, usage: UInt32) -> Bool {
            switch (Int(page), Int(usage)) {
            case (kHIDPage_GenericDesktop, kHIDUsage_GD_SystemMenuLeft), (kHIDPage_GenericDesktop, kHIDUsage_GD_SystemMenuRight),
                 (kHIDPage_Consumer, kHIDUsage_Csmr_ScanPreviousTrack), (kHIDPage_Consumer, kHIDUsage_Csmr_ScanNextTrack):
                true
            default:
                false
            }
        }

        /// The remote reports Consumer page usages (or Generic Desktop menu usages on some receivers).
        /// Since macOS 10.13.6 the receiver sends System Menu Up/Down alongside every Volume +/- press,
        /// so those two are left out or each press would move twice.
        static func key(page: UInt32, usage: UInt32) -> KeyCode? {
            switch (Int(page), Int(usage)) {
            case (kHIDPage_Consumer, kHIDUsage_Csmr_VolumeIncrement), (kHIDPage_Consumer, kHIDUsage_Csmr_MenuUp):
                .upArrow
            case (kHIDPage_Consumer, kHIDUsage_Csmr_VolumeDecrement), (kHIDPage_Consumer, kHIDUsage_Csmr_MenuDown):
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
        private let volumeHold = VolumeButtonHold()
        /// Set by the app: the TV button, which opens and closes Now Playing's list.
        var onTVButton: @MainActor () -> Void = {}
        /// Set by the app: a remote's button was pressed (before the key it sends arrives).
        var onInput: @MainActor () -> Void = {}

        /// A Siri Remote is paired and held by First Row.
        var hasRemote: Bool { !remotes.isEmpty }

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
            RemoteDiagnosticsLog.watchSiblings(of: device)
        }

        private func detach(_ device: IOHIDDevice) {
            guard let index = remotes.firstIndex(where: { $0 === device }) else { return }
            remotes.remove(at: index)
            releaseAll()
        }

        private func releaseAll() {
            for keyCode in pressedKeys {
                if let key = KeyCode(rawValue: keyCode) {
                    SyntheticKeyEvents.post(key, down: false, source: .siriRemote)
                }
            }
            pressedKeys.removeAll()
            volumeHold.end()
        }

        private func handle(page: UInt32, usage: UInt32, pressed: Bool) {
            RemoteDiagnosticsLog.write("button page \(page) usage \(String(format: "0x%02x", usage)) \(pressed ? "down" : "up")")
            if pressed { onInput() }
            switch (Int(page), Int(usage)) {
            case (kHIDPage_Consumer, 0x60):
                // The TV button.
                if pressed { onTVButton() }
                return
            case (kHIDPage_Consumer, kHIDUsage_Csmr_VolumeIncrement):
                if pressed { volumeHold.begin(1) } else { volumeHold.end() }
                return
            case (kHIDPage_Consumer, kHIDUsage_Csmr_VolumeDecrement):
                if pressed { volumeHold.begin(-1) } else { volumeHold.end() }
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
            SyntheticKeyEvents.post(key, down: pressed, source: .siriRemote)
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

    /// While the hidden `logRemoteInput` setting is on, writes what a Siri Remote sends (its
    /// buttons as First Row gets them, and the raw packets of its other parts, the touch surface
    /// among them) to ~/Library/Logs/First Row/remote.log, for working out how to read them.
    @MainActor
    enum RemoteDiagnosticsLog {
        static let isOn = UserDefaults.standard.bool(forKey: "logRemoteInput")
        private static let start = ProcessInfo.processInfo.systemUptime
        private static var handle: FileHandle?
        private static var manager: IOHIDManager?
        private static var watchedSerials: Set<String> = []
        private static var buffers: [UnsafeMutablePointer<UInt8>] = []

        static func write(_ line: String) {
            guard isOn else { return }
            if handle == nil {
                let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/First Row", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("remote.log")
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(atPath: file.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: file)
                handle?.seekToEndOfFile()
            }
            let text = String(format: "%9.3f ", ProcessInfo.processInfo.systemUptime - start) + line + "\n"
            handle?.write(Data(text.utf8))
        }

        /// Opens the remote's other parts (the same serial number), without taking them over.
        static func watchSiblings(of remote: IOHIDDevice) {
            guard isOn, let serial = IOHIDDeviceGetProperty(remote, kIOHIDSerialNumberKey as CFString) as? String,
                  watchedSerials.insert(serial).inserted
            else { return }
            write("watching remote \(serial)")
            let manager = manager ?? {
                let made = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
                IOHIDManagerSetDeviceMatching(made, [kIOHIDVendorIDKey: 0x4C] as CFDictionary)
                IOHIDManagerRegisterDeviceMatchingCallback(made, { _, _, _, device in
                    MainActor.assumeIsolatedIfPossible { RemoteDiagnosticsLog.attach(device) }
                }, nil)
                IOHIDManagerScheduleWithRunLoop(made, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                IOHIDManagerOpen(made, IOOptionBits(kIOHIDOptionsTypeNone))
                return made
            }()
            self.manager = manager
        }

        private static func attach(_ device: IOHIDDevice) {
            guard let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String,
                  watchedSerials.contains(serial)
            else { return }
            let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
            // The buttons come through First Row's own handling.
            guard !(page == kHIDPage_Consumer && usage == kHIDUsage_Csmr_ConsumerControl) else { return }
            let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            write("part page \(page) usage \(usage) open \(opened)")
            let size = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            buffers.append(buffer)
            let tag = UnsafeMutableRawPointer(bitPattern: (page << 16) | usage)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { context, _, _, _, reportID, report, length in
                let tag = Int(bitPattern: context)
                let bytes = (0 ..< length).map { String(format: "%02x", report[$0]) }.joined()
                MainActor.assumeIsolatedIfPossible {
                    RemoteDiagnosticsLog.write("packet \(tag >> 16)/\(tag & 0xFFFF) id \(reportID) len \(length) \(bytes)")
                }
            }, tag)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
    }

    /// A remote's volume button: steps the volume on press, then keeps stepping while it's held,
    /// like the Mac's volume keys.
    @MainActor
    final class VolumeButtonHold {
        private(set) var direction = 0
        private var timer: Timer?

        func begin(_ direction: Int) {
            end()
            guard direction != 0 else { return }
            self.direction = direction
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
            self.timer = timer
        }

        func end() {
            timer?.invalidate()
            timer = nil
            direction = 0
        }
    }

    /// The default output device's volume, in sixteenths like the Mac's volume keys.
    enum SystemOutputVolume {
        // kAudioHardwareServiceDeviceProperty_VirtualMainVolume, which needs macOS 12 by name.
        private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663
        /// The harness keeps its own level, so tests leave the Mac's volume alone.
        private static var harnessVolume: Float32 = 0.5

        static func step(by direction: Int) {
            if FirstRowHarness.isActive {
                harnessVolume = min(1, max(0, ((harnessVolume * 16).rounded() + Float32(direction)) / 16))
                return
            }
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
            if FirstRowHarness.isActive {
                NotificationCenter.default.post(name: .firstRowVolumeChanged, object: nil, userInfo: ["volume": Double(harnessVolume)])
                return
            }
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
            guard !FirstRowHarness.isActive, let device = defaultOutputDevice() else { return }
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
