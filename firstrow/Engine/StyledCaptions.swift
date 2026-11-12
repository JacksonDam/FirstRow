#if !FIRSTROW_PORTABLE
    import CoreGraphics
    import CoreText
    import Foundation

    // Subtitles whose words differ from one another: some bold, some slanted, some underlined,
    // some in a colour of their own. (Plain ones are drawn as any other line of text is.) These
    // come from the engine, which reads them out of the movie or the file beside it; on Linux
    // and Windows mpv draws a movie's subtitles itself.

    enum StyledCaptions {
        /// What tells one set of subtitles from another, for keeping the last drawn.
        static func key(_ captions: [MovieCaption]) -> String {
            captions.map { caption in
                let runs = caption.runs.isEmpty ? [MovieCaption.Run(text: caption.text ?? "")] : caption.runs
                return runs.map { "\($0.text)|\($0.isBold)\($0.isItalic)\($0.isUnderlined)\($0.color ?? -1)" }.joined(separator: "\u{1}")
            }.joined(separator: "\u{2}")
        }

        /// Whether any of them has words that aren't plain.
        static func areStyled(_ captions: [MovieCaption]) -> Bool {
            captions.contains { $0.runs.contains { $0.isBold || $0.isItalic || $0.isUnderlined || $0.color != nil } }
        }

        /// The subtitles' lines one under another, centred, each word in its own style.
        static func render(_ captions: [MovieCaption], fontName: String, size: CGFloat, wrapWidth: CGFloat, lineSpacing: CGFloat, shadows: [TextShadow], scale: CGFloat) -> RenderedGraphic {
            let plain = FontMetrics.font(fontName, size: size)
            let text = CFAttributedStringCreateMutable(nil, 0)!
            func add(_ words: String, _ run: MovieCaption.Run?) {
                var font = plain
                var attributes: [CFString: Any] = [:]
                var traits: CTFontSymbolicTraits = []
                if run?.isBold == true { traits.insert(.traitBold) }
                if run?.isItalic == true { traits.insert(.traitItalic) }
                if traits.contains(.traitItalic) {
                    if let slanted = CTFontCreateCopyWithSymbolicTraits(plain, 0, nil, .traitItalic, .traitItalic) {
                        font = slanted
                    } else {
                        // (The font has no slanted face: its upright one is leant over.)
                        var slant = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
                        font = CTFontCreateCopyWithAttributes(plain, 0, &slant, nil)
                    }
                }
                if traits.contains(.traitBold) {
                    // A bolder face where the font has one that differs from the one in use
                    // (the looks' own lettering is bold or nearly so already); else its letters
                    // are thickened with a stroke of their own colour.
                    let name = CTFontCopyPostScriptName(font) as String
                    if let bolder = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold), (CTFontCopyPostScriptName(bolder) as String) != name {
                        font = bolder
                    } else {
                        attributes[kCTStrokeWidthAttributeName] = -3.5
                    }
                }
                var color = RGBA.white
                if let value = run?.color {
                    color = RGBA(
                        red: CGFloat((value >> 24) & 0xFF) / 255, green: CGFloat((value >> 16) & 0xFF) / 255,
                        blue: CGFloat((value >> 8) & 0xFF) / 255, alpha: CGFloat(value & 0xFF) / 255,
                    )
                }
                attributes[kCTFontAttributeName] = font
                attributes[kCTForegroundColorAttributeName] = color.cgColor
                if run?.isUnderlined == true { attributes[kCTUnderlineStyleAttributeName] = CTUnderlineStyle.single.rawValue }
                let piece = CFAttributedStringCreate(nil, words as CFString, attributes as CFDictionary)!
                CFAttributedStringReplaceAttributedString(text, CFRange(location: CFAttributedStringGetLength(text), length: 0), piece)
            }
            for (index, caption) in captions.enumerated() {
                if index > 0 { add("\n", nil) }
                if caption.runs.isEmpty {
                    add((caption.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines), nil)
                } else {
                    for run in caption.runs { add(run.text, run) }
                }
            }
            // Broken into lines at the width, and at the line ends the subtitle has of its own.
            let typesetter = CTTypesetterCreateWithAttributedString(text)
            let length = CFAttributedStringGetLength(text)
            var lines: [(line: CTLine, width: CGFloat)] = []
            var start = 0
            while start < length {
                let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, wrapWidth)))
                guard count > 0 else { break }
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
                if width > 0.5 { lines.append((line, ceil(width))) }
                start += count
            }
            guard !lines.isEmpty else { return .empty }
            let lineHeight = FontMetrics.lineHeight(plain)
            let baseline = FontMetrics.baseline(plain)
            let boxSize = CGSize(
                width: lines.map(\.width).max() ?? 0,
                height: CGFloat(lines.count) * lineHeight + CGFloat(lines.count - 1) * lineSpacing,
            )
            let padding = ceil(shadows.map { $0.radius * 2.5 + max(abs($0.offset.width), abs($0.offset.height)) }.max() ?? 0) + 2
            return TextRenderer.draw(size: boxSize, padding: padding, scale: scale, shadows: shadows) { context in
                for (index, line) in lines.enumerated() {
                    let x = ((boxSize.width - line.width) * 0.5).rounded()
                    let top = CGFloat(index) * (lineHeight + lineSpacing)
                    // (Bitmap coordinates have y up; lines are placed from the top.)
                    context.textPosition = CGPoint(x: padding + x, y: boxSize.height + padding - top - baseline)
                    CTLineDraw(line.line, context)
                }
            }
        }
    }
#endif
