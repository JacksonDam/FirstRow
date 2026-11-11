import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// A YouTube video's caption line, over the foot of the picture.
@MainActor
final class YouTubeCaptionLayer {
    let layer = SceneLayer()
    private let line = SceneLayer()

    init() {
        layer.addSublayer(line)
        line.isHidden = true
    }

    /// `raised` while the transport bar is up, so the line clears it; `width` is how much of
    /// the picture's width is clear of the comments.
    func update(text: String?, raised: Bool, width: CGFloat, size: CGSize, scale: CGFloat, pass _: RenderPass) {
        guard let text, !text.isEmpty else {
            line.isHidden = true
            return
        }
        let graphic = TextRenderer.render(TextSpec(
            text: text,
            fontName: ModernTheme.isActive ? ModernTheme.mediumFontName : firstRowBoldFontName,
            size: 44,
            color: .white,
            wrapWidth: width * 0.78,
            alignment: .center,
            lineSpacing: 4,
            shadows: [
                TextShadow(color: RGBA(white: 0, alpha: 0.95), radius: 2.5),
                TextShadow(color: RGBA(white: 0, alpha: 0.85), radius: 6, offset: CGSize(width: 0, height: 2)),
            ],
        ), scale: scale)
        line.isHidden = false
        let foot = size.height - (raised ? 196 : 76)
        line.show(graphic, at: CGPoint(x: ((width - graphic.size.width) / 2).rounded(), y: (foot - graphic.size.height).rounded()))
    }
}

/// A YouTube video's comments: a panel over the right of the picture, one comment picked out,
/// the list moving under it as up and down go through them.
@MainActor
final class YouTubeCommentsLayer {
    let layer = SceneLayer()
    private let panel = SceneLayer()
    private let title = SceneLayer()
    private let count = SceneLayer()
    private let message = SceneLayer()
    private let clip = SceneLayer()
    private let list = SceneLayer()
    private var blocks: [String: Block] = [:]
    /// What the panel last showed, kept while it slides away.
    private var shown: YouTubeCommentsState?
    private var lastFocus: Int?
    private var lastOffset: CGFloat = 0
    /// The panel in canvas points, while it's out (for clicks and touches).
    private(set) var panelFrame: CGRect?

    /// How wide the panel is on a canvas of this size.
    static func width(in size: CGSize) -> CGFloat {
        min(840, (size.width * 0.44).rounded())
    }

    private final class Block {
        let layer = SceneLayer()
        let author = SceneLayer()
        let when = SceneLayer()
        let text = SceneLayer()
        let footer = SceneLayer()
        var key = ""
        var height: CGFloat = 0

        init() {
            for sublayer in [author, when, text, footer] { layer.addSublayer(sublayer) }
        }
    }

    init() {
        layer.addSublayer(panel)
        panel.isHidden = true
        panel.masksToBounds = true
        for sublayer in [title, count, message, clip] { panel.addSublayer(sublayer) }
        clip.masksToBounds = true
        clip.addSublayer(list)
    }

    func update(menu: MenuView, size: CGSize, scale: CGFloat, pass: RenderPass) {
        let state = menu.isMoviePlaybackVisible ? menu.youtubeComments : nil
        if let state { shown = state }
        let reveal = state == nil ? 0 : menu.youtubeCommentsReveal
        guard let content = shown else {
            panel.isHidden = true
            panelFrame = nil
            return
        }
        if state == nil, panel.opacity < 0.01 {
            // Away and out of sight: let go of its comments.
            shown = nil
            for block in blocks.values { block.layer.removeFromSuperlayer() }
            blocks = [:]
            lastFocus = nil
            panel.isHidden = true
            panelFrame = nil
            return
        }
        let isModern = ModernTheme.isActive
        let width = Self.width(in: size)
        let frame = CGRect(x: size.width - width, y: 0, width: width, height: size.height)
        let wasHidden = panel.isHidden
        panel.isHidden = false
        panel.place(frame)
        panel.backgroundColor = CGColor(gray: isModern ? 0.07 : 0, alpha: isModern ? 0.86 : 0.84)
        let away = CATransform3DMakeTranslation(width, 0, 0)
        if wasHidden {
            panel.setTransform(away, nil)
            panel.setOpacity(0, nil)
        }
        let move = pass.animation
        panel.setTransform(reveal > 0.5 ? CATransform3DIdentity : away, move)
        panel.setOpacity(reveal > 0.5 ? 1 : 0, move)
        panelFrame = reveal > 0.5 ? frame : nil

        let inset: CGFloat = 44
        let column = width - inset * 2
        let bold = isModern ? ModernTheme.boldFontName : firstRowBoldFontName
        let medium = isModern ? ModernTheme.mediumFontName : firstRowBoldFontName
        let regular = isModern ? ModernTheme.regularFontName : firstRowRegularFontName
        let titleGraphic = TextRenderer.render(TextSpec(text: "Comments", fontName: bold, size: 44), scale: scale)
        title.show(titleGraphic, at: CGPoint(x: inset, y: 54))
        // "5,240 Comments" as "5,240" beside the title.
        let total = content.totalText?.split(separator: " ").first.map(String.init) ?? ""
        let countGraphic = TextRenderer.render(TextSpec(text: total, fontName: regular, size: 30, color: RGBA(white: 1, alpha: 0.55)), scale: scale)
        count.isHidden = total.isEmpty
        count.show(countGraphic, at: CGPoint(x: inset + titleGraphic.size.width + 18, y: 54 + titleGraphic.size.height - countGraphic.size.height - 4))

        let top = 54 + titleGraphic.size.height + 30
        let viewport = CGRect(x: 0, y: top, width: width, height: size.height - top - 40)
        clip.place(viewport)

        let note = content.isLoading ? "Loading..." : (content.comments.isEmpty ? (content.error ?? "") : "")
        message.isHidden = note.isEmpty
        if !note.isEmpty {
            let graphic = TextRenderer.render(TextSpec(text: note, fontName: regular, size: 30, color: RGBA(white: 1, alpha: 0.6), wrapWidth: column), scale: scale)
            message.show(graphic, at: CGPoint(x: inset, y: top + 8))
        }

        // The comments from the top to a little past the one picked out are laid out (each
        // one's height is only known once its text is set); the rest wait their turn.
        let focus = min(max(0, content.focused), max(0, content.comments.count - 1))
        let prepared = min(content.comments.count, focus + 10)
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        var live = Set<String>()
        for index in 0 ..< prepared {
            let comment = content.comments[index]
            live.insert(comment.id)
            let block: Block
            if let known = blocks[comment.id] {
                block = known
            } else {
                block = Block()
                blocks[comment.id] = block
                list.addSublayer(block.layer)
            }
            let key = "\(column)|\(scale)|\(isModern)"
            if block.key != key {
                block.key = key
                let authorGraphic = TextRenderer.render(TextSpec(text: comment.author, fontName: medium, size: 26, color: RGBA(white: 1, alpha: 0.92), maxWidth: column * 0.62), scale: scale)
                block.author.show(authorGraphic, at: .zero)
                var whenText = comment.publishedText
                if comment.isPinned { whenText = whenText.isEmpty ? "Pinned" : "Pinned, " + whenText }
                let whenGraphic = TextRenderer.render(TextSpec(text: whenText, fontName: regular, size: 22, color: RGBA(white: 1, alpha: 0.5), maxWidth: column * 0.34), scale: scale)
                block.when.show(whenGraphic, at: CGPoint(x: authorGraphic.size.width + 14, y: authorGraphic.size.height - whenGraphic.size.height - 2))
                var words = comment.text
                if words.count > 700 { words = String(words.prefix(700)) + "…" }
                let textGraphic = TextRenderer.render(TextSpec(text: words, fontName: regular, size: 28, color: .white, wrapWidth: column, lineSpacing: 3), scale: scale)
                let textTop = authorGraphic.size.height + 8
                block.text.show(textGraphic, at: CGPoint(x: 0, y: textTop))
                var parts: [String] = []
                if !comment.likesText.isEmpty { parts.append(comment.likesText == "1" ? "1 like" : "\(comment.likesText) likes") }
                if !comment.replyCountText.isEmpty { parts.append(comment.replyCountText == "1" ? "1 reply" : "\(comment.replyCountText) replies") }
                if comment.isHearted { parts.append("liked by the creator") }
                let footerGraphic = TextRenderer.render(TextSpec(text: parts.joined(separator: ", "), fontName: regular, size: 22, color: RGBA(white: 1, alpha: 0.5), maxWidth: column), scale: scale)
                block.footer.isHidden = parts.isEmpty
                let footerTop = textTop + textGraphic.size.height + 8
                block.footer.show(footerGraphic, at: CGPoint(x: 0, y: footerTop))
                block.height = parts.isEmpty ? textTop + textGraphic.size.height : footerTop + footerGraphic.size.height
            }
            tops.append(y)
            block.layer.frame = CGRect(x: inset, y: y, width: column, height: block.height)
            block.layer.setOpacity(index == focus ? 1 : 0.42, pass.animation(.easeInOut(duration: 0.2), when: lastFocus != nil && lastFocus != focus))
            y += block.height + 34
        }
        for (id, block) in blocks where !live.contains(id) {
            block.layer.removeFromSuperlayer()
            blocks[id] = nil
        }
        // The one picked out sits at the top of the list, until the list's end comes up.
        let contentHeight = max(0, y - 34)
        let wanted = tops.indices.contains(focus) ? tops[focus] : 0
        let offset = prepared == content.comments.count ? min(wanted, max(0, contentHeight - viewport.height)) : wanted
        let slides = lastFocus != nil && lastFocus != focus && !wasHidden
        list.setFrame(CGRect(x: 0, y: -offset, width: width, height: max(contentHeight, 1)), slides ? .easeInOut(duration: 0.22) : (offset == lastOffset ? nil : pass.animation))
        lastFocus = focus
        lastOffset = offset
    }
}
