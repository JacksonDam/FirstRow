import CoreGraphics
import CPortable
import Foundation

/// Draws a layer tree with OpenGL the way Core Animation composites it: each layer flattens
/// its sublayers into its own plane, and masks, blurs, shadows and group opacity render the
/// layer offscreen first.
public final class Compositor {
    nonisolated(unsafe) private static var loaderHook: ((String) -> UnsafeMutableRawPointer?)?

    let device: GLDevice
    private var targetStack: [(framebuffer: GLuint, width: Int, height: Int)] = []
    private var scissor: CGRect?
    private var defaultFramebuffer: GLuint = 0
    /// Layers drawn this frame, whose finished animations are retired afterwards.
    private var visited: [CALayer] = []
    private var shadowCache = ShadowCache()
    private var time: CFTimeInterval = 0
    /// Points to pixels on screen, for picking offscreen resolutions.
    private var screenScale: CGFloat = 1

    /// Whether the last frame had animations still running.
    public private(set) var isAnimating = false

    /// Loads OpenGL with `loader` (for example SDL_GL_GetProcAddress) and builds the shaders.
    public init(loader: @escaping (String) -> UnsafeMutableRawPointer?) throws {
        Self.loaderHook = loader
        let missing = frgl_load { name in
            guard let name else { return nil }
            return Compositor.loaderHook?(String(cString: name))
        }
        if missing > 0 {
            throw CompositorError.loader(Int(missing))
        }
        device = try GLDevice()
    }

    /// Hooks other drawing (such as a video renderer) can use to put GL state back.
    public func resetState() {
        glUseProgram(device.program.id)
        glBindVertexArray(device.vao)
        glBindBuffer(GL_ARRAY_BUFFER, device.vbo)
        glEnable(GL_BLEND)
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
        glDisable(GL_DEPTH_TEST)
        glDisable(GL_CULL_FACE)
        glDisable(GL_STENCIL_TEST)
        glDisable(GL_SCISSOR_TEST)
        glActiveTexture(GL_TEXTURE0)
    }

    /// Draws `root` (whose bounds are in points, y up) into the framebuffer.
    public func render(root: CALayer, pixelWidth: Int, pixelHeight: Int, time: CFTimeInterval, framebuffer: GLuint = 0) {
        self.time = time
        defaultFramebuffer = framebuffer
        device.deleteRetiredTextures()
        root.layoutIfNeeded()
        let size = root.bounds.size
        screenScale = size.width > 0 ? CGFloat(pixelWidth) / size.width : 1
        resetState()
        targetStack = [(framebuffer, pixelWidth, pixelHeight)]
        bind(framebuffer: framebuffer, width: pixelWidth, height: pixelHeight)
        glClearColor(0, 0, 0, 1)
        glClear(GL_COLOR_BUFFER_BIT)
        visited.removeAll(keepingCapacity: true)
        // Root space (points, y up) to clip space.
        var projection = CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0)
        projection = projection.then(CATransform3DMakeScale(2 / max(1, size.width), 2 / max(1, size.height), 1))
        let rootState = root.presentationState(at: time)
        let toClip = layerToSuperTransform(rootState).flattened.then(projection)
        draw(root, state: rootState, toClip: toClip, opacity: 1, time: time)
        var animating = false
        finishFrame(root, animating: &animating)
        isAnimating = animating
    }

    /// Marks every layer as drawn and retires finished animations, hidden layers included.
    private func finishFrame(_ layer: CALayer, animating: inout Bool) {
        layer.hasBeenRendered = true
        if SnapCheck.enabled {
            // Filters are shared objects, so keep their values as they were drawn.
            var model = layer.modelState
            for case let filter as CIFilter in model.filters ?? [] {
                let key = "\(filter.name).inputRadius"
                if model.filterValues[key] == nil, let value = model.filterParameter(filter.name, "inputRadius") {
                    model.filterValues[key] = value
                }
            }
            layer.lastDrawnModel = model
        }
        RenderStats.layersVisited += 1
        RenderStats.animations += layer.animationList.count
        if layer.hasAnimations {
            if layer.isAnimating(at: time) { animating = true }
            layer.retireAnimations(at: time)
        }
        if let mask = layer.mask { finishFrame(mask, animating: &animating) }
        for child in layer.children { finishFrame(child, animating: &animating) }
    }

    /// Reads the last frame back, for screenshots.
    public func snapshot(pixelWidth: Int, pixelHeight: Int, framebuffer: GLuint = 0) -> CGImage {
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
        let storage = PixelStorage(width: pixelWidth, height: pixelHeight)
        let row = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelWidth * 4)
        defer { row.deallocate() }
        glPixelStorei(GL_PACK_ALIGNMENT, 4)
        glReadPixels(0, 0, GLsizei(pixelWidth), GLsizei(pixelHeight), GL_BGRA, GL_UNSIGNED_BYTE, storage.bytes)
        // GL rows run bottom up.
        for y in 0 ..< pixelHeight / 2 {
            let top = storage.bytes + y * storage.bytesPerRow
            let bottom = storage.bytes + (pixelHeight - 1 - y) * storage.bytesPerRow
            row.update(from: top, count: storage.bytesPerRow)
            top.update(from: bottom, count: storage.bytesPerRow)
            bottom.update(from: row, count: storage.bytesPerRow)
        }
        return CGImage(storage: storage, colorSpace: CGColorSpace(name: CGColorSpace.sRGB), alphaInfo: .premultipliedFirst)
    }

    // MARK: Targets

    private func bind(framebuffer: GLuint, width: Int, height: Int) {
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
        glViewport(0, 0, GLsizei(width), GLsizei(height))
    }

    private func push(_ target: RenderTarget) {
        targetStack.append((target.framebuffer, target.width, target.height))
        bind(framebuffer: target.framebuffer, width: target.width, height: target.height)
        glDisable(GL_SCISSOR_TEST)
        glClearColor(0, 0, 0, 0)
        glClear(GL_COLOR_BUFFER_BIT)
    }

    /// Goes back to drawing into the target below the offscreen ones.
    private func restoreParent(scissor savedScissor: CGRect?) {
        let top = targetStack[targetStack.count - 1]
        bind(framebuffer: top.framebuffer, width: top.width, height: top.height)
        scissor = savedScissor
        applyScissor()
    }

    private func applyScissor() {
        if let scissor {
            glEnable(GL_SCISSOR_TEST)
            let r = scissor.integral
            glScissor(GLint(r.minX), GLint(r.minY), GLsizei(max(0, r.width)), GLsizei(max(0, r.height)))
        } else {
            glDisable(GL_SCISSOR_TEST)
        }
    }

    // MARK: Drawing

    private struct Quad {
        var rect: CGRect
        var uv: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 1, 1)
        var color: (Float, Float, Float, Float) = (1, 1, 1, 1)
        var mode: GLDevice.Mode = .solid
        var bounds: CGRect?
        var radius: CGFloat = 0
        var border: CGFloat = 0
        var antialias = false
        var gradient: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 1)
        var texture: GLuint = 0
        var mask: GLuint = 0
    }

    private func submit(_ quad: Quad, _ mvp: CATransform3D) {
        let p = device.program
        var rect = quad.rect
        var uv = quad.uv
        let edgeRect = quad.bounds ?? quad.rect
        if quad.antialias {
            // Grow the quad by about a pixel so its edge can fade out.
            let pad = 1.5 / max(0.01, pixelDensity(mvp, at: CGPoint(x: rect.midX, y: rect.midY)))
            let grown = rect.insetBy(dx: -pad, dy: -pad)
            if rect.width > 0, rect.height > 0 {
                let du = (uv.2 - uv.0) / rect.width
                let dv = (uv.3 - uv.1) / rect.height
                uv = (uv.0 - du * pad, uv.1 - dv * pad, uv.2 + du * pad, uv.3 + dv * pad)
            }
            rect = grown
        }
        var matrix = mvp.values.map { GLfloat($0) }
        glUniformMatrix4fv(p.mvp, 1, GL_FALSE, &matrix)
        glUniform4f(p.rect, GLfloat(rect.minX), GLfloat(rect.minY), GLfloat(rect.width), GLfloat(rect.height))
        glUniform4f(p.uv, GLfloat(uv.0), GLfloat(uv.1), GLfloat(uv.2), GLfloat(uv.3))
        glUniform4f(p.color, quad.color.0, quad.color.1, quad.color.2, quad.color.3)
        glUniform1i(p.mode, quad.mode.rawValue)
        glUniform4f(p.bounds, GLfloat(edgeRect.minX), GLfloat(edgeRect.minY), GLfloat(edgeRect.width), GLfloat(edgeRect.height))
        glUniform1f(p.radius, GLfloat(quad.radius))
        glUniform1f(p.border, GLfloat(quad.border))
        let e: GLfloat = quad.antialias ? 1 : 0
        glUniform4f(p.edges, e, e, e, e)
        glUniform4f(p.gradient, GLfloat(quad.gradient.0), GLfloat(quad.gradient.1), GLfloat(quad.gradient.2), GLfloat(quad.gradient.3))
        if quad.mask != 0 {
            glActiveTexture(GL_TEXTURE1)
            glBindTexture(GL_TEXTURE_2D, quad.mask)
            glActiveTexture(GL_TEXTURE0)
        }
        glBindTexture(GL_TEXTURE_2D, quad.texture)
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
    }

    /// Roughly how many target pixels one unit of a layer's space covers at `point`.
    private func pixelDensity(_ mvp: CATransform3D, at point: CGPoint) -> CGFloat {
        let top = targetStack.last ?? (0, 1, 1)
        func screen(_ x: CGFloat, _ y: CGFloat) -> CGPoint? {
            let p = mvp.apply(x: x, y: y)
            guard p.3 > 1e-6 else { return nil }
            return CGPoint(x: p.0 / p.3 * CGFloat(top.width) / 2, y: p.1 / p.3 * CGFloat(top.height) / 2)
        }
        guard let a = screen(point.x, point.y), let bx = screen(point.x + 1, point.y), let by = screen(point.x, point.y + 1) else { return 1 }
        return max(hypot(bx.x - a.x, bx.y - a.y), hypot(by.x - a.x, by.y - a.y))
    }

    /// True when the transform keeps rectangles axis-aligned on screen.
    private func isAxisAligned(_ m: CATransform3D) -> Bool {
        abs(m.m14) < 1e-9 && abs(m.m24) < 1e-9 && abs(m.m12) < 1e-9 && abs(m.m21) < 1e-9
    }

    private func color(_ c: CGColor?, alpha: Float) -> (Float, Float, Float, Float) {
        guard let c else { return (0, 0, 0, 0) }
        let p = c.premultiplied
        return (p.0 * alpha, p.1 * alpha, p.2 * alpha, p.3 * alpha)
    }

    /// The transform from a sublayer's bounds space into its superlayer's bounds space.
    private func childTransform(_ child: LayerState, in parent: LayerState) -> CATransform3D {
        layerToSuperTransform(child).then(sublayerSpaceTransform(parent)).flattened
    }

    private func draw(_ layer: CALayer, state: LayerState, toClip: CATransform3D, opacity: Float, time: Double) {
        visited.append(layer)
        RenderStats.layersDrawn += 1
        guard !state.isHidden else { return }
        // An animation can pass through a negative size, which draws like the same box the
        // right way round, as the bounds setter stores it.
        var s = state
        if s.bounds.size.width < 0 || s.bounds.size.height < 0 { s.bounds = s.bounds.standardized }
        let alpha = opacity * s.opacity
        guard alpha > 0.0005 else { return }
        if needsGroup(layer, s, alpha: alpha) {
            drawGroup(layer, state: s, toClip: toClip, opacity: alpha, time: time)
            return
        }
        drawShadowPath(layer, s, toClip: toClip, opacity: alpha)
        drawBody(layer, s, toClip: toClip, opacity: alpha, time: time)
    }

    /// Background, contents, sublayers and border, in Core Animation's order.
    private func drawBody(_ layer: CALayer, _ s: LayerState, toClip: CATransform3D, opacity alpha: Float, time: Double) {
        let antialias = !isAxisAligned(toClip) && layer.allowsEdgeAntialiasing
        if let background = s.backgroundColor, background.alpha > 0 {
            submit(Quad(rect: s.bounds, color: color(background, alpha: alpha), bounds: s.bounds, radius: s.cornerRadius, antialias: antialias && s.cornerRadius == 0), toClip)
        }
        drawContents(layer, s, toClip: toClip, opacity: alpha, antialias: antialias)
        drawSublayers(layer, s, toClip: toClip, opacity: alpha, time: time)
        if s.borderWidth > 0, let border = s.borderColor, border.alpha > 0 {
            submit(Quad(rect: s.bounds, color: color(border, alpha: alpha), bounds: s.bounds, radius: max(s.cornerRadius, 0.0001), border: s.borderWidth), toClip)
        }
    }

    private func drawSublayers(_ layer: CALayer, _ s: LayerState, toClip: CATransform3D, opacity: Float, time: Double) {
        let children = layer.children
        guard !children.isEmpty else { return }
        let savedScissor = scissor
        if s.masksToBounds {
            // Only axis-aligned clips reach here; others go through an offscreen group.
            if let clip = screenRect(s.bounds, toClip) {
                scissor = savedScissor.map { $0.intersection(clip) } ?? clip
                if scissor?.isNull == true { scissor = .zero }
                applyScissor()
            }
        }
        if let replicator = layer as? CAReplicatorLayer {
            drawReplicas(replicator, s, toClip: toClip, opacity: opacity, time: time)
        } else {
            var states = children.map { ($0, $0.presentationState(at: time)) }
            if states.contains(where: { $0.1.zPosition != 0 }) {
                states = states.enumerated().sorted { a, b in
                    a.element.1.zPosition == b.element.1.zPosition ? a.offset < b.offset : a.element.1.zPosition < b.element.1.zPosition
                }.map(\.element)
            }
            for (child, childState) in states {
                draw(child, state: childState, toClip: childTransform(childState, in: s).then(toClip), opacity: opacity, time: time)
            }
        }
        if s.masksToBounds {
            scissor = savedScissor
            applyScissor()
        }
    }

    private func drawReplicas(_ layer: CAReplicatorLayer, _ s: LayerState, toClip: CATransform3D, opacity: Float, time: Double) {
        let anchorX = s.bounds.minX + s.bounds.width * s.anchorPoint.x
        let anchorY = s.bounds.minY + s.bounds.height * s.anchorPoint.y
        let center = CATransform3DMakeTranslation(-anchorX, -anchorY, 0)
        let back = CATransform3DMakeTranslation(anchorX, anchorY, 0)
        var instance = CATransform3DIdentity
        for index in 0 ..< max(1, s.instanceCount) {
            let instanceTime = time - Double(index) * s.instanceDelay
            let alpha = max(0, opacity * (1 + Float(index) * s.instanceAlphaOffset))
            for child in layer.children {
                let childState = child.presentationState(at: instanceTime)
                let placed = layerToSuperTransform(childState).then(center).then(instance).then(back).then(sublayerSpaceTransform(s)).flattened
                draw(child, state: childState, toClip: placed.then(toClip), opacity: alpha, time: instanceTime)
            }
            instance = instance.then(s.instanceTransform)
        }
    }

    /// A rectangle's box in target pixels, when the transform keeps it axis-aligned.
    private func screenRect(_ rect: CGRect, _ toClip: CATransform3D) -> CGRect? {
        guard isAxisAligned(toClip) else { return nil }
        let top = targetStack.last ?? (0, 1, 1)
        let a = toClip.apply(x: rect.minX, y: rect.minY)
        let b = toClip.apply(x: rect.maxX, y: rect.maxY)
        guard a.3 > 0, b.3 > 0 else { return nil }
        let x0 = (a.0 / a.3 + 1) / 2 * CGFloat(top.width)
        let y0 = (a.1 / a.3 + 1) / 2 * CGFloat(top.height)
        let x1 = (b.0 / b.3 + 1) / 2 * CGFloat(top.width)
        let y1 = (b.1 / b.3 + 1) / 2 * CGFloat(top.height)
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
    }

    // MARK: Contents

    private func image(from contents: Any?) -> CGImage? {
        if let image = contents as? CGImage { return image }
        if let provider = contents as? LayerContentsProviding { return provider.layerContents }
        return nil
    }

    private func drawContents(_ layer: CALayer, _ s: LayerState, toClip: CATransform3D, opacity: Float, antialias: Bool) {
        if layer is CAGradientLayer {
            drawGradient(s, toClip: toClip, opacity: opacity, antialias: antialias)
            return
        }
        if layer is CAShapeLayer {
            drawShape(s, toClip: toClip, opacity: opacity)
            return
        }
        if let video = s.contents as? ExternalTextureProviding {
            guard let texture = video.currentTexture() else { return }
            drawTexture(texture.id, imageSize: CGSize(width: texture.width, height: texture.height), flippedRows: texture.bottomUp, s, layer: layer, toClip: toClip, opacity: opacity, antialias: antialias)
            return
        }
        guard let image = image(from: s.contents), let box = device.texture(for: image) else { return }
        drawTexture(box.texture, imageSize: CGSize(width: image.width, height: image.height), flippedRows: false, s, layer: layer, toClip: toClip, opacity: opacity, antialias: antialias)
    }

    private func drawTexture(_ texture: GLuint, imageSize: CGSize, flippedRows: Bool, _ s: LayerState, layer: CALayer, toClip: CATransform3D, opacity: Float, antialias: Bool) {
        let b = s.bounds
        guard b.width > 0, b.height > 0, imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = max(0.0001, s.contentsScale)
        let cr = s.contentsRect
        let natural = CGSize(width: imageSize.width * cr.width / scale, height: imageSize.height * cr.height / scale)
        let flipped = layer.contentsAreFlipped() != flippedRows
        let rect = gravityRect(s.contentsGravity, natural: natural, in: b, flipped: flipped)
        // Texture rows run top down: the image's top row is at maxY unless the space is flipped.
        func uv(_ unitX: CGFloat, _ unitY: CGFloat) -> (CGFloat, CGFloat) {
            (cr.minX + unitX * cr.width, cr.minY + unitY * cr.height)
        }
        let filter = s.minificationFilter == .nearest && s.magnificationFilter == .nearest ? GL_NEAREST : GL_LINEAR
        glBindTexture(GL_TEXTURE_2D, texture)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(filter))
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(filter))
        let clipToBounds = s.masksToBounds
        let radius = clipToBounds ? s.cornerRadius : 0
        let center = s.contentsCenter
        if center != CGRect(x: 0, y: 0, width: 1, height: 1), s.contentsGravity == .resize {
            drawNineSlice(texture: texture, natural: natural, center: center, rect: rect, flipped: flipped, toClip: toClip, opacity: opacity)
            return
        }
        var drawRect = rect
        var u0 = uv(0, 0).0, u1 = uv(1, 0).0
        var vTop = uv(0, 0).1, vBottom = uv(0, 1).1
        if clipToBounds {
            let clipped = rect.intersection(b)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return }
            let fx0 = (clipped.minX - rect.minX) / rect.width, fx1 = (clipped.maxX - rect.minX) / rect.width
            let du = u1 - u0
            (u0, u1) = (u0 + du * fx0, u0 + du * fx1)
            // In y: unit 0 is the image's top row.
            let topEdgeFraction = flipped ? (clipped.minY - rect.minY) / rect.height : (rect.maxY - clipped.maxY) / rect.height
            let bottomEdgeFraction = flipped ? (clipped.maxY - rect.minY) / rect.height : (rect.maxY - clipped.minY) / rect.height
            let dv = vBottom - vTop
            (vTop, vBottom) = (vTop + dv * topEdgeFraction, vTop + dv * bottomEdgeFraction)
            drawRect = clipped
        }
        // uv is given at (minX, minY) and (maxX, maxY) of the quad.
        let quadUV = flipped ? (u0, vTop, u1, vBottom) : (u0, vBottom, u1, vTop)
        submit(Quad(rect: drawRect, uv: quadUV, color: (opacity, opacity, opacity, opacity), mode: .texture, bounds: radius > 0 ? b : drawRect, radius: radius, antialias: antialias && radius == 0, texture: texture), toClip)
    }

    private func gravityRect(_ gravity: CALayerContentsGravity, natural: CGSize, in b: CGRect, flipped: Bool) -> CGRect {
        let w = natural.width, h = natural.height
        // "Top" means the edge that shows at the top.
        let topY = flipped ? b.minY : b.maxY - h
        let bottomY = flipped ? b.maxY - h : b.minY
        switch gravity {
        case .resize: return b
        case .resizeAspect, .resizeAspectFill:
            guard w > 0, h > 0 else { return b }
            let scale = gravity == .resizeAspect ? min(b.width / w, b.height / h) : max(b.width / w, b.height / h)
            let size = CGSize(width: w * scale, height: h * scale)
            return CGRect(x: b.midX - size.width / 2, y: b.midY - size.height / 2, width: size.width, height: size.height)
        case .center: return CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
        case .top: return CGRect(x: b.midX - w / 2, y: topY, width: w, height: h)
        case .bottom: return CGRect(x: b.midX - w / 2, y: bottomY, width: w, height: h)
        case .left: return CGRect(x: b.minX, y: b.midY - h / 2, width: w, height: h)
        case .right: return CGRect(x: b.maxX - w, y: b.midY - h / 2, width: w, height: h)
        case .topLeft: return CGRect(x: b.minX, y: topY, width: w, height: h)
        case .topRight: return CGRect(x: b.maxX - w, y: topY, width: w, height: h)
        case .bottomLeft: return CGRect(x: b.minX, y: bottomY, width: w, height: h)
        case .bottomRight: return CGRect(x: b.maxX - w, y: bottomY, width: w, height: h)
        default: return b
        }
    }

    private func drawNineSlice(texture: GLuint, natural: CGSize, center: CGRect, rect: CGRect, flipped: Bool, toClip: CATransform3D, opacity: Float) {
        // Fixed edges in points, shrunk together if the rect is too small for them.
        var left = center.minX * natural.width
        var right = (1 - center.maxX) * natural.width
        var top = center.minY * natural.height
        var bottom = (1 - center.maxY) * natural.height
        if left + right > rect.width, left + right > 0 {
            let k = rect.width / (left + right)
            left *= k
            right *= k
        }
        if top + bottom > rect.height, top + bottom > 0 {
            let k = rect.height / (top + bottom)
            top *= k
            bottom *= k
        }
        let xs = [rect.minX, rect.minX + left, rect.maxX - right, rect.maxX]
        let us = [0, center.minX, center.maxX, 1]
        // Rows from the visual top down.
        let ysTopDown: [CGFloat] = flipped ? [rect.minY, rect.minY + top, rect.maxY - bottom, rect.maxY] : [rect.maxY, rect.maxY - top, rect.minY + bottom, rect.minY]
        let vs = [0, center.minY, center.maxY, 1]
        for row in 0 ..< 3 {
            for column in 0 ..< 3 {
                let x0 = xs[column], x1 = xs[column + 1]
                let yA = ysTopDown[row], yB = ysTopDown[row + 1]
                guard x1 - x0 > 0.0001, abs(yB - yA) > 0.0001 else { continue }
                let minY = min(yA, yB), maxY = max(yA, yB)
                let vAtMinY = flipped ? vs[row] : vs[row + 1]
                let vAtMaxY = flipped ? vs[row + 1] : vs[row]
                submit(Quad(rect: CGRect(x: x0, y: minY, width: x1 - x0, height: maxY - minY), uv: (us[column], vAtMinY, us[column + 1], vAtMaxY), color: (opacity, opacity, opacity, opacity), mode: .texture, texture: texture), toClip)
            }
        }
    }

    private func drawGradient(_ s: LayerState, toClip: CATransform3D, opacity: Float, antialias: Bool) {
        guard !s.gradientColors.isEmpty, s.bounds.width > 0, s.bounds.height > 0 else { return }
        let texture = device.gradientTexture(colors: s.gradientColors, locations: s.gradientLocations)
        let mode: GLDevice.Mode = s.gradientType == .radial ? .radialGradient : .axialGradient
        let radius = s.masksToBounds ? s.cornerRadius : 0
        submit(Quad(rect: s.bounds, uv: (0, 0, 1, 1), color: (opacity, opacity, opacity, opacity), mode: mode, bounds: s.bounds, radius: radius, antialias: antialias && radius == 0, gradient: (s.startPoint.x, s.startPoint.y, s.endPoint.x, s.endPoint.y), texture: texture), toClip)
    }

    private var shapeCache: [String: (CGImage, CGRect)] = [:]

    private func drawShape(_ s: LayerState, toClip: CATransform3D, opacity: Float) {
        guard let path = s.shapePath, !path.isEmpty else { return }
        let density = max(1, min(4, pixelDensity(toClip, at: CGPoint(x: s.bounds.midX, y: s.bounds.midY))))
        let stroke = s.strokeColor != nil ? s.lineWidth : 0
        let box = path.boundingBox.insetBy(dx: -stroke - 1, dy: -stroke - 1)
        guard box.width > 0, box.height > 0 else { return }
        let key = "\(path.elements)|\(String(describing: s.fillColor?.rgba))|\(String(describing: s.strokeColor?.rgba))|\(s.lineWidth)|\(density)"
        var entry = shapeCache[key]
        if entry == nil {
            let width = Int(ceil(box.width * density)), height = Int(ceil(box.height * density))
            guard width > 0, height > 0, width < 8192, height < 8192,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { return }
            context.scaleBy(x: density, y: density)
            context.translateBy(x: -box.minX, y: -box.minY)
            if let fill = s.fillColor {
                context.addPath(path)
                context.setFillColor(fill)
                context.fillPath(using: s.fillRule == .evenOdd ? .evenOdd : .winding)
            }
            if let strokeColor = s.strokeColor, s.lineWidth > 0 {
                context.addPath(path)
                context.setStrokeColor(strokeColor)
                context.setLineWidth(s.lineWidth)
                context.setLineCap(s.lineCap == .round ? .round : s.lineCap == .square ? .square : .butt)
                context.setLineJoin(s.lineJoin == .round ? .round : s.lineJoin == .bevel ? .bevel : .miter)
                context.strokePath()
            }
            guard let image = context.makeImage() else { return }
            if shapeCache.count > 64 { shapeCache.removeAll() }
            entry = (image, box)
            shapeCache[key] = entry
        }
        guard let (image, rect) = entry, let texture = device.texture(for: image) else { return }
        // The bitmap was drawn with y up, so its top row is the path's maxY.
        submit(Quad(rect: rect, uv: (0, 1, 1, 0), color: (opacity, opacity, opacity, opacity), mode: .texture, texture: texture.texture), toClip)
    }

    // MARK: Shadows

    private func drawShadowPath(_ layer: CALayer, _ s: LayerState, toClip: CATransform3D, opacity: Float) {
        guard s.shadowOpacity > 0, let path = s.shadowPath, let shadowColor = s.shadowColor, shadowColor.alpha > 0 else { return }
        // In whole doublings, so a moving or zooming layer keeps its shadow rather than having
        // a new one blurred on the processor every frame. A soft shadow scales well.
        let rawDensity = max(0.5, min(2, pixelDensity(toClip, at: CGPoint(x: s.bounds.midX, y: s.bounds.midY))))
        let densityStep = Int(log2(rawDensity).rounded())
        let density = pow(2, CGFloat(densityStep))
        let sigma = s.shadowRadius / 2 * density
        let margin = ceil(sigma * 3) + 2
        let box = path.boundingBox
        guard box.width > 0, box.height > 0 else { return }
        let key = ShadowKey(path: ObjectIdentifier(path), radius: s.shadowRadius, densityStep: densityStep)
        var image = shadowCache.image(for: key, path: path)
        if image == nil {
            let width = Int(ceil(box.width * density + margin * 2)), height = Int(ceil(box.height * density + margin * 2))
            guard width > 0, height > 0, width < 8192, height < 8192,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { return }
            context.translateBy(x: margin, y: margin)
            context.scaleBy(x: density, y: density)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.addPath(path)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            guard let shape = context.makeImage() else { return }
            fr_blur_bgra(shape.storage.bytes, Int32(shape.width), Int32(shape.height), Int32(shape.bytesPerRow), Float(sigma))
            RenderStats.shadowRasters += 1
            shadowCache.insert(shape, for: key, path: path)
            image = shape
        }
        guard let image, let texture = device.texture(for: image) else { return }
        let m = margin / density
        let rect = CGRect(x: box.minX - m + s.shadowOffset.width, y: box.minY - m + s.shadowOffset.height, width: box.width + m * 2, height: box.height + m * 2)
        let tint = color(shadowColor, alpha: opacity * s.shadowOpacity)
        submit(Quad(rect: rect, uv: (0, 1, 1, 0), color: tint, mode: .shadowFromAlpha, texture: texture.texture), toClip)
    }

    // MARK: Offscreen groups

    private func needsGroup(_ layer: CALayer, _ s: LayerState, alpha: Float) -> Bool {
        if layer.mask != nil { return true }
        if s.blurRadius() > 0.01 { return true }
        if s.shadowOpacity > 0, s.shadowPath == nil, s.shadowColor?.alpha ?? 0 > 0 { return true }
        if s.masksToBounds, !layer.children.isEmpty, s.cornerRadius > 0 { return true }
        if s.opacity < 0.999, layer.allowsGroupOpacity, drawableCount(layer, s, limit: 2) > 1 { return true }
        return false
    }

    /// Counts things the layer draws, stopping at `limit`.
    private func drawableCount(_ layer: CALayer, _ s: LayerState, limit: Int) -> Int {
        var count = 0
        if s.backgroundColor?.alpha ?? 0 > 0 { count += 1 }
        if s.contents != nil || layer is CAGradientLayer || layer is CAShapeLayer { count += 1 }
        if s.borderWidth > 0 { count += 1 }
        if count >= limit { return count }
        for child in layer.children where !child.isHidden && child.opacity > 0 {
            count += drawableCount(child, child.modelState, limit: limit - count)
            if count >= limit { return count }
        }
        return count
    }

    /// The area a layer and its visible sublayers cover, in its own bounds space.
    private func contentExtent(_ layer: CALayer, _ s: LayerState, time: Double, depth: Int = 0) -> CGRect {
        var extent = s.bounds
        guard !s.masksToBounds, depth < 8 else { return extent }
        for child in layer.children {
            let cs = child.presentationState(at: time)
            guard !cs.isHidden, cs.opacity > 0 else { continue }
            let inner = contentExtent(child, cs, time: time, depth: depth + 1)
            let t = childTransform(cs, in: s)
            var points: [CGPoint] = []
            for corner in [(inner.minX, inner.minY), (inner.maxX, inner.minY), (inner.minX, inner.maxY), (inner.maxX, inner.maxY)] {
                let p = t.apply(x: corner.0, y: corner.1)
                guard p.3 > 1e-6 else { continue }
                points.append(CGPoint(x: p.0 / p.3, y: p.1 / p.3))
            }
            guard points.count == 4 else { continue }
            let xs = points.map(\.x), ys = points.map(\.y)
            extent = extent.union(CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
        }
        if s.shadowOpacity > 0 {
            let grow = s.shadowRadius * 1.5 + 2
            extent = extent.union(extent.offsetBy(dx: s.shadowOffset.width, dy: s.shadowOffset.height).insetBy(dx: -grow, dy: -grow))
        }
        return extent
    }

    private func drawGroup(_ layer: CALayer, state s: LayerState, toClip: CATransform3D, opacity: Float, time: Double) {
        RenderStats.groups += 1
        var extent = contentExtent(layer, s, time: time)
        if let mask = layer.mask {
            let ms = mask.presentationState(at: time)
            let maskFrame = rectThrough(childTransform(ms, in: s), ms.bounds)
            extent = extent.intersection(maskFrame)
        }
        let blur = s.blurRadius()
        if blur > 0 { extent = extent.insetBy(dx: -ceil(blur * 3), dy: -ceil(blur * 3)) }
        // Keep offscreen work bounded to a few screens' worth.
        let limit = max(4096, (layer.superlayer?.bounds.width ?? 4096) * 3)
        extent = extent.intersection(CGRect(x: -limit, y: -limit, width: limit * 2, height: limit * 2))
        guard !extent.isNull, extent.width > 0.5, extent.height > 0.5 else { return }
        var density = min(screenScale * 2, max(0.25, pixelDensity(toClip, at: CGPoint(x: extent.midX, y: extent.midY))))
        // Big blurs don't need full resolution, which is how Core Animation keeps them cheap.
        if blur > 0 { density = min(density, max(0.25, 8 / blur)) }
        let maxSide = CGFloat(device.maxTextureSize)
        density = min(density, maxSide / max(extent.width, extent.height))
        let width = max(1, Int(ceil(extent.width * density)))
        let height = max(1, Int(ceil(extent.height * density)))
        let toTarget = CATransform3DMakeTranslation(-extent.minX, -extent.minY, 0)
            .then(CATransform3DMakeScale(2 / extent.width, 2 / extent.height, 1))
            .then(CATransform3DMakeTranslation(-1, -1, 0))
        let savedScissor = scissor
        scissor = nil

        let content = device.acquireTarget(width: width, height: height)
        push(content)
        var groupState = s
        groupState.shadowOpacity = 0
        drawBody(layer, groupState, toClip: toTarget, opacity: 1, time: time)
        targetStack.removeLast()

        var result = content
        if let mask = layer.mask {
            let maskTarget = device.acquireTarget(width: width, height: height)
            push(maskTarget)
            let ms = mask.presentationState(at: time)
            draw(mask, state: ms, toClip: childTransform(ms, in: s).then(toTarget), opacity: 1, time: time)
            targetStack.removeLast()
            let combined = device.acquireTarget(width: width, height: height)
            push(combined)
            submit(Quad(rect: extent, uv: (0, 0, 1, 1), mode: .textureMasked, texture: content.texture, mask: maskTarget.texture), toTarget)
            targetStack.removeLast()
            device.releaseTarget(maskTarget)
            device.releaseTarget(content)
            result = combined
        }
        if s.masksToBounds, s.cornerRadius > 0 {
            let rounded = device.acquireTarget(width: width, height: height)
            push(rounded)
            submit(Quad(rect: extent, uv: (0, 0, 1, 1), mode: .texture, bounds: s.bounds, radius: s.cornerRadius, texture: result.texture), toTarget)
            targetStack.removeLast()
            device.releaseTarget(result)
            result = rounded
        }
        if blur > 0 {
            result = blurred(result, sigma: blur * density)
        }
        restoreParent(scissor: savedScissor)
        glUseProgram(device.program.id)

        if s.shadowOpacity > 0, s.shadowPath == nil, let shadowColor = s.shadowColor {
            let shadow = blurred(copy(result), sigma: s.shadowRadius / 2 * density)
            bind(framebuffer: targetStack.last!.framebuffer, width: targetStack.last!.width, height: targetStack.last!.height)
            applyScissor()
            glUseProgram(device.program.id)
            let tint = color(shadowColor, alpha: opacity * s.shadowOpacity)
            submit(Quad(rect: extent.offsetBy(dx: s.shadowOffset.width, dy: s.shadowOffset.height), uv: (0, 0, 1, 1), color: tint, mode: .shadowFromAlpha, texture: shadow.texture), toClip)
            device.releaseTarget(shadow)
        }
        submit(Quad(rect: extent, uv: (0, 0, 1, 1), color: (opacity, opacity, opacity, opacity), mode: .texture, antialias: !isAxisAligned(toClip), texture: result.texture), toClip)
        device.releaseTarget(result)
    }

    private func rectThrough(_ t: CATransform3D, _ r: CGRect) -> CGRect {
        var points: [CGPoint] = []
        for corner in [(r.minX, r.minY), (r.maxX, r.minY), (r.minX, r.maxY), (r.maxX, r.maxY)] {
            let p = t.apply(x: corner.0, y: corner.1)
            guard p.3 > 1e-6 else { continue }
            points.append(CGPoint(x: p.0 / p.3, y: p.1 / p.3))
        }
        guard !points.isEmpty else { return r }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    private func copy(_ source: RenderTarget) -> RenderTarget {
        let target = device.acquireTarget(width: source.width, height: source.height)
        glBindFramebuffer(GL_READ_FRAMEBUFFER, source.framebuffer)
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, target.framebuffer)
        glBlitFramebuffer(0, 0, GLint(source.width), GLint(source.height), 0, 0, GLint(target.width), GLint(target.height), GL_COLOR_BUFFER_BIT, GL_NEAREST)
        glBindFramebuffer(GL_FRAMEBUFFER, targetStack.last?.framebuffer ?? defaultFramebuffer)
        return target
    }

    /// A two-pass Gaussian blur; consumes `source` and returns a new target.
    private func blurred(_ source: RenderTarget, sigma: CGFloat) -> RenderTarget {
        guard sigma > 0.2 else { return source }
        let b = device.blur
        let other = device.acquireTarget(width: source.width, height: source.height)
        glUseProgram(b.id)
        glUniform1i(b.sampler, 0)
        glUniform1f(b.sigma, GLfloat(min(sigma, 40)))
        glDisable(GL_BLEND)
        glDisable(GL_SCISSOR_TEST)
        glBindFramebuffer(GL_FRAMEBUFFER, other.framebuffer)
        glViewport(0, 0, GLsizei(other.width), GLsizei(other.height))
        glUniform2f(b.direction, 1, 0)
        glBindTexture(GL_TEXTURE_2D, source.texture)
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
        glBindFramebuffer(GL_FRAMEBUFFER, source.framebuffer)
        glUniform2f(b.direction, 0, 1)
        glBindTexture(GL_TEXTURE_2D, other.texture)
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
        glEnable(GL_BLEND)
        glUseProgram(device.program.id)
        device.releaseTarget(other)
        let top = targetStack.last!
        bind(framebuffer: top.framebuffer, width: top.width, height: top.height)
        return source
    }
}

/// Lets layer contents be something other than a CGImage, such as a picture object.
public protocol LayerContentsProviding: AnyObject {
    var layerContents: CGImage? { get }
}

/// A texture another renderer (such as a video decoder) keeps up to date.
public struct ExternalTexture {
    public let id: GLuint
    public let width: Int
    public let height: Int
    /// GL framebuffers store rows bottom up.
    public let bottomUp: Bool

    public init(id: GLuint, width: Int, height: Int, bottomUp: Bool) {
        self.id = id
        self.width = width
        self.height = height
        self.bottomUp = bottomUp
    }
}

public protocol ExternalTextureProviding: AnyObject {
    func currentTexture() -> ExternalTexture?
}

/// Counters behind the FIRSTROW_DEBUG_FRAMES summaries.
public enum RenderStats {
    nonisolated(unsafe) public static var layersDrawn = 0
    nonisolated(unsafe) public static var layersVisited = 0
    nonisolated(unsafe) public static var animations = 0
    nonisolated(unsafe) public static var groups = 0
    nonisolated(unsafe) public static var shadowRasters = 0
    nonisolated(unsafe) public static var textureUploads = 0
    nonisolated(unsafe) public static var targetsCreated = 0

    /// One line of counts, then zeroes them.
    public static func takeSummary(frames: Int) -> String {
        let n = max(1, frames)
        let line = "layers \(layersDrawn / n) drawn of \(layersVisited / n), animations \(animations / n), groups \(groups / n), "
            + "shadow rasters \(shadowRasters), texture uploads \(textureUploads), new targets \(targetsCreated)"
        layersDrawn = 0; layersVisited = 0; animations = 0; groups = 0; shadowRasters = 0; textureUploads = 0; targetsCreated = 0
        return line
    }
}

private struct ShadowKey: Hashable {
    let path: ObjectIdentifier
    let radius: CGFloat
    let densityStep: Int
}

/// Blurred shadow shapes, the oldest dropped once they pass a memory budget.
private struct ShadowCache {
    private var entries: [ShadowKey: (path: CGPath, image: CGImage)] = [:]
    private var order: [ShadowKey] = []
    private var bytes = 0
    private let budget = 48 * 1024 * 1024

    /// Checks the path is the same object, since a freed path's identifier can be reused.
    func image(for key: ShadowKey, path: CGPath) -> CGImage? {
        guard let entry = entries[key], entry.path === path else { return nil }
        return entry.image
    }

    mutating func insert(_ image: CGImage, for key: ShadowKey, path: CGPath) {
        if let old = entries.removeValue(forKey: key) {
            bytes -= old.image.bytesPerRow * old.image.height
            order.removeAll { $0 == key }
        }
        entries[key] = (path, image)
        order.append(key)
        bytes += image.bytesPerRow * image.height
        while bytes > budget, order.count > 1 {
            let oldest = order.removeFirst()
            if let dropped = entries.removeValue(forKey: oldest) {
                bytes -= dropped.image.bytesPerRow * dropped.image.height
            }
        }
    }
}
