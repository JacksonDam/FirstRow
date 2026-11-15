import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// How Now Playing makes room on its right for the list it came from or the lyrics: what's
/// left of it moves left and shrinks a little to fit.
@MainActor
enum NowPlayingSideLayout {
    static func queueWidth(_ size: CGSize) -> CGFloat {
        min(600, size.width * 0.4)
    }

    /// The side panel's width plus its margins, in canvas points (0 with nothing beside it),
    /// and how far out it is.
    static func reserve(menu: MenuView, size: CGSize) -> (width: CGFloat, amount: CGFloat) {
        let reveal = min(max(menu.nowPlayingQueueReveal, 0), 1)
        let list = queueWidth(size) + 70
        if menu.isNowPlayingLyricsVisible {
            // Aside for the words already: as the list comes out over them, what stays goes
            // from the room the words need to the room the list needs, a step for each of its.
            let words = lyricsFrame(size).width + 90
            return (words + (list - words) * reveal, 1)
        }
        if reveal > 0 { return (list, reveal) }
        return (0, 0)
    }

    /// The list's sheet in canvas points: down the right side or, standing upright, across the
    /// part under the fold.
    static func queuePanel(_ size: CGSize, upright: UprightStance?) -> CGRect {
        if let pane = upright?.lowerPane {
            return CGRect(x: 40, y: pane.minY + 14, width: size.width - 80, height: pane.height - 28)
        }
        let width = queueWidth(size)
        return CGRect(x: size.width - width - 40, y: 70, width: width, height: size.height - 140)
    }

    /// In the modern look, lying down, the words have the right half of the screen and the
    /// song is set out again in the left half (its cover over its details), at nearly its full
    /// size, rather than shrunk aside. It stays there while the list is out: that comes over
    /// the words, which fade as it does, and they are there again when it goes.
    static func wordsTakeHalf(menu: MenuView) -> Bool {
        ModernTheme.isActive && menu.upright == nil && menu.isNowPlayingLyricsVisible
    }

    /// How much the words show against the list: all of them with the list away, and none by
    /// the time it is half way out over them (what stays is on the move by then).
    static func wordsStrength(menu: MenuView) -> CGFloat {
        1 - min(max(menu.nowPlayingQueueReveal * 2, 0), 1)
    }

    /// How much of the heading (see `heading`) there is: all of it with the list away; as the
    /// list comes out under the fold the song goes back to its usual tucked arrangement.
    static func headingAmount(menu: MenuView) -> CGFloat {
        1 - min(max(menu.nowPlayingQueueReveal, 0), 1)
    }

    /// In the modern look, standing upright and opened out flat, the words have the whole
    /// screen under a small heading: the cover, small, beside Back at the top, with the song's
    /// name and artist beside it. Where that cover goes in canvas points, while the words are
    /// out or on their way (nil otherwise: bent at the fold, the words keep to the part under
    /// it).
    static func heading(menu: MenuView, canvasScale: CGFloat) -> CGRect? {
        guard ModernTheme.isActive, let upright = menu.upright, !upright.isBent,
              menu.isNowPlayingLyricsVisible || menu.nowPlayingWordsGlide != nil
        else { return nil }
        let scale = max(canvasScale, 0.0001)
        let side: CGFloat = 116
        // Level with Back (46 points across, 38 in from the left and 10 under the top inset),
        // and clear of it.
        let middle = max(upright.topInset + 33 / scale, 55 / scale)
        return CGRect(x: (100 / scale).rounded(), y: (middle - side / 2).rounded(), width: side, height: side)
    }

    static func lyricsFrame(_ size: CGSize, upright: UprightStance? = nil, heading: CGRect? = nil) -> CGRect {
        if let heading {
            // Under the heading, lined up with its cover, to the bottom of the screen.
            let top = heading.maxY + 16
            return CGRect(x: heading.minX, y: top, width: size.width - heading.minX - 80, height: max(1, size.height - top))
        }
        if let pane = upright?.lowerPane {
            // Standing upright the words have the part under the fold to themselves.
            return CGRect(x: 70, y: pane.minY, width: size.width - 140, height: pane.height)
        }
        if ModernTheme.isActive {
            // The right half, from a little past the middle, top to bottom.
            let left = (size.width * 0.535).rounded()
            return CGRect(x: left, y: 0, width: size.width - left - max(90, (size.width * 0.07).rounded()), height: size.height)
        }
        let width = (size.width * 0.44).rounded()
        // On iPhone and iPad the buttons along the bottom keep the words above them.
        #if os(iOS)
            #if os(iOS)
                let height = size.height * 0.8
            #else
                let height = size.height
            #endif
        #else
            let height = size.height
        #endif
        return CGRect(x: size.width - width - 70, y: 0, width: width, height: height)
    }

    /// The move and scale, about the middle of the screen, for what stays.
    /// A list only part way out moves the rest only part of the way.
    static func shift(menu: MenuView, size: CGSize) -> (dx: CGFloat, scale: CGFloat) {
        // Standing upright nothing moves aside: see `tuck`.
        guard menu.upright == nil else { return (0, 1) }
        // (The modern look sets the song out again in the left half itself; what goes with it,
        // the buttons along the bottom, has the middle of that half.)
        if wordsTakeHalf(menu: menu) { return (-size.width / 4, 1) }
        let reserve = reserve(menu: menu, size: size)
        guard reserve.width > 0, reserve.amount > 0 else { return (0, 1) }
        let scale = min(1, max(0.5, (size.width - reserve.width - 50) / (size.width * 0.86)))
        return (-reserve.width / 2 * reserve.amount, 1 - (1 - scale) * reserve.amount)
    }

    static func transform(_ shift: (dx: CGFloat, scale: CGFloat), size: CGSize) -> CATransform3D {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var transform = CATransform3DMakeTranslation(center.x + shift.dx, center.y, 0)
        transform = CATransform3DScale(transform, shift.scale, shift.scale, 1)
        return CATransform3DTranslate(transform, -center.x, -center.y, 0)
    }

    /// A rectangle of what stays, where it shows once moved.
    static func map(_ rect: CGRect, _ shift: (dx: CGFloat, scale: CGFloat), size: CGSize) -> CGRect {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGRect(
            x: center.x + shift.dx + (rect.minX - center.x) * shift.scale,
            y: center.y + (rect.minY - center.y) * shift.scale,
            width: rect.width * shift.scale,
            height: rect.height * shift.scale,
        )
    }

    /// Standing upright the list and the words come out under the fold, where the song's
    /// details are, and the details tuck up beside the cover above it, both smaller. How far
    /// that has gone: 0 with nothing out, 1 with the list or the words all the way out.
    static func tuck(menu: MenuView) -> CGFloat {
        guard menu.upright != nil else { return 0 }
        let words = menu.nowPlayingWordsGlide ?? (menu.isNowPlayingLyricsVisible ? 1 : 0)
        return max(min(max(menu.nowPlayingQueueReveal, 0), 1), min(max(words, 0), 1))
    }

    /// Standing upright, where the details show part way through a tuck (0 to 1), so that they
    /// never cross the cover, the list or the words on the way. Over its first half they slide
    /// off the left of the part under the fold, ahead of the list coming in from the right;
    /// over its second they slide in above the fold from the side they end up on, into the
    /// room the cover has made by then. `home` and `tucked` are where they rest at either end,
    /// and `span` how far they reach across, in their own points. `slide` is how far along
    /// they are from their resting place, for the on-screen buttons that go with them.
    /// (`fromRight` has them come in from the right whichever side they end up on: into a
    /// heading with the cover on its left.)
    static func detailsPlace(home: Place, tucked: Place, span: ClosedRange<CGFloat>, width: CGFloat, tuck: CGFloat, fromRight: Bool = false) -> (place: Place, slide: CGFloat) {
        let tuck = min(max(tuck, 0), 1)
        let rest = tuck < 0.5 ? home : tucked
        let left = rest.center.x + (span.lowerBound - rest.anchor.x) * rest.scale
        let right = rest.center.x + (span.upperBound - rest.anchor.x) * rest.scale
        let slide: CGFloat
        if tuck < 0.5 {
            // Gently at first, then away faster than the list comes in.
            slide = -(right + 60) * pow(tuck / 0.5, 1.5)
        } else {
            let away = fromRight || (left + right) / 2 > width / 2 ? width - left + 60 : -(right + 60)
            slide = away * pow(1 - (tuck - 0.5) / 0.5, 1.5)
        }
        return (Place(anchor: rest.anchor, scale: rest.scale, center: CGPoint(x: rest.center.x + slide, y: rest.center.y)), slide)
    }

    /// Where one part of the panel (the cover, or the details) shows: at `scale`, with its own
    /// point `anchor` at `center`.
    struct Place {
        var anchor: CGPoint
        var scale: CGFloat
        var center: CGPoint

        /// Part of the way from one place to another, in a straight line.
        static func between(_ from: Place, _ to: Place, _ amount: CGFloat) -> Place {
            let amount = min(max(amount, 0), 1)
            return Place(
                anchor: from.anchor,
                scale: from.scale + (to.scale - from.scale) * amount,
                center: CGPoint(x: from.center.x + (to.center.x - from.center.x) * amount, y: from.center.y + (to.center.y - from.center.y) * amount),
            )
        }

        /// For a layer anchored at its top left and placed at the origin.
        var transform: CATransform3D {
            var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            return CATransform3DTranslate(transform, -anchor.x, -anchor.y, 0)
        }

        func map(_ rect: CGRect) -> CGRect {
            CGRect(
                x: center.x + (rect.minX - anchor.x) * scale,
                y: center.y + (rect.minY - anchor.y) * scale,
                width: rect.width * scale,
                height: rect.height * scale,
            )
        }
    }
}

/// A faint bar that says something can be pulled out from where it sits. When it first
/// shows it brightens, drifts a little the way to pull and back, and settles faint and still.
@MainActor
final class HintBarLayer {
    let layer = SceneLayer()
    private let bar = SceneLayer()
    private var isShown = false
    private var introducedSession: Int?
    /// How bright it rests, against its brightest.
    private static let resting: Float = 0.15

    init() {
        layer.addSublayer(bar)
        layer.opacity = 0
        layer.isHidden = true
        bar.backgroundColor = CGColor(gray: 1, alpha: 1)
    }

    /// `drift` is the way to pull it, in the layer's own points; `session` changes each time
    /// what it belongs to opens, and it introduces itself once per session.
    func update(frame: CGRect, shown: Bool, drift: CGSize, session: Int, alpha: CGFloat = 0.55) {
        layer.place(frame)
        bar.frame = CGRect(origin: .zero, size: frame.size)
        bar.cornerRadius = min(frame.width, frame.height) / 2
        bar.backgroundColor = CGColor(gray: 1, alpha: alpha)
        guard shown != isShown else { return }
        isShown = shown
        guard shown else {
            // (Still introducing itself, it goes from where that has got to.)
            if layer.animation(forKey: "introduce") != nil {
                let now = layer.presentation()?.opacity ?? layer.opacity
                layer.removeAnimation(forKey: "introduce")
                bar.removeAnimation(forKey: "introduce")
                layer.opacity = now
            }
            layer.setOpacity(0, .smoothInOut(duration: 0.3))
            return
        }
        layer.isHidden = false
        guard introducedSession != session else {
            layer.setOpacity(Double(Self.resting), .smooth(duration: 0.6))
            return
        }
        introducedSession = session
        layer.removeAllAnimations()
        bar.removeAllAnimations()
        layer.opacity = Self.resting
        let duration: CFTimeInterval = 2.8
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, Self.resting]
        fade.keyTimes = [0, 0.14, 0.42, 1]
        fade.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)]
        fade.duration = duration
        layer.addAtFullRate(fade, forKey: "introduce")
        let float = CAKeyframeAnimation(keyPath: "transform")
        float.values = [CATransform3DIdentity, CATransform3DMakeTranslation(drift.width, drift.height, 0), CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
        float.keyTimes = [0.1, 0.45, 0.85]
        float.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        float.duration = duration
        bar.addAtFullRate(float, forKey: "introduce")
    }
}

// MARK: - The list beside Now Playing

/// The songs Now Playing came from, in a panel that slides in over the right of the screen,
/// with the one playing marked. Only rows near the view get layers.
@MainActor
final class NowPlayingQueueLayer {
    let layer = SceneLayer()
    private let panel = SceneLayer()
    private let header = SceneLayer()
    private let clip = SceneLayer()
    private let fade = SceneGradientLayer()
    private let rowsContainer = SceneLayer()

    /// One song in the list, drawn as the menus' rows are: in the modern look a translucent
    /// capsule that turns white, grows and casts its shadow when picked out; in the classic look
    /// plain text over the menus' selection bar.
    private final class Row {
        let layer = SceneLayer()
        let shadowCaster = SceneLayer()
        let shadowCutout = CAShapeLayer()
        var shadowSize: CGSize = .zero
        let capsule = SceneLayer()
        let content = SceneLayer()
        let light = Ink()
        let dark = Ink()
        /// What a row's two inks are drawn from.
        struct ContentKey: Equatable {
            let title: String
            let detail: String
            let isPlaying: Bool
            let isModern: Bool
            let scale: CGFloat
            let width: CGFloat
        }

        var contentKey: ContentKey?
        /// What the dark ink was last drawn from: it's drawn when its row is first focused.
        var darkKey: ContentKey?
        var index = -1
        var isFocused = false

        final class Ink {
            let layer = SceneLayer()
            let title = SceneLayer()
            let detail = SceneLayer()
            let speaker = SceneLayer()

            init() {
                for sublayer in [title, detail, speaker] {
                    layer.addSublayer(sublayer)
                }
            }
        }

        init() {
            capsule.backgroundColor = ModernTheme.rowFill.cgColor
            shadowCaster.shadowColor = CGColor(gray: 0, alpha: 1)
            shadowCaster.shadowRadius = 14
            shadowCaster.shadowOffset = .zero
            shadowCaster.shadowOpacity = 0.6
            shadowCutout.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
            shadowCutout.fillRule = .evenOdd
            shadowCutout.fillColor = CGColor(gray: 0, alpha: 1)
            shadowCaster.mask = shadowCutout
            layer.addSublayer(shadowCaster)
            layer.addSublayer(capsule)
            layer.addSublayer(content)
            content.addSublayer(light.layer)
            content.addSublayer(dark.layer)
        }
    }

    private var rows: [Int: Row] = [:]
    private var spare: [Row] = []
    private var lastScroll: CGFloat?
    /// How strongly each edge fades (top, bottom), as last set.
    private var lastFade: (CGFloat, CGFloat)?
    private var lastHeaderKey = ""
    /// The classic look's selection bar, behind the row picked out.
    private let selection = SelectionBoxLayer()
    private var lastSelectionIndex: Int?

    /// In canvas points: the panel, where rows show, the first row's top, how far it scrolls,
    /// and the strip along the right edge that pulls it out.
    private(set) var panelFrame: CGRect = .zero
    private(set) var viewport: CGRect = .zero
    private(set) var listTop: CGFloat = 0
    private(set) var scrollLimit: CGFloat = 0
    private(set) var isAvailable = false

    init() {
        // Away, the sheet waits past the right edge. It is out of sight there even while the
        // modern look draws the scene smaller on its way out, which brings what is just past
        // the screen's edges into view.
        layer.masksToBounds = true
        layer.addSublayer(panel)
        panel.addSublayer(header)
        panel.addSublayer(clip)
        clip.masksToBounds = true
        clip.addSublayer(rowsContainer)
        rowsContainer.addSublayer(selection.layer)
        selection.layer.isHidden = true
        clip.mask = fade
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        // (Six stops: past each edge, the edge itself, and where the fade from it ends.)
        fade.colors = [
            CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1),
            CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0),
        ]
        panel.opacity = 0
        panel.isHidden = true
    }

    func update(menu: MenuView, pass: RenderPass, size: CGSize, scale: CGFloat) {
        // (Its bounds, not its frame: it is drawn at the canvas's scale, and what it cuts off is
        // what lies past the canvas's edges.)
        layer.bounds = CGRect(origin: .zero, size: size)
        let isModern = ModernTheme.isActive
        isAvailable = menu.canShowNowPlayingQueue
        let reveal = isAvailable ? menu.nowPlayingQueueReveal : 0

        // (The hint along the right edge is drawn with the on-screen buttons, in screen points,
        // so it matches the transport's.)

        panelFrame = NowPlayingSideLayout.queuePanel(size, upright: menu.upright)
        let width = panelFrame.width
        panel.place(panelFrame)
        panel.backgroundColor = isModern ? CGColor(gray: 0.06, alpha: 0.72) : CGColor(gray: 0, alpha: 0.82)
        panel.cornerRadius = isModern ? 36 : 18
        panel.borderWidth = isModern ? 0 : 1.5
        panel.borderColor = CGColor(gray: 1, alpha: 0.22)
        panel.shadowColor = CGColor(gray: 0, alpha: 1)
        panel.shadowOpacity = 0.5
        panel.shadowRadius = 30
        panel.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: panelFrame.size), cornerWidth: panel.cornerRadius, cornerHeight: panel.cornerRadius, transform: nil)
        // One sheet that slides: away, it waits just past the right edge, shadow and all.
        let travel = size.width - panelFrame.minX + 60
        panel.isHidden = false
        panel.opacity = 1
        panel.setTransform(CATransform3DMakeTranslation(travel * (1 - reveal), 0, 0), pass.animation)
        // Away, its rows needn't be kept up to date.
        guard reveal > 0 else { return }

        // The list's name.
        let title = menu.nowPlayingQueueTitle
        let headerKey = "\(title)|\(isModern)|\(scale)|\(width)"
        let headerTop: CGFloat = 34
        if headerKey != lastHeaderKey {
            lastHeaderKey = headerKey
            let graphic = TextRenderer.render(TextSpec(
                text: title,
                fontName: isModern ? ModernTheme.boldFontName : firstRowBoldFontName,
                size: 40,
                color: RGBA(white: 1, alpha: 0.96),
                maxWidth: width - 80,
                minimumScaleFactor: 0.7,
            ), scale: scale)
            header.show(graphic, at: CGPoint(x: 40, y: headerTop))
        }

        let pitch = MenuView.nowPlayingQueueRowPitch
        let count = menu.nowPlayingQueueCount
        // Where the rows show, and how far each end is from the sheet's.
        let listFrame = CGRect(x: 0, y: headerTop + 74, width: width, height: panelFrame.height - headerTop - 74 - 18)
        let padding: CGFloat = 14
        // The classic bar's glow reaches further past a row than the room the first and last
        // rows are given, so on the first row its top was cut off in a straight line. What is
        // clipped starts that much higher, and ends as much lower as the sheet has room for;
        // the rows stay where they were, and so does where they fade as they scroll.
        let barHeight = pitch - 8
        let glow = SelectionBoxLayer.pictureHeight(visualHeight: barHeight + 58 * barHeight / 75, selectionBoxHeight: barHeight)
        let glowRoom = isModern ? 0 : max(0, ((glow - barHeight) / 2 - padding).rounded(.up))
        let roomAbove = min(glowRoom, listFrame.minY)
        let roomBelow = min(glowRoom, 16)
        let clipFrame = CGRect(x: 0, y: listFrame.minY - roomAbove, width: width, height: listFrame.height + roomAbove + roomBelow)
        clip.frame = clipFrame
        fade.frame = CGRect(origin: .zero, size: clipFrame.size)
        let fadeReach: CGFloat = 26
        let clipHeight = max(1, clipFrame.height)
        fade.locations = [0, roomAbove / clipHeight, (roomAbove + fadeReach) / clipHeight, 1 - (roomBelow + fadeReach) / clipHeight, 1 - roomBelow / clipHeight, 1]
            .map { NSNumber(value: Double($0)) }
        viewport = CGRect(x: panelFrame.minX, y: panelFrame.minY + listFrame.minY, width: width, height: listFrame.height)
        listTop = viewport.minY + padding
        scrollLimit = max(0, CGFloat(count) * pitch + padding * 2 - listFrame.height)
        let scroll = max(0, min(scrollLimit, menu.nowPlayingQueueScroll))
        rowsContainer.bounds = CGRect(x: 0, y: 0, width: width, height: max(listFrame.height, CGFloat(count) * pitch + padding * 2))
        let scrollAnimation = lastScroll == nil ? nil : pass.animation
        // Where it shows now, part way through a scroll, as well as where it's going: a quick
        // flick of the wheel mustn't leave it empty on the way.
        let shownScroll = roomAbove + padding - (rowsContainer.presentation()?.position.y ?? rowsContainer.position.y)
        rowsContainer.setPosition(CGPoint(x: 0, y: roomAbove + padding - scroll), scrollAnimation)
        lastScroll = scroll
        // Each edge fades only with something scrolled past it: at the top of the list the first
        // song shows whole, and at the bottom the last one does. (The room for the glow past
        // each edge shows or hides with the edge.)
        let topFade = min(1, max(0, scroll / fadeReach))
        let bottomFade = min(1, max(0, (scrollLimit - scroll) / fadeReach))
        let fadeColors = [
            CGColor(gray: 0, alpha: 1 - topFade), CGColor(gray: 0, alpha: 1 - topFade), CGColor(gray: 0, alpha: 1),
            CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1 - bottomFade), CGColor(gray: 0, alpha: 1 - bottomFade),
        ]
        let fadeKey = (topFade, bottomFade)
        if lastFade.map({ $0 != fadeKey }) ?? true {
            fade.set("colors", to: fadeColors, unchanged: false, animation: lastFade == nil ? nil : scrollAnimation)
            lastFade = fadeKey
        }

        // Rows near the view, all the way along a scroll under way.
        let first = max(0, Int(floor(min(scroll, shownScroll) / pitch)) - 2)
        let last = min(count - 1, Int(ceil((max(scroll, shownScroll) + listFrame.height) / pitch)) + 2)
        let range = first <= last ? first ... last : 1 ... 0
        for (index, row) in rows where !range.contains(index) {
            row.layer.isHidden = true
            row.index = -1
            spare.append(row)
            rows[index] = nil
        }
        let active = menu.nowPlayingQueueActiveIndex
        let focus = menu.nowPlayingQueueHoverIndex
        // Rows leave room each side for the classic bar's glow, or the modern capsule's growth.
        let rowInset: CGFloat = isModern ? 16 : 40
        func rowFrame(_ index: Int) -> CGRect {
            CGRect(x: rowInset, y: CGFloat(index) * pitch, width: width - rowInset * 2, height: pitch - 8)
        }

        // The classic bar slides from row to row, as the menus' does.
        if !isModern, let focus, focus >= 0, focus < count {
            let frame = rowFrame(focus)
            let spill = frame.height / 75
            let appearing = selection.layer.isHidden || lastSelectionIndex == nil
            selection.layer.isHidden = false
            selection.update(
                frame: frame.insetBy(dx: -40 * spill, dy: -29 * spill),
                selectionBoxHeight: frame.height,
                // On the list's own curve, so when the list scrolls under it, it stays still.
                animation: appearing ? nil : (lastSelectionIndex != focus ? (pass.animation ?? .easeInOut(duration: 0.2)) : nil),
            )
            lastSelectionIndex = focus
        } else {
            selection.layer.isHidden = true
            lastSelectionIndex = nil
        }

        for index in range {
            guard let content = menu.nowPlayingQueueRow(index) else { continue }
            let row = rows[index] ?? {
                let made = spare.popLast() ?? {
                    let fresh = Row()
                    rowsContainer.addSublayer(fresh.layer)
                    return fresh
                }()
                made.layer.isHidden = false
                rows[index] = made
                return made
            }()
            update(row, index: index, content: content, frame: rowFrame(index), isPlaying: active == index, isFocused: focus == index, isModern: isModern, scale: scale)
        }
    }

    private static let focusAnimation = Animation.smooth(duration: ModernTheme.focusDuration)
    private static let unfocusAnimation = Animation.smooth(duration: 0.22)

    private func update(_ row: Row, index: Int, content: (title: String, detail: String), frame: CGRect, isPlaying: Bool, isFocused focused: Bool, isModern: Bool, scale: CGFloat) {
        let sameRow = row.index == index
        let wasFocused = sameRow && row.isFocused
        row.index = index
        row.layer.frame = frame
        let size = frame.size

        // Each ink drawn once per song, size and look: the light one for every row, the dark
        // one (the modern look's, on its white focus capsule) once its row is focused.
        let key = Row.ContentKey(title: content.title, detail: content.detail, isPlaying: isPlaying, isModern: isModern, scale: scale, width: size.width)
        var inks: [(Row.Ink, RGBA, RGBA)] = []
        if key != row.contentKey {
            row.contentKey = key
            inks.append((row.light, isModern ? ModernTheme.text : RGBA(white: 1, alpha: 0.96), isModern ? ModernTheme.secondaryText : RGBA(white: 1, alpha: 0.6)))
        }
        if isModern, focused, key != row.darkKey {
            row.darkKey = key
            inks.append((row.dark, ModernTheme.focusedText, ModernTheme.focusedSecondaryText))
        }
        if !inks.isEmpty {
            let titleFont = isModern ? ModernTheme.mediumFontName : firstRowBoldFontName
            let detailFont = isModern ? ModernTheme.regularFontName : firstRowRegularFontName
            for (ink, primary, secondary) in inks {
                ink.layer.frame = CGRect(origin: .zero, size: size)
                var right = size.width - 26
                if isPlaying {
                    let glyph = SymbolRenderer.render("speaker.wave.3.fill", pointSize: 24, weight: .semibold, color: primary, scale: scale)
                    ink.speaker.isHidden = false
                    ink.speaker.show(glyph, at: CGPoint(x: right - glyph.size.width, y: ((size.height - glyph.size.height) / 2).rounded()))
                    right -= glyph.size.width + 16
                } else {
                    ink.speaker.isHidden = true
                }
                let textWidth = max(40, right - 26)
                let titleGraphic = TextRenderer.render(TextSpec(text: content.title, fontName: titleFont, size: 27, color: primary, maxWidth: textWidth), scale: scale)
                let detailGraphic = TextRenderer.render(TextSpec(text: content.detail, fontName: detailFont, size: 20, color: secondary, maxWidth: textWidth), scale: scale)
                let block = titleGraphic.size.height + 2 + detailGraphic.size.height
                let top = ((size.height - block) / 2).rounded()
                ink.title.show(titleGraphic, at: CGPoint(x: 26, y: top))
                ink.detail.show(detailGraphic, at: CGPoint(x: 26, y: top + titleGraphic.size.height + 2))
            }
        }

        guard isModern else {
            // Classic: plain text; the bar behind does the picking out.
            row.shadowCaster.isHidden = true
            row.capsule.isHidden = true
            row.dark.layer.isHidden = true
            row.light.layer.isHidden = false
            row.light.layer.setOpacity(1, nil)
            row.content.setTransform(CATransform3DIdentity, nil)
            row.content.place(CGRect(origin: .zero, size: size))
            row.isFocused = focused
            return
        }
        row.shadowCaster.isHidden = false
        row.capsule.isHidden = false

        // As the menus' rows: focus arrives at once and grows; it leaves with a quick fade.
        let changed = sameRow && wasFocused != focused
        let growth: Animation? = changed ? Self.focusAnimation : nil
        let unfocus: Animation? = changed && !focused ? Self.unfocusAnimation : nil
        let focusChanged = !sameRow || wasFocused != focused
        row.isFocused = focused
        let rest = CGRect(origin: .zero, size: size)
        let grow = ModernTheme.focusGrowth
        let capsuleFrame = focused ? rest.insetBy(dx: -grow.width, dy: -grow.height) : rest
        if focusChanged {
            row.capsule.set("backgroundColor", to: (focused ? ModernTheme.focusFill : ModernTheme.rowFill).cgColor, unchanged: false, animation: unfocus)
            row.shadowCaster.set("shadowOpacity", to: Float(focused ? 0.75 : 0.6), unchanged: false, animation: unfocus ?? growth)
        }
        if size != row.shadowSize {
            row.shadowSize = size
            let radius = size.height / 2
            row.shadowCaster.shadowPath = CGPath(roundedRect: rest, cornerWidth: radius, cornerHeight: radius, transform: nil)
            let reach: CGFloat = 48
            row.shadowCutout.frame = rest.insetBy(dx: -reach, dy: -reach)
            let cutout = CGMutablePath()
            cutout.addRect(CGRect(x: 0, y: 0, width: size.width + reach * 2, height: size.height + reach * 2))
            let hole = CGRect(x: reach + 0.5, y: reach + 0.5, width: size.width - 1, height: size.height - 1)
            cutout.addPath(CGPath(roundedRect: hole, cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil))
            row.shadowCutout.path = cutout
        }
        row.shadowCaster.frame = rest
        row.capsule.setFrame(capsuleFrame, growth)
        row.capsule.set("cornerRadius", to: capsuleFrame.height / 2, unchanged: row.capsule.cornerRadius == capsuleFrame.height / 2, animation: growth)
        row.content.place(rest)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var grown = CATransform3DMakeTranslation(center.x, center.y, 0)
        grown = CATransform3DScale(grown, ModernTheme.focusedContentScale, ModernTheme.focusedContentScale, 1)
        grown = CATransform3DTranslate(grown, -center.x, -center.y, 0)
        row.content.setTransform(focused ? grown : CATransform3DIdentity, growth)
        if focused {
            row.light.layer.isHidden = true
            row.dark.layer.isHidden = false
            if focusChanged { row.dark.layer.setOpacity(1, nil) }
        } else {
            row.light.layer.isHidden = false
            if let unfocus {
                // The dark text, as it was, fades out over the light text fading in.
                row.light.layer.setOpacity(0, nil)
                row.light.layer.setOpacity(1, unfocus)
                row.dark.layer.setOpacity(0, unfocus)
            } else if focusChanged {
                row.light.layer.setOpacity(1, nil)
                row.dark.layer.isHidden = true
            }
        }
    }
}

// MARK: - Lyrics

/// The song's words beside Now Playing, large: with times, the line being sung is bright and
/// held a third of the way down as the others go by; without, they scroll along with the song.
@MainActor
final class NowPlayingLyricsLayer {
    let layer = SceneLayer()
    private let clip = SceneLayer()
    private let fade = SceneGradientLayer()
    private let column = SceneLayer()
    private var lineLayers: [SceneLayer] = []
    private var lineTops: [CGFloat] = []
    private var contentHeight: CGFloat = 0
    private var builtKey = ""
    private var lastLine: Int?

    /// One line of the words in the modern look, a layer of its own: its lettering, and softer
    /// (out of focus) copies of it for when it is further from the line being sung.
    private final class Line {
        let layer = SceneLayer()
        let sharp = SceneLayer()
        var soft: [SceneLayer?] = [nil, nil, nil]
        /// Each softer copy: not asked for (0), being made (1), there (2).
        var softState = [0, 0, 0]
        var graphic: RenderedGraphic?
        var top: CGFloat = 0
        var height: CGFloat = 0
        /// How it shows now: how soft (0 is sharp) and how strongly, and whether it has a place yet.
        var softness = -1
        var strength: Double = -1
        var isPlaced = false
        /// On its way off the screen until then (it is put away once it has gone).
        var awayAt: CFTimeInterval = 0
    }

    private var lines: [Line] = []
    private var isLaidOut = false
    private var wasShown = false
    /// When the lines' last move to new places is over.
    private var movesSettleAt: CFTimeInterval = 0

    init() {
        layer.addSublayer(clip)
        clip.masksToBounds = true
        clip.addSublayer(column)
        clip.mask = fade
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        fade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        fade.locations = [0, 0.14, 0.84, 1]
        layer.opacity = 0
        layer.isHidden = true
    }

    func update(menu: MenuView, pass: RenderPass, size: CGSize, scale: CGFloat, canvasScale: CGFloat = 1) {
        layer.frame = CGRect(origin: .zero, size: size)
        // Standing upright they come in once the song's details have left the part under the
        // fold, and are gone before those come back. (With the whole screen under a heading
        // they wait a little longer, for the cover to be most of the way up to it.)
        let glide = menu.upright == nil ? nil : menu.nowPlayingWordsGlide
        let isModern = ModernTheme.isActive
        let lyingDown = menu.upright == nil
        // (The classic look's songs change over by one zooming away and the next zooming in,
        // through where the words are: they are away for that, and come back after it.)
        let isChangingSong = !isModern && menu.musicSongTransitionSnapshot != nil
        let shown = (menu.isNowPlayingLyricsVisible || glide != nil) && menu.hasNowPlayingLyrics && !isChangingSong
        if shown { layer.isHidden = false }
        let heading = NowPlayingSideLayout.heading(menu: menu, canvasScale: canvasScale)
        let glided = glide.map { heading == nil ? min(max(($0 - 0.5) / 0.5, 0), 1) : min(max(($0 - 0.62) / 0.38, 0), 1) } ?? 1
        // (The list comes out over them: they fade as it does, and come back as it goes.)
        let opacity = Double(glided * NowPlayingSideLayout.wordsStrength(menu: menu))
        let appearing = shown && !wasShown
        if !shown {
            // Away quickly where nothing else says how: a song changing, the modern look's
            // words lying down (which the rest then moves over).
            layer.setOpacity(0, isModern ? (lyingDown ? .easeOut(duration: 0.14) : pass.animation) : (pass.animation ?? .easeOut(duration: 0.15)))
        } else if isModern, lyingDown {
            // Lying down each line comes for itself (see `updateModern`).
            layer.setOpacity(opacity, appearing ? nil : pass.animation)
        } else {
            // (Back for a new song they fade in, rather than being there at once.)
            layer.setOpacity(opacity, appearing && glide == nil ? pass.animation ?? .smooth(duration: 0.3) : pass.animation)
        }
        guard shown, let lyrics = menu.nowPlayingLyrics else {
            // (Hidden once they have faded. What they said stays as it was until then: the
            // next song's words are not put in their place while they go.)
            if layer.opacity == 0, layer.animation(forKey: "opacity") == nil { layer.isHidden = true }
            wasShown = false
            return
        }
        wasShown = true
        let area = NowPlayingSideLayout.lyricsFrame(size, upright: menu.upright, heading: heading)
        // (In the modern look the lines further off are out of focus, and spread a little past
        // their lettering: the clip leaves them room at the sides.)
        let pad: CGFloat = isModern ? 28 : 0
        clip.frame = area.insetBy(dx: -pad, dy: 0)
        fade.frame = CGRect(origin: .zero, size: clip.frame.size)
        // The foot of the screen is the on-screen buttons': the words fade out above them
        // (above the one in the corner, or the whole row where that is along the bottom, as
        // it is under a heading and in the classic look).
        var strip: CGFloat = 0
        if let buttons = TouchControlsLayer.nowPlayingButtons(menu: menu)?.scaled(by: 1 / max(canvasScale, 0.0001)) {
            strip = heading != nil || !isModern ? max(buttons.cornerStrip, buttons.play + buttons.bottomMargin + 12) : buttons.cornerStrip
        }
        if isModern {
            updateModern(lyrics, menu: menu, shown: shown, appearing: appearing, area: area, pad: pad, strip: strip, size: size, scale: scale, underHeading: heading != nil)
            return
        }
        if !lines.isEmpty {
            for line in lines { line.layer.removeFromSuperlayer() }
            lines = []
            builtKey = ""
        }
        // (With no buttons on the screen the words fade over its last sixth, as ever.)
        let depth = max(1, area.height)
        fade.locations = [0, 0.14, NSNumber(value: Double(max(0.5, 1 - (strip + depth * 0.16) / depth))), NSNumber(value: Double(max(0.6, 1 - strip / depth)))]

        // Every line drawn once per song (and size), each its own layer.
        let key = "\(menu.nowPlayingLyricsSongID ?? "")|\(lyrics.lines.count)|\(area.width)|\(scale)|\(isModern)"
        if key != builtKey {
            builtKey = key
            lastLine = nil
            for line in lineLayers { line.removeFromSuperlayer() }
            lineLayers = []
            lineTops = []
            var y: CGFloat = 0
            for line in lyrics.lines {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                let lineLayer = SceneLayer()
                if text.isEmpty {
                    // A break between verses.
                    lineTops.append(y)
                    y += 34
                } else {
                    let graphic = TextRenderer.render(TextSpec(
                        text: text,
                        fontName: isModern ? ModernTheme.boldFontName : firstRowBoldFontName,
                        size: 50,
                        color: .white,
                        wrapWidth: area.width,
                        lineSpacing: 4,
                    ), scale: scale)
                    lineLayer.show(graphic, at: CGPoint(x: 0, y: y))
                    lineTops.append(y)
                    y += graphic.size.height + 26
                }
                column.addSublayer(lineLayer)
                lineLayers.append(lineLayer)
            }
            contentHeight = y
            column.bounds = CGRect(x: 0, y: 0, width: area.width, height: max(y, 1))
        }

        let elapsed = menu.musicNowPlayingElapsedSeconds
        let anchor = area.height * 0.34
        if lyrics.isSynced {
            let current = lyrics.currentLineIndex(at: elapsed + 0.2)
            // (-1 before the first line is sung: the move to it from there is a move too.)
            let now = current ?? -1
            if now != lastLine || pass.animation == nil {
                let changed = lastLine != nil && now != lastLine
                lastLine = now
                let move: Animation? = changed ? .smooth(duration: 0.55) : nil
                let top = current.flatMap { lineTops.indices.contains($0) ? lineTops[$0] : nil } ?? -anchor * 0.5
                column.setPosition(CGPoint(x: 0, y: anchor - top), move)
                for (index, line) in lineLayers.enumerated() {
                    line.setOpacity(index == current ? 1 : 0.3, move)
                }
            }
        } else {
            // Without times, the words move up through the song at its pace.
            let duration = max(1, menu.musicNowPlayingDurationSeconds)
            let progress = CGFloat(min(1, max(0, elapsed / duration)))
            let travel = max(0, contentHeight - area.height * 0.5)
            column.setPosition(CGPoint(x: 0, y: anchor - travel * progress), lastLine == nil ? nil : .linear(duration: 0.5))
            if lastLine == nil {
                for line in lineLayers { line.setOpacity(0.85, nil) }
            }
            lastLine = -1
        }
    }

    // MARK: - The modern look

    /// The words in the modern look: large lines down the right half (or, standing upright,
    /// under the fold), the one being sung bright and sharp near the top, the ones to come
    /// under it fainter and softer the further off they are, and the one just sung fading out
    /// above. As the song moves on each line goes up to its new place, the lower ones setting
    /// off a moment after the ones above them.
    private func updateModern(_ lyrics: MusicLyrics, menu: MenuView, shown: Bool, appearing: Bool, area: CGRect, pad: CGFloat, strip: CGFloat, size: CGSize, scale: CGFloat, underHeading: Bool) {
        if !lineLayers.isEmpty {
            for line in lineLayers { line.removeFromSuperlayer() }
            lineLayers = []
            lineTops = []
        }
        let fontSize = min(84, max(44, (size.height * 0.051).rounded()))
        let between = (fontSize * 0.8).rounded()
        // The line being sung starts this far down; what is above it fades out toward the top
        // edge, and what is far below it toward the bottom.
        let anchor = (size.height * 0.123).rounded()
        let height = max(1, area.height)
        // (Under a heading the line just sung shows whole between it and the one being sung.)
        let rise = underHeading ? 40 : size.height * 0.085
        let foot = max(size.height * 0.02, strip)
        fade.locations = [0, NSNumber(value: Double(min(0.4, rise / height))), NSNumber(value: Double(max(0.5, 1 - (foot + size.height * 0.18) / height))), NSNumber(value: Double(max(0.6, 1 - foot / height)))]

        let key = "\(menu.nowPlayingLyricsSongID ?? "")|\(lyrics.lines.count)|\(area.width)|\(scale)|\(fontSize)|modern"
        if key != builtKey {
            builtKey = key
            lastLine = nil
            isLaidOut = false
            for line in lines { line.layer.removeFromSuperlayer() }
            lines = []
            var y: CGFloat = 0
            for entry in lyrics.lines {
                let line = Line()
                let text = entry.text.trimmingCharacters(in: .whitespaces)
                line.top = y
                if text.isEmpty {
                    // A break between verses.
                    y += (between * 0.8).rounded()
                } else {
                    let graphic = TextRenderer.render(TextSpec(
                        text: text,
                        fontName: ModernTheme.boldFontName,
                        size: fontSize,
                        color: .white,
                        wrapWidth: area.width,
                        lineSpacing: (fontSize * 0.08).rounded(),
                    ), scale: scale)
                    line.graphic = graphic
                    line.height = graphic.size.height
                    line.sharp.show(graphic, at: .zero)
                    line.layer.addSublayer(line.sharp)
                    y += graphic.size.height + between
                }
                line.layer.isHidden = true
                clip.addSublayer(line.layer)
                lines.append(line)
            }
            contentHeight = y
        }
        guard !lines.isEmpty else { return }

        let elapsed = menu.musicNowPlayingElapsedSeconds
        let synced = lyrics.isSynced
        let current = synced ? lyrics.currentLineIndex(at: elapsed + 0.2) : nil
        // The line that has the place near the top: the one being sung, or before the first of
        // them, the first.
        let lead = current ?? 0
        let jumped = lastLine.map { abs($0 - (current ?? -1)) > 2 } ?? false
        let changed = isLaidOut && synced && lastLine != (current ?? -1)
        lastLine = current ?? -1
        let move: Animation? = changed ? .smooth(duration: 0.5) : nil
        let look: Animation? = changed ? .smooth(duration: 0.36) : nil
        var scrolled: CGFloat = 0
        if !synced {
            // Without times, the words move up through the song at its pace.
            let duration = max(1, menu.musicNowPlayingDurationSeconds)
            let progress = CGFloat(min(1, max(0, elapsed / duration)))
            scrolled = max(0, contentHeight - area.height * 0.5) * progress
        }
        let leadTop = synced ? lines[min(lead, lines.count - 1)].top : scrolled
        // One line on, the lower lines set off a moment after the ones above them. Further
        // than that, while the song is being wound through, or with the last move still under
        // way, they all go together: a line made to wait its turn again and again would be
        // left behind by the others, out of step with them and over them.
        let now = CACurrentMediaTime()
        let together = jumped || menu.musicScrubDirection != 0 || now < movesSettleAt
        if changed { movesSettleAt = now + 0.5 }
        let glide: Animation? = synced ? move : (isLaidOut ? .linear(duration: 0.5) : nil)
        // How far each line that is up is from where it is going. One that comes up while they
        // are on their way starts as far from its own place, and one that goes off the screen
        // goes there with them: the lines keep their spacing however far the song jumps.
        var offsets = [CGFloat?](repeating: nil, count: glide == nil ? 0 : lines.count)
        if glide != nil {
            for (index, line) in lines.enumerated() where line.isPlaced && !line.layer.isHidden {
                offsets[index] = (line.layer.presentation()?.position.y ?? line.layer.position.y) - (anchor + line.top - leadTop)
            }
            // (Each of the others goes by the nearest one that is up: above it, or failing
            // that below.)
            var nearest: CGFloat?
            for index in offsets.indices {
                if let offset = offsets[index] { nearest = offset } else { offsets[index] = nearest }
            }
            nearest = nil
            for index in offsets.indices.reversed() {
                if let offset = offsets[index] { nearest = offset } else { offsets[index] = nearest }
            }
        }
        var order = 0
        for (index, line) in lines.enumerated() {
            let y = anchor + line.top - leadTop
            let place = CGPoint(x: pad, y: y)
            let wait = synced && changed && !together ? min(0.3, 0.045 * Double(max(0, index - lead))) : 0
            let lineGlide = glide.map { wait > 0 ? $0.delay(wait) : $0 }
            // Only what is on the screen, or just off it, is kept up.
            let near = y > -line.height - size.height * 0.3 && y < area.height + size.height * 0.3
            guard near, line.graphic != nil else {
                guard !line.layer.isHidden else { continue }
                if line.isPlaced, line.awayAt == 0, let lineGlide {
                    line.awayAt = now + wait + lineGlide.duration
                }
                if now < line.awayAt {
                    line.layer.setPosition(place, lineGlide)
                } else {
                    line.layer.isHidden = true
                    line.isPlaced = false
                    line.awayAt = 0
                }
                continue
            }
            let distance = index - (current ?? -1)
            let softness: Int
            let strength: Double
            if !synced {
                softness = 0
                strength = 0.8
            } else if distance == 0 {
                softness = 0
                strength = 1
            } else if distance > 0 {
                softness = min(3, distance)
                strength = distance == 1 ? 0.27 : (distance == 2 ? 0.23 : 0.2)
            } else {
                softness = 2
                strength = distance == -1 ? 0.16 : 0
            }
            let fresh = line.layer.isHidden || !line.isPlaced
            line.layer.isHidden = false
            line.isPlaced = true
            line.awayAt = 0
            if fresh {
                // (Just come near enough to be kept up: put as far from where it belongs as
                // the others are, to go there with them.)
                let offset = lineGlide == nil ? 0 : offsets[index] ?? 0
                line.layer.setPosition(CGPoint(x: pad, y: y + offset), nil)
            }
            line.layer.setPosition(place, lineGlide)
            show(line, softness: softness, strength: strength, fontSize: fontSize, scale: scale, animation: fresh ? nil : look)
            if appearing, menu.upright == nil {
                // Coming up beside the song, the lines come in one after another from the top,
                // once the song has begun to make way for them.
                line.layer.opacity = 0
                line.layer.setOpacity(1, Animation.smooth(duration: 0.36).delay(0.12 + 0.035 * Double(order)))
                order += 1
            } else if fresh {
                line.layer.setOpacity(1, nil)
            }
        }
        isLaidOut = true
    }

    /// Shows a line as soft and as strong as it is to be: its sharp lettering, or the softer
    /// copy for that softness once that has been made (until then the sharp one stands in).
    private func show(_ line: Line, softness: Int, strength: Double, fontSize: CGFloat, scale: CGFloat, animation: Animation?) {
        var copy = softness - 1
        #if FIRSTROW_PORTABLE
            copy = -1
        #else
            if copy >= 0, line.softState[copy] != 2 {
                makeSoftCopy(of: line, copy, fontSize: fontSize, scale: scale)
                copy = -1
            }
        #endif
        guard softness != line.softness || strength != line.strength || animation == nil else { return }
        line.softness = softness
        line.strength = strength
        line.sharp.setOpacity(copy < 0 ? strength : 0, animation)
        for (index, soft) in line.soft.enumerated() {
            soft?.setOpacity(index == copy ? strength : 0, animation)
        }
    }

    #if !FIRSTROW_PORTABLE
        /// How soft each copy is, against the size of the lettering.
        private nonisolated static let softening: [CGFloat] = [0.024, 0.05, 0.08]

        /// Makes a line's softer copy on another thread, and brings it in when it is done.
        private func makeSoftCopy(of line: Line, _ copy: Int, fontSize: CGFloat, scale: CGFloat) {
            guard line.softState[copy] == 0, let graphic = line.graphic else { return }
            line.softState[copy] = 1
            let built = builtKey
            let sigma = fontSize * Self.softening[copy]
            LetteringInProgress.queue.async {
                let made = Self.softened(graphic, sigma: sigma, scale: scale)
                DispatchQueue.main.async {
                    MainActor.assumeIsolatedIfPossible {
                        guard self.builtKey == built, line.softState[copy] == 1, let made else { return }
                        let soft = SceneLayer()
                        withoutLayerActions {
                            soft.contents = made.image
                            soft.frame = made.frame
                            soft.opacity = 0
                            line.layer.addSublayer(soft)
                        }
                        line.soft[copy] = soft
                        line.softState[copy] = 2
                        // It takes over from whatever stood in for it, if it is still wanted.
                        if line.softness == copy + 1 {
                            let strength = line.strength
                            line.sharp.setOpacity(0, .smooth(duration: 0.2))
                            for (index, other) in line.soft.enumerated() {
                                other?.setOpacity(index == copy ? strength : 0, .smooth(duration: 0.2))
                            }
                        }
                    }
                }
            }
        }

        /// The lettering out of focus by `sigma` points: drawn smaller (blurred, it needs no
        /// more) with room around it for the blur to spread into, and where that sits against
        /// the lettering's own origin.
        private nonisolated static func softened(_ graphic: RenderedGraphic, sigma: CGFloat, scale: CGFloat) -> (image: CGImage, frame: CGRect)? {
            guard let image = graphic.image else { return nil }
            let box = graphic.imageFrame(at: .zero)
            let density = min(scale, max(0.75, 2.4 / sigma))
            let margin = (sigma * 3).rounded(.up)
            let width = Int(((box.width + margin * 2) * density).rounded(.up))
            let height = Int(((box.height + margin * 2) * density).rounded(.up))
            guard width > 0, height > 0, let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo,
            ) else { return nil }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: margin * density, y: margin * density, width: box.width * density, height: box.height * density))
            guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            // Three box blurs come close to a Gaussian one of this spread.
            let radius = max(1, Int((sigma * density - 0.5).rounded()))
            for _ in 0 ..< 3 {
                for y in 0 ..< height {
                    TouchControlsLayer.boxBlur(data + y * context.bytesPerRow, count: width, stride: 4, radius: radius)
                }
                for x in 0 ..< width {
                    TouchControlsLayer.boxBlur(data + x * 4, count: height, stride: context.bytesPerRow, radius: radius)
                }
            }
            guard let blurred = context.makeImage() else { return nil }
            return (blurred, CGRect(x: box.minX - margin, y: box.minY - margin, width: CGFloat(width) / density, height: CGFloat(height) / density))
        }
    #endif
}
