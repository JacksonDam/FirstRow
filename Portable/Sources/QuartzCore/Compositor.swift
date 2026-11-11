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
    /// Counts frames, to tell which layers the one being drawn reached.
    private var frame = 0
    private var shadowCache = ShadowCache()
    private let matrixFloats = UnsafeMutablePointer<GLfloat>.allocate(capacity: 16)
    /// What the shader's uniforms were last set to, so only the ones that change are sent.
    private var sent = SentUniforms()

    private struct SentUniforms {
        var uv: (GLfloat, GLfloat, GLfloat, GLfloat) = (.nan, .nan, .nan, .nan)
        var color: (GLfloat, GLfloat, GLfloat, GLfloat) = (.nan, .nan, .nan, .nan)
        var bounds: (GLfloat, GLfloat, GLfloat, GLfloat) = (.nan, .nan, .nan, .nan)
        var gradient: (GLfloat, GLfloat, GLfloat, GLfloat) = (.nan, .nan, .nan, .nan)
        var mode: GLint = -1
        var radius: GLfloat = .nan
        var border: GLfloat = .nan
        var edges: GLfloat = .nan
        var maskKind: GLint = -1
        var maskPlace: (GLfloat, GLfloat, GLfloat, GLfloat) = (.nan, .nan, .nan, .nan)
        var maskGradient: (GLfloat, GLfloat, GLfloat, GLfloat) = (.nan, .nan, .nan, .nan)
        var shadow: (GLfloat, GLfloat) = (.nan, .nan)
    }

    /// A mask that goes on as each quad is drawn (see `directMask`).
    private struct DirectMask {
        /// 1 a picture's alpha, 2 a gradient's alpha.
        var kind: GLint
        var texture: GLuint
        /// From the masked layer's space to the mask's own square.
        var place: (GLfloat, GLfloat, GLfloat, GLfloat)
        var gradient: (GLfloat, GLfloat, GLfloat, GLfloat) = (0, 0, 0, 1)
    }

    private var activeMask: DirectMask?
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
        device.destroyIdleTargets()
        device.deleteIdleTextures()
        root.layoutIfNeeded()
        let size = root.bounds.size
        screenScale = size.width > 0 ? CGFloat(pixelWidth) / size.width : 1
        resetState()
        targetStack = [(framebuffer, pixelWidth, pixelHeight)]
        bind(framebuffer: framebuffer, width: pixelWidth, height: pixelHeight)
        glClearColor(0, 0, 0, 1)
        glClear(GL_COLOR_BUFFER_BIT)
        frame += 1
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
            if layer.isAnimating(at: time, isDrawn: layer.lastDrawnFrame == frame) {
                animating = true
            }
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
        RenderStats.offscreenPasses += 1
        RenderStats.offscreenPixels += target.width * target.height
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
        /// For a box's shadow: the blur's standard deviation and the box's corner radius.
        var shadow: (CGFloat, CGFloat) = (0, 0)
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
        mvp.write(to: matrixFloats)
        glUniformMatrix4fv(p.mvp, 1, GL_FALSE, matrixFloats)
        glUniform4f(p.rect, GLfloat(rect.minX), GLfloat(rect.minY), GLfloat(rect.width), GLfloat(rect.height))
        // The rest mostly stay as the quad before left them.
        let quadUV = (GLfloat(uv.0), GLfloat(uv.1), GLfloat(uv.2), GLfloat(uv.3))
        if quadUV != sent.uv {
            sent.uv = quadUV
            glUniform4f(p.uv, quadUV.0, quadUV.1, quadUV.2, quadUV.3)
        }
        if quad.color != sent.color {
            sent.color = quad.color
            glUniform4f(p.color, quad.color.0, quad.color.1, quad.color.2, quad.color.3)
        }
        if quad.mode.rawValue != sent.mode {
            sent.mode = quad.mode.rawValue
            glUniform1i(p.mode, quad.mode.rawValue)
        }
        let bounds = (GLfloat(edgeRect.minX), GLfloat(edgeRect.minY), GLfloat(edgeRect.width), GLfloat(edgeRect.height))
        if bounds != sent.bounds {
            sent.bounds = bounds
            glUniform4f(p.bounds, bounds.0, bounds.1, bounds.2, bounds.3)
        }
        let radius = GLfloat(quad.radius)
        if radius != sent.radius {
            sent.radius = radius
            glUniform1f(p.radius, radius)
        }
        let border = GLfloat(quad.border)
        if border != sent.border {
            sent.border = border
            glUniform1f(p.border, border)
        }
        let e: GLfloat = quad.antialias ? 1 : 0
        if e != sent.edges {
            sent.edges = e
            glUniform4f(p.edges, e, e, e, e)
        }
        let gradient = (GLfloat(quad.gradient.0), GLfloat(quad.gradient.1), GLfloat(quad.gradient.2), GLfloat(quad.gradient.3))
        if gradient != sent.gradient {
            sent.gradient = gradient
            glUniform4f(p.gradient, gradient.0, gradient.1, gradient.2, gradient.3)
        }
        if quad.mode == .shadowBox {
            let shadow = (GLfloat(quad.shadow.0), GLfloat(quad.shadow.1))
            if shadow != sent.shadow {
                sent.shadow = shadow
                glUniform2f(p.shadow, shadow.0, shadow.1)
            }
        }
        let maskKind = activeMask?.kind ?? 0
        if maskKind != sent.maskKind {
            sent.maskKind = maskKind
            glUniform1i(p.maskKind, maskKind)
        }
        if let activeMask {
            if activeMask.place != sent.maskPlace {
                sent.maskPlace = activeMask.place
                glUniform4f(p.maskPlace, activeMask.place.0, activeMask.place.1, activeMask.place.2, activeMask.place.3)
            }
            if activeMask.gradient != sent.maskGradient {
                sent.maskGradient = activeMask.gradient
                glUniform4f(p.maskGradient, activeMask.gradient.0, activeMask.gradient.1, activeMask.gradient.2, activeMask.gradient.3)
            }
            glActiveTexture(GL_TEXTURE1)
            glBindTexture(GL_TEXTURE_2D, activeMask.texture)
            glActiveTexture(GL_TEXTURE0)
        } else if quad.mask != 0 {
            glActiveTexture(GL_TEXTURE1)
            glBindTexture(GL_TEXTURE_2D, quad.mask)
            glActiveTexture(GL_TEXTURE0)
        }
        glBindTexture(GL_TEXTURE_2D, quad.texture)
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
        RenderStats.drawCalls += 1
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
        RenderStats.layersDrawn += 1
        guard !state.isHidden else { return }
        let alpha = opacity * state.opacity
        guard alpha > 0.0005 else { return }
        layer.lastDrawnFrame = frame
        // An animation can pass through a negative size, which draws like the same box the
        // right way round, as the bounds setter stores it.
        if state.bounds.size.width < 0 || state.bounds.size.height < 0 {
            var righted = state
            righted.bounds = righted.bounds.standardized
            drawVisible(layer, righted, toClip: toClip, opacity: alpha, time: time)
        } else {
            drawVisible(layer, state, toClip: toClip, opacity: alpha, time: time)
        }
    }

    private func drawVisible(_ layer: CALayer, _ s: LayerState, toClip: CATransform3D, opacity alpha: Float, time: Double) {
        if let mask = layer.mask, let direct = directMask(mask, on: layer, s, toClip: toClip, time: time) {
            // The one thing the layer draws, with the mask put on as it's drawn.
            activeMask = direct
            if !s.masksToBounds { drawShadowPath(layer, s, toClip: toClip, opacity: alpha) }
            drawBody(layer, s, toClip: toClip, opacity: alpha, time: time)
            activeMask = nil
            return
        }
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
        } else if children.contains(where: { $0.mayHaveZPosition }) {
            // Drawn by z position, then in order.
            var states = children.map { ($0, $0.presentationState(at: time)) }
            if states.contains(where: { $0.1.zPosition != 0 }) {
                states = states.enumerated().sorted { a, b in
                    a.element.1.zPosition == b.element.1.zPosition ? a.offset < b.offset : a.element.1.zPosition < b.element.1.zPosition
                }.map(\.element)
            }
            for (child, childState) in states {
                draw(child, state: childState, toClip: childTransform(childState, in: s).then(toClip), opacity: opacity, time: time)
            }
        } else {
            // The usual case, in order as they come: nothing to sort, so nothing to collect.
            let plain = hasPlainSublayerSpace(s)
            let space = plain ? CATransform3DIdentity : sublayerSpaceTransform(s)
            for child in children {
                let childState = child.hasAnimations ? child.presentationState(at: time) : child.modelState
                let placed = plain ? layerToSuperTransform(childState).flattened : layerToSuperTransform(childState).then(space).flattened
                draw(child, state: childState, toClip: placed.then(toClip), opacity: opacity, time: time)
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
        // Textures are made smooth, and the rare layer that wants hard pixels puts them back.
        let hardPixels = s.minificationFilter == .nearest && s.magnificationFilter == .nearest
        if hardPixels { setFilter(GL_NEAREST, of: texture) }
        defer { if hardPixels { setFilter(GL_LINEAR, of: texture) } }
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

    private func setFilter(_ filter: GLenum, of texture: GLuint) {
        glBindTexture(GL_TEXTURE_2D, texture)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(filter))
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(filter))
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

    private var shapeCache: [ShapeKey: (CGImage, CGRect)] = [:]

    private func drawShape(_ s: LayerState, toClip: CATransform3D, opacity: Float) {
        guard let (image, rect) = shapePicture(s, toClip: toClip), let texture = device.texture(for: image) else { return }
        // The bitmap was drawn with y up, so its top row is the path's maxY.
        submit(Quad(rect: rect, uv: (0, 1, 1, 0), color: (opacity, opacity, opacity, opacity), mode: .texture, texture: texture.texture), toClip)
    }

    /// A shape layer's fill and stroke as a picture, and the box it covers in the layer's space.
    private func shapePicture(_ s: LayerState, toClip: CATransform3D) -> (CGImage, CGRect)? {
        guard let path = s.shapePath, !path.isEmpty else { return nil }
        // The next quarter step up from the scale it's seen at. While a scene is scaled in or
        // out that scale is different every frame, and a picture made for each one meant every
        // shape and rounded mask on screen was drawn again and sent to the graphics card every
        // frame of the move. One made a little too fine is simply drawn smaller.
        let seenAt = max(1, min(4, pixelDensity(toClip, at: CGPoint(x: s.bounds.midX, y: s.bounds.midY))))
        let density = min(4, (seenAt * 4 - 0.02).rounded(.up) / 4)
        let stroke = s.strokeColor != nil ? s.lineWidth : 0
        let box = path.boundingBox.insetBy(dx: -stroke - 1, dy: -stroke - 1)
        guard box.width > 0, box.height > 0 else { return nil }
        let key = ShapeKey(elements: path.elements, fill: ColorKey(s.fillColor), stroke: ColorKey(s.strokeColor), lineWidth: s.lineWidth, density: density,
                           fillRule: s.fillRule, lineCap: s.lineCap, lineJoin: s.lineJoin)
        var entry = shapeCache[key]
        if entry == nil {
            let width = Int(ceil(box.width * density)), height = Int(ceil(box.height * density))
            guard width > 0, height > 0, width < 8192, height < 8192,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { return nil }
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
            guard let image = context.makeImage() else { return nil }
            if shapeCache.count > 64 { shapeCache.removeAll() }
            entry = (image, box)
            shapeCache[key] = entry
        }
        return entry
    }

    /// The mask in a form that can go on as the layer is drawn, when both are simple enough:
    /// the layer draws one thing (so nothing in it overlaps: masking each of two overlapping
    /// things lets the lower one show through the upper where the mask is part-way), and the
    /// mask is a lone shape or straight gradient, square on to the layer.
    private func directMask(_ mask: CALayer, on layer: CALayer, _ s: LayerState, toClip: CATransform3D, time: Double) -> DirectMask? {
        guard layer.children.isEmpty, mask.children.isEmpty, mask.mask == nil else { return nil }
        guard s.blurRadius() <= 0.01, !(s.shadowOpacity > 0 && s.shadowPath == nil) else { return nil }
        var drawn = 0
        if s.backgroundColor?.alpha ?? 0 > 0 { drawn += 1 }
        if s.contents != nil || layer is CAGradientLayer || layer is CAShapeLayer { drawn += 1 }
        if s.borderWidth > 0, s.borderColor?.alpha ?? 0 > 0 { drawn += 1 }
        if s.shadowOpacity > 0, s.shadowPath != nil, !s.masksToBounds { drawn += 1 }
        guard drawn == 1 else { return nil }
        let ms = mask.presentationState(at: time)
        guard !ms.isHidden, ms.opacity > 0.999, ms.backgroundColor?.alpha ?? 0 <= 0, ms.borderWidth <= 0, ms.shadowOpacity <= 0,
              ms.blurRadius() <= 0.01, ms.contents == nil else { return nil }
        // From the mask's space to the layer's: only a scale and a move will do.
        let t = childTransform(ms, in: s)
        guard abs(t.m12) < 1e-9, abs(t.m21) < 1e-9, abs(t.m14) < 1e-9, abs(t.m24) < 1e-9, abs(t.m44 - 1) < 1e-9,
              abs(t.m11) > 1e-9, abs(t.m22) > 1e-9 else { return nil }
        if mask is CAShapeLayer {
            // At the resolution it'll be seen at: the layer's, through the mask's own scale.
            guard let (image, box) = shapePicture(ms, toClip: t.then(toClip)), let texture = device.texture(for: image) else { return nil }
            // u runs with x; v runs from the picture's top row, which is the box's maxY.
            let place = (GLfloat(1 / (t.m11 * box.width)), GLfloat(-1 / (t.m22 * box.height)),
                         GLfloat((-t.m41 / t.m11 - box.minX) / box.width), GLfloat((box.maxY + t.m42 / t.m22) / box.height))
            return DirectMask(kind: 1, texture: texture.texture, place: place)
        }
        if mask is CAGradientLayer {
            guard ms.gradientType == .axial, !ms.gradientColors.isEmpty, ms.bounds.width > 0, ms.bounds.height > 0,
                  !(ms.masksToBounds && ms.cornerRadius > 0) else { return nil }
            let b = ms.bounds
            let place = (GLfloat(1 / (t.m11 * b.width)), GLfloat(1 / (t.m22 * b.height)),
                         GLfloat((-t.m41 / t.m11 - b.minX) / b.width), GLfloat((-t.m42 / t.m22 - b.minY) / b.height))
            let texture = device.gradientTexture(colors: ms.gradientColors, locations: ms.gradientLocations)
            return DirectMask(kind: 2, texture: texture, place: place,
                              gradient: (GLfloat(ms.startPoint.x), GLfloat(ms.startPoint.y), GLfloat(ms.endPoint.x), GLfloat(ms.endPoint.y)))
        }
        return nil
    }

    // MARK: Shadows

    /// A path that is nothing but a rectangle, or one with its four corners rounded alike
    /// (as `CGPath(rect:)` and `CGPath(roundedRect:)` make them): the box and the radius.
    private static func boxShape(of path: CGPath) -> (box: CGRect, corner: CGFloat)? {
        let e = path.elements
        if e.count == 5, case let .move(a) = e[0], case let .line(b) = e[1], case let .line(c) = e[2], case let .line(d) = e[3], case .close = e[4] {
            guard a.y == b.y, b.x == c.x, c.y == d.y, d.x == a.x, a.x != c.x, a.y != c.y else { return nil }
            return (CGRect(x: min(a.x, c.x), y: min(a.y, c.y), width: abs(c.x - a.x), height: abs(c.y - a.y)), 0)
        }
        if e.count == 10, case let .move(start) = e[0], case let .line(side) = e[1], case let .cubic(_, _, turned) = e[2], case .line = e[3], case .cubic = e[4],
           case .line = e[5], case .cubic = e[6], case .line = e[7], case .cubic = e[8], case .close = e[9]
        {
            let box = path.boundingBox
            let down = start.y - box.minY, across = box.maxX - turned.x
            guard abs(start.x - box.maxX) < 0.001, abs(side.x - box.maxX) < 0.001, abs(turned.y - box.maxY) < 0.001,
                  across > 0, abs(across - down) < 0.01, across <= min(box.width, box.height) / 2 + 0.01 else { return nil }
            return (box, across)
        }
        return nil
    }

    private func drawShadowPath(_ layer: CALayer, _ s: LayerState, toClip: CATransform3D, opacity: Float) {
        guard s.shadowOpacity > 0, let path = s.shadowPath, let shadowColor = s.shadowColor, shadowColor.alpha > 0 else { return }
        // A box's shadow is worked out as it's drawn: nothing to blur, to keep or to send to
        // the graphics card, whatever size the box is and however it's turned. (Blurred into
        // a picture each, the screen saver's photos' shadows came to hundreds of megabytes a
        // turn of the wall.)
        if let shape = Self.boxShape(of: path) {
            let sigma = max(0.01, s.shadowRadius)
            let reach = sigma * 3 + 1
            let box = shape.box.offsetBy(dx: s.shadowOffset.width, dy: s.shadowOffset.height)
            let tint = color(shadowColor, alpha: opacity * s.shadowOpacity)
            submit(Quad(rect: box.insetBy(dx: -reach, dy: -reach), color: tint, mode: .shadowBox,
                        gradient: (box.minX, box.minY, box.width, box.height), shadow: (sigma, shape.corner)), toClip)
            return
        }
        // In whole doublings, so a moving or zooming layer keeps its shadow rather than having
        // a new one blurred on the processor every frame. A soft shadow scales well.
        let rawDensity = max(0.5, min(2, pixelDensity(toClip, at: CGPoint(x: s.bounds.midX, y: s.bounds.midY))))
        let densityStep = Int(log2(rawDensity).rounded())
        let density = pow(2, CGFloat(densityStep))
        // (A layer's shadow radius is the blur's standard deviation, as Core Animation has it:
        // its shadow of radius 14 falls away as a Gaussian of 14, not of 7. A context's shadow
        // blur, in Core Graphics, is twice its deviation.)
        let sigma = s.shadowRadius * density
        let margin = ceil(sigma * 3) + 2
        let box = path.boundingBox
        guard box.width > 0, box.height > 0 else { return }
        let key = ShadowKey(path: path, radius: s.shadowRadius, densityStep: densityStep)
        var image = shadowCache.image(for: key)
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
            shadowCache.insert(shape, for: key)
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
    /// Null when nothing in it draws.
    private func contentExtent(_ layer: CALayer, _ s: LayerState, time: Double, depth: Int = 0) -> CGRect {
        // (One too deep to follow is taken as its box.)
        guard depth < 8 else { return s.bounds }
        // Its own box counts when it draws in it; a layer that only holds others is as big as they are.
        var extent = CGRect.null
        if s.backgroundColor?.alpha ?? 0 > 0 || s.contents != nil || layer is CAGradientLayer || (s.borderWidth > 0 && s.borderColor?.alpha ?? 0 > 0) {
            extent = s.bounds
        }
        if layer is CAShapeLayer, let path = s.shapePath, !path.isEmpty {
            let reach = (s.strokeColor != nil ? s.lineWidth : 0) + 1
            extent = extent.union(path.boundingBox.insetBy(dx: -reach, dy: -reach))
        }
        for child in layer.children {
            let cs = child.presentationState(at: time)
            guard !cs.isHidden, cs.opacity > 0 else { continue }
            let inner = contentExtent(child, cs, time: time, depth: depth + 1)
            guard !inner.isNull, let placed = box(of: inner, through: childTransform(cs, in: s), allCorners: true) else { continue }
            extent = extent.union(placed)
        }
        // A layer that clips shows no more than what's in its box (and no shadow).
        if s.masksToBounds { return extent.intersection(s.bounds) }
        if s.shadowOpacity > 0 {
            // A shadow path casts the shadow whatever the layer draws.
            let caster = s.shadowPath.map(\.boundingBox) ?? extent
            if !caster.isNull {
                let grow = s.shadowRadius * 3 + 2
                extent = extent.union(caster.offsetBy(dx: s.shadowOffset.width, dy: s.shadowOffset.height).insetBy(dx: -grow, dy: -grow))
            }
        }
        return extent
    }

    private func drawGroup(_ layer: CALayer, state s: LayerState, toClip: CATransform3D, opacity: Float, time: Double) {
        RenderStats.groups += 1
        var extent = contentExtent(layer, s, time: time)
        guard !extent.isNull else { return }
        if let mask = layer.mask {
            let ms = mask.presentationState(at: time)
            let maskFrame = rectThrough(childTransform(ms, in: s), ms.bounds)
            extent = extent.intersection(maskFrame)
            guard !extent.isNull else { return }
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
        let castsShadow = s.shadowOpacity > 0 && s.shadowPath == nil && s.shadowColor != nil
        // Only the part that can reach the screen is drawn: a carousel that runs three screens
        // wide fades as one group, and drawing all of it took four times the screen's pixels
        // every frame. What a blur or a shadow pulls in from just outside is kept, and the cut
        // falls on the pixels the whole thing would have had, so nothing shifts as it moves.
        var wholePixels: (width: Int, height: Int)?
        if let reachable = reachableRect(toClip) {
            var reach: CGFloat = 1
            if blur > 0 { reach += ceil(blur * 3) }
            if castsShadow { reach += ceil(s.shadowRadius * 3) + max(abs(s.shadowOffset.width), abs(s.shadowOffset.height)) + 2 }
            let wanted = reachable.insetBy(dx: -reach, dy: -reach)
            let cut = extent.intersection(wanted)
            guard !cut.isNull, cut.width > 0, cut.height > 0 else { return }
            if blur <= 0, let aligned = pixelAligned(cut, toClip, density: density) {
                // On the target's own pixels: what's drawn offscreen is what would have been
                // drawn straight to the screen, and putting it there is an exact copy.
                extent = aligned.rect
                wholePixels = (aligned.width, aligned.height)
            } else {
                let x0 = max(extent.minX, extent.minX + floor((wanted.minX - extent.minX) * density) / density)
                let x1 = min(extent.maxX, extent.minX + ceil((wanted.maxX - extent.minX) * density) / density)
                let y0 = max(extent.minY, extent.minY + floor((wanted.minY - extent.minY) * density) / density)
                let y1 = min(extent.maxY, extent.minY + ceil((wanted.maxY - extent.minY) * density) / density)
                guard x1 - x0 > 0.5 / density, y1 - y0 > 0.5 / density else { return }
                extent = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            }
        }
        let maxSide = CGFloat(device.maxTextureSize)
        if maxSide / max(extent.width, extent.height) < density {
            density = maxSide / max(extent.width, extent.height)
            wholePixels = nil
        }
        var width = wholePixels?.width ?? max(1, Int(ceil(extent.width * density)))
        var height = wholePixels?.height ?? max(1, Int(ceil(extent.height * density)))
        // In steps (of 16 to 64 pixels), the area drawn growing by whole pixels to match (what's
        // added is empty, or more of the layer). A group that's being scaled, or moved by
        // fractions of a pixel, comes out a few pixels bigger or smaller each frame, and a
        // target of exactly that size had to be made new each time, which a graphics card
        // takes its time over. In steps, the target the last frame used fits this one.
        let steppedWidth = Self.stepped(width), steppedHeight = Self.stepped(height)
        if steppedWidth <= device.maxTextureSize, steppedHeight <= device.maxTextureSize {
            extent.size = CGSize(width: extent.width * CGFloat(steppedWidth) / CGFloat(width),
                                 height: extent.height * CGFloat(steppedHeight) / CGFloat(height))
            width = steppedWidth
            height = steppedHeight
        }
        let toTarget = CATransform3DMakeTranslation(-extent.minX, -extent.minY, 0)
            .then(CATransform3DMakeScale(2 / extent.width, 2 / extent.height, 1))
            .then(CATransform3DMakeTranslation(-1, -1, 0))
        let savedScissor = scissor
        scissor = nil

        let content = device.acquireTarget(width: width, height: height)
        push(content)
        var groupState = s
        groupState.shadowOpacity = 0
        // A shadow from a shadow path belongs to the layer: its mask cuts it, and it fades with
        // the rest. (One that would be clipped to the bounds isn't drawn, as on the Mac.)
        if s.shadowPath != nil, !s.masksToBounds, blur <= 0 {
            drawShadowPath(layer, s, toClip: toTarget, opacity: 1)
        }
        drawBody(layer, groupState, toClip: toTarget, opacity: 1, time: time)
        targetStack.removeLast()

        // With no blur or shadow to make from the finished picture, a mask or rounded corners go
        // on as it's drawn to the screen, which saves a pass over every pixel of it.
        let roundsCorners = s.masksToBounds && s.cornerRadius > 0
        if blur <= 0, !castsShadow, layer.mask == nil || !roundsCorners {
            var maskTarget: RenderTarget?
            if let mask = layer.mask {
                let target = device.acquireTarget(width: width, height: height)
                push(target)
                let ms = mask.presentationState(at: time)
                draw(mask, state: ms, toClip: childTransform(ms, in: s).then(toTarget), opacity: 1, time: time)
                targetStack.removeLast()
                maskTarget = target
            }
            restoreParent(scissor: savedScissor)
            let tint = (opacity, opacity, opacity, opacity)
            if let maskTarget {
                submit(Quad(rect: extent, uv: (0, 0, 1, 1), color: tint, mode: .textureMasked, antialias: !isAxisAligned(toClip), texture: content.texture, mask: maskTarget.texture), toClip)
                device.releaseTarget(maskTarget)
            } else if roundsCorners {
                submit(Quad(rect: extent, uv: (0, 0, 1, 1), color: tint, mode: .texture, bounds: s.bounds, radius: s.cornerRadius, texture: content.texture), toClip)
            } else {
                submit(Quad(rect: extent, uv: (0, 0, 1, 1), color: tint, mode: .texture, antialias: !isAxisAligned(toClip), texture: content.texture), toClip)
            }
            device.releaseTarget(content)
            return
        }

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

        if castsShadow, let shadowColor = s.shadowColor {
            let shadow = blurred(copy(result), sigma: s.shadowRadius * density)
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

    /// A target's side rounded up to the next step: finer steps for small groups, which
    /// would otherwise be drawn much bigger than they are.
    private static func stepped(_ pixels: Int) -> Int {
        let step = pixels < 256 ? 16 : pixels < 1024 ? 32 : 64
        return (pixels + step - 1) / step * step
    }

    private func rectThrough(_ t: CATransform3D, _ r: CGRect) -> CGRect {
        box(of: r, through: t, allCorners: false) ?? r
    }

    /// The box around a rectangle's corners once `t` has moved them, leaving out corners that
    /// end up behind the eye. Nil when none are left (or, with `allCorners`, when any is).
    private func box(of r: CGRect, through t: CATransform3D, allCorners: Bool) -> CGRect? {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        var found = 0
        func add(_ x: CGFloat, _ y: CGFloat) {
            let p = t.apply(x: x, y: y)
            guard p.3 > 1e-6 else { return }
            let px = p.0 / p.3, py = p.1 / p.3
            minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, py); maxY = max(maxY, py)
            found += 1
        }
        add(r.minX, r.minY); add(r.maxX, r.minY); add(r.minX, r.maxY); add(r.maxX, r.maxY)
        guard found == 4 || (!allCorners && found > 0) else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `rect` grown to whole pixels of the target being drawn into, with its size in them, for
    /// a layer that sits square on to the target and is drawn at the target's resolution.
    private func pixelAligned(_ rect: CGRect, _ toClip: CATransform3D, density: CGFloat) -> (rect: CGRect, width: Int, height: Int)? {
        guard isAxisAligned(toClip), toClip.m44 > 1e-9, let top = targetStack.last else { return nil }
        let sx = toClip.m11 / toClip.m44 * CGFloat(top.width) / 2
        let sy = toClip.m22 / toClip.m44 * CGFloat(top.height) / 2
        guard abs(abs(sx) - density) < density * 0.001, abs(abs(sy) - density) < density * 0.001 else { return nil }
        let tx = (toClip.m41 / toClip.m44 + 1) / 2 * CGFloat(top.width)
        let ty = (toClip.m42 / toClip.m44 + 1) / 2 * CGFloat(top.height)
        let px0 = floor(min(rect.minX * sx, rect.maxX * sx) + tx + 0.001), px1 = ceil(max(rect.minX * sx, rect.maxX * sx) + tx - 0.001)
        let py0 = floor(min(rect.minY * sy, rect.maxY * sy) + ty + 0.001), py1 = ceil(max(rect.minY * sy, rect.maxY * sy) + ty - 0.001)
        guard px1 > px0, py1 > py0 else { return nil }
        let xa = (px0 - tx) / sx, xb = (px1 - tx) / sx, ya = (py0 - ty) / sy, yb = (py1 - ty) / sy
        return (CGRect(x: min(xa, xb), y: min(ya, yb), width: abs(xb - xa), height: abs(yb - ya)), Int(px1 - px0), Int(py1 - py0))
    }

    /// The part of a layer's space that can reach the target being drawn into (all of it, or
    /// the clip in force), when the layer sits square on to it.
    private func reachableRect(_ toClip: CATransform3D) -> CGRect? {
        guard isAxisAligned(toClip), abs(toClip.m11) > 1e-9, abs(toClip.m22) > 1e-9, toClip.m44 > 1e-9 else { return nil }
        var x0: CGFloat = -1, y0: CGFloat = -1, x1: CGFloat = 1, y1: CGFloat = 1
        if let scissor, let top = targetStack.last, top.width > 0, top.height > 0 {
            x0 = scissor.minX / CGFloat(top.width) * 2 - 1
            x1 = scissor.maxX / CGFloat(top.width) * 2 - 1
            y0 = scissor.minY / CGFloat(top.height) * 2 - 1
            y1 = scissor.maxY / CGFloat(top.height) * 2 - 1
        }
        let xa = (x0 * toClip.m44 - toClip.m41) / toClip.m11, xb = (x1 * toClip.m44 - toClip.m41) / toClip.m11
        let ya = (y0 * toClip.m44 - toClip.m42) / toClip.m22, yb = (y1 * toClip.m44 - toClip.m42) / toClip.m22
        return CGRect(x: min(xa, xb), y: min(ya, yb), width: abs(xb - xa), height: abs(yb - ya))
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
        RenderStats.blurs += 1
        RenderStats.drawCalls += 2
        RenderStats.offscreenPasses += 2
        RenderStats.offscreenPixels += source.width * source.height * 2
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

/// Counters behind the FIRSTROW_DEBUG_FRAMES summaries. They only ever count up: a summary is
/// the difference between two readings.
public enum RenderStats {
    nonisolated(unsafe) public static var layersDrawn = 0
    nonisolated(unsafe) public static var layersVisited = 0
    nonisolated(unsafe) public static var animations = 0
    nonisolated(unsafe) public static var groups = 0
    nonisolated(unsafe) public static var shadowRasters = 0
    nonisolated(unsafe) public static var textureUploads = 0
    nonisolated(unsafe) public static var textureBytes = 0
    nonisolated(unsafe) public static var targetsCreated = 0
    nonisolated(unsafe) public static var drawCalls = 0
    /// Times drawing went to an offscreen target (a group's content, a mask, a blur pass), and
    /// how many pixels those targets had.
    nonisolated(unsafe) public static var offscreenPasses = 0
    nonisolated(unsafe) public static var offscreenPixels = 0
    nonisolated(unsafe) public static var blurs = 0

    public struct Reading: Sendable {
        public var layersDrawn = 0, layersVisited = 0, animations = 0, groups = 0, shadowRasters = 0
        public var textureUploads = 0, textureBytes = 0, targetsCreated = 0, drawCalls = 0
        public var offscreenPasses = 0, offscreenPixels = 0, blurs = 0

        public init() {}

        init(layersDrawn: Int, layersVisited: Int, animations: Int, groups: Int, shadowRasters: Int, textureUploads: Int, textureBytes: Int,
             targetsCreated: Int, drawCalls: Int, offscreenPasses: Int, offscreenPixels: Int, blurs: Int)
        {
            self.layersDrawn = layersDrawn; self.layersVisited = layersVisited; self.animations = animations; self.groups = groups
            self.shadowRasters = shadowRasters; self.textureUploads = textureUploads; self.textureBytes = textureBytes
            self.targetsCreated = targetsCreated; self.drawCalls = drawCalls; self.offscreenPasses = offscreenPasses
            self.offscreenPixels = offscreenPixels; self.blurs = blurs
        }

        public static func - (a: Reading, b: Reading) -> Reading {
            Reading(layersDrawn: a.layersDrawn - b.layersDrawn, layersVisited: a.layersVisited - b.layersVisited, animations: a.animations - b.animations,
                    groups: a.groups - b.groups, shadowRasters: a.shadowRasters - b.shadowRasters, textureUploads: a.textureUploads - b.textureUploads,
                    textureBytes: a.textureBytes - b.textureBytes, targetsCreated: a.targetsCreated - b.targetsCreated, drawCalls: a.drawCalls - b.drawCalls,
                    offscreenPasses: a.offscreenPasses - b.offscreenPasses, offscreenPixels: a.offscreenPixels - b.offscreenPixels, blurs: a.blurs - b.blurs)
        }
    }

    public static func reading() -> Reading {
        Reading(layersDrawn: layersDrawn, layersVisited: layersVisited, animations: animations, groups: groups, shadowRasters: shadowRasters,
                textureUploads: textureUploads, textureBytes: textureBytes, targetsCreated: targetsCreated, drawCalls: drawCalls,
                offscreenPasses: offscreenPasses, offscreenPixels: offscreenPixels, blurs: blurs)
    }

    nonisolated(unsafe) private static var lastSummary = Reading()

    /// One line of counts since the last summary.
    public static func takeSummary(frames: Int) -> String {
        let n = max(1, frames)
        let now = reading()
        let d = now - lastSummary
        lastSummary = now
        return "layers \(d.layersDrawn / n) drawn of \(d.layersVisited / n), animations \(d.animations / n), groups \(d.groups / n), "
            + "draws \(d.drawCalls / n), offscreen passes \(d.offscreenPasses / n), "
            + "shadow rasters \(d.shadowRasters), texture uploads \(d.textureUploads), new targets \(d.targetsCreated)"
    }
}

/// A colour as a key: its four parts.
struct ColorKey: Hashable {
    let red: Double, green: Double, blue: Double, alpha: Double

    init?(_ color: CGColor?) {
        guard let rgba = color?.rgba else { return nil }
        red = Double(rgba.0); green = Double(rgba.1); blue = Double(rgba.2); alpha = Double(rgba.3)
    }
}

/// What a drawn shape depends on.
private struct ShapeKey: Hashable {
    let elements: [PathElement]
    let fill: ColorKey?
    let stroke: ColorKey?
    let lineWidth: CGFloat
    let density: CGFloat
    let fillRule: CAShapeLayerFillRule
    let lineCap: CAShapeLayerLineCap
    let lineJoin: CAShapeLayerLineJoin
}

/// A shadow is the same for the same shape, blur and resolution, whichever path object says
/// the shape: First Row makes a new path each time it lays a layer out.
private struct ShadowKey: Hashable {
    let elements: [PathElement]
    let radius: CGFloat
    let densityStep: Int

    init(path: CGPath, radius: CGFloat, densityStep: Int) {
        elements = path.elements
        self.radius = radius
        self.densityStep = densityStep
    }
}

/// Blurred shadow shapes, the oldest dropped once they pass a memory budget.
private struct ShadowCache {
    private var entries: [ShadowKey: CGImage] = [:]
    private var order: [ShadowKey] = []
    private var bytes = 0
    private let budget = 48 * 1024 * 1024

    func image(for key: ShadowKey) -> CGImage? {
        entries[key]
    }

    mutating func insert(_ image: CGImage, for key: ShadowKey) {
        if let old = entries.removeValue(forKey: key) {
            bytes -= old.bytesPerRow * old.height
            order.removeAll { $0 == key }
        }
        entries[key] = image
        order.append(key)
        bytes += image.bytesPerRow * image.height
        while bytes > budget, order.count > 1 {
            let oldest = order.removeFirst()
            if let dropped = entries.removeValue(forKey: oldest) {
                bytes -= dropped.bytesPerRow * dropped.height
            }
        }
    }
}
