import CoreGraphics
import CPortable
import Foundation

/// A GPU copy of a CGImage, freed (on the render thread) when the image goes away, or when
/// it hasn't been drawn in a while and there are too many (`deleteIdleTextures`).
final class TextureBox: CGImageRendererResource {
    let texture: GLuint
    let width: Int
    let height: Int
    /// The picture it was made of, which holds it.
    weak var picture: CGImage?
    /// When it was last drawn.
    var lastUsed: CFTimeInterval = 0

    init(texture: GLuint, width: Int, height: Int) {
        self.texture = texture
        self.width = width
        self.height = height
    }

    deinit {
        GLDevice.retire(texture)
    }
}

/// An offscreen colour target.
final class RenderTarget {
    let framebuffer: GLuint
    let texture: GLuint
    let width: Int
    let height: Int
    /// When it was last handed back (to tell the ones nothing uses any more).
    var lastUsed: CFTimeInterval = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        RenderStats.targetsCreated += 1
        var tex: GLuint = 0
        glGenTextures(1, &tex)
        glBindTexture(GL_TEXTURE_2D, tex)
        glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA8), GLsizei(width), GLsizei(height), 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_EDGE))
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_EDGE))
        texture = tex
        var fbo: GLuint = 0
        glGenFramebuffers(1, &fbo)
        glBindFramebuffer(GL_FRAMEBUFFER, fbo)
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0)
        framebuffer = fbo
    }

    func destroy() {
        var fbo = framebuffer
        var tex = texture
        glDeleteFramebuffers(1, &fbo)
        glDeleteTextures(1, &tex)
    }
}

/// Shaders, buffers and textures for drawing layers.
final class GLDevice {
    struct Program {
        let id: GLuint
        let mvp: GLint
        let rect: GLint
        let uv: GLint
        let color: GLint
        let mode: GLint
        let bounds: GLint
        let radius: GLint
        let border: GLint
        let edges: GLint
        let gradient: GLint
        let sampler: GLint
        let maskSampler: GLint
        let maskKind: GLint
        let maskPlace: GLint
        let maskGradient: GLint
        let shadow: GLint
    }

    struct BlurProgram {
        let id: GLuint
        let direction: GLint
        let sigma: GLint
        let sampler: GLint
    }

    enum Mode: GLint {
        case solid = 0
        case texture = 1
        case axialGradient = 2
        case radialGradient = 3
        case textureMasked = 4
        case shadowFromAlpha = 5
        /// The shadow of a box (in `gradient`, as x, y, width, height), worked out per pixel.
        case shadowBox = 6
    }

    private static let retiredLock = NSLock()
    nonisolated(unsafe) private static var retired: [GLuint] = []

    static func retire(_ texture: GLuint) {
        retiredLock.lock()
        retired.append(texture)
        retiredLock.unlock()
    }

    let program: Program
    let blur: BlurProgram
    let vao: GLuint
    let vbo: GLuint
    private var targetPool: [RenderTarget] = []
    /// Every texture made of a picture, to find the ones not drawn in a while.
    private var pictureTextures: [PictureTexture] = []
    private var lastTextureSweep: CFTimeInterval = 0
    /// How many bytes of pictures' textures there may be before idle ones are deleted.
    private let textureBudget = 96 * 1024 * 1024

    private struct PictureTexture {
        weak var box: TextureBox?
    }
    private struct GradientKey: Hashable {
        let colors: [ColorKey?]
        let locations: [Double]?
    }

    private var gradientCache: [GradientKey: GLuint] = [:]
    private(set) var maxTextureSize: Int = 4096

    init() throws {
        var vertexArray: GLuint = 0
        glGenVertexArrays(1, &vertexArray)
        glBindVertexArray(vertexArray)
        vao = vertexArray
        var buffer: GLuint = 0
        glGenBuffers(1, &buffer)
        glBindBuffer(GL_ARRAY_BUFFER, buffer)
        let quad: [GLfloat] = [0, 0, 1, 0, 0, 1, 1, 1]
        quad.withUnsafeBytes { glBufferData(GL_ARRAY_BUFFER, $0.count, $0.baseAddress, GL_STATIC_DRAW) }
        glVertexAttribPointer(0, 2, GLenum(GL_FLOAT), GL_FALSE, 8, nil)
        glEnableVertexAttribArray(0)
        vbo = buffer
        var size: GLint = 0
        glGetIntegerv(GL_MAX_TEXTURE_SIZE, &size)
        if size > 0 { maxTextureSize = Int(min(size, 8192)) }

        let main = try Self.link(vertex: Shaders.vertex, fragment: Shaders.fragment)
        program = Program(
            id: main,
            mvp: glGetUniformLocation(main, "uMVP"),
            rect: glGetUniformLocation(main, "uRect"),
            uv: glGetUniformLocation(main, "uUV"),
            color: glGetUniformLocation(main, "uColor"),
            mode: glGetUniformLocation(main, "uMode"),
            bounds: glGetUniformLocation(main, "uBounds"),
            radius: glGetUniformLocation(main, "uRadius"),
            border: glGetUniformLocation(main, "uBorder"),
            edges: glGetUniformLocation(main, "uEdges"),
            gradient: glGetUniformLocation(main, "uGradient"),
            sampler: glGetUniformLocation(main, "uTexture"),
            maskSampler: glGetUniformLocation(main, "uMask"),
            maskKind: glGetUniformLocation(main, "uMaskKind"),
            maskPlace: glGetUniformLocation(main, "uMaskPlace"),
            maskGradient: glGetUniformLocation(main, "uMaskGradient"),
            shadow: glGetUniformLocation(main, "uShadow"),
        )
        let blurID = try Self.link(vertex: Shaders.blurVertex, fragment: Shaders.blurFragment)
        blur = BlurProgram(id: blurID, direction: glGetUniformLocation(blurID, "uDirection"), sigma: glGetUniformLocation(blurID, "uSigma"), sampler: glGetUniformLocation(blurID, "uTexture"))
        glUseProgram(main)
        glUniform1i(program.sampler, 0)
        glUniform1i(program.maskSampler, 1)
    }

    private static func compile(_ source: String, _ type: GLenum) throws -> GLuint {
        let shader = glCreateShader(type)
        source.withCString { pointer in
            var p: UnsafePointer<GLchar>? = pointer
            glShaderSource(shader, 1, &p, nil)
        }
        glCompileShader(shader)
        var ok: GLint = 0
        glGetShaderiv(shader, GL_COMPILE_STATUS, &ok)
        if ok == 0 {
            var log = [GLchar](repeating: 0, count: 4096)
            glGetShaderInfoLog(shader, 4096, nil, &log)
            throw CompositorError.shader(String(cString: log))
        }
        return shader
    }

    private static func link(vertex: String, fragment: String) throws -> GLuint {
        let vs = try compile(vertex, GL_VERTEX_SHADER)
        let fs = try compile(fragment, GL_FRAGMENT_SHADER)
        let program = glCreateProgram()
        glAttachShader(program, vs)
        glAttachShader(program, fs)
        glBindAttribLocation(program, 0, "aPosition")
        glLinkProgram(program)
        var ok: GLint = 0
        glGetProgramiv(program, GL_LINK_STATUS, &ok)
        glDeleteShader(vs)
        glDeleteShader(fs)
        if ok == 0 {
            var log = [GLchar](repeating: 0, count: 4096)
            glGetProgramInfoLog(program, 4096, nil, &log)
            throw CompositorError.shader(String(cString: log))
        }
        return program
    }

    /// Destroys the targets nothing has used for a few seconds. A change of screen (a fade, a
    /// blur coming in) needs several screen-sized targets for a moment; kept, they were
    /// tens of megabytes each on a large screen, 24 deep.
    func destroyIdleTargets() {
        guard !targetPool.isEmpty else { return }
        let now = CACurrentMediaTime()
        targetPool.removeAll { target in
            guard now - target.lastUsed > 3 else { return false }
            target.destroy()
            return true
        }
    }

    /// Deletes the textures of pictures not drawn for ten seconds, longest ago first, while
    /// there are more than the budget's worth. A picture kept by a cache (a cover that was
    /// scrolled past) kept its texture as long: after a long list, hundreds of megabytes. It
    /// keeps its pixels, and gets a texture again if it's drawn again.
    func deleteIdleTextures() {
        let now = CACurrentMediaTime()
        guard now - lastTextureSweep > 2 else { return }
        lastTextureSweep = now
        pictureTextures.removeAll { $0.box == nil }
        var total = pictureTextures.reduce(0) { $0 + ($1.box.map { $0.width * $0.height * 4 } ?? 0) }
        guard total > textureBudget else { return }
        let idle = pictureTextures.compactMap(\.box).filter { now - $0.lastUsed > 10 }.sorted { $0.lastUsed < $1.lastUsed }
        for box in idle {
            guard total > textureBudget else { break }
            total -= box.width * box.height * 4
            // (The picture held it: let go of, it's deleted with the next frame's retired ones.)
            box.picture?.rendererResource = nil
        }
    }

    func deleteRetiredTextures() {
        Self.retiredLock.lock()
        let list = Self.retired
        Self.retired.removeAll()
        Self.retiredLock.unlock()
        guard !list.isEmpty else { return }
        list.withUnsafeBufferPointer { glDeleteTextures(GLsizei($0.count), $0.baseAddress) }
    }

    /// The texture for an image, uploaded on first use.
    func texture(for image: CGImage) -> TextureBox? {
        if let box = image.rendererResource as? TextureBox {
            box.lastUsed = CACurrentMediaTime()
            return box
        }
        guard image.width > 0, image.height > 0 else { return nil }
        var source = image
        if image.width > maxTextureSize || image.height > maxTextureSize {
            let scale = CGFloat(maxTextureSize) / CGFloat(max(image.width, image.height))
            source = image.resized(width: max(1, Int(CGFloat(image.width) * scale)), height: max(1, Int(CGFloat(image.height) * scale))) ?? image
        }
        var tex: GLuint = 0
        glGenTextures(1, &tex)
        glBindTexture(GL_TEXTURE_2D, tex)
        glPixelStorei(GL_UNPACK_ALIGNMENT, 4)
        glPixelStorei(GL_UNPACK_ROW_LENGTH, GLint(source.bytesPerRow / 4))
        glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA8), GLsizei(source.width), GLsizei(source.height), 0, GL_BGRA, GL_UNSIGNED_BYTE, source.storage.bytes)
        glPixelStorei(GL_UNPACK_ROW_LENGTH, 0)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_EDGE))
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_EDGE))
        let box = TextureBox(texture: tex, width: source.width, height: source.height)
        box.picture = image
        box.lastUsed = CACurrentMediaTime()
        pictureTextures.append(PictureTexture(box: box))
        RenderStats.textureUploads += 1
        RenderStats.textureBytes += source.width * source.height * 4
        image.rendererResource = box
        return box
    }

    /// A 256-pixel strip of a gradient, premultiplied.
    func gradientTexture(colors: [CGColor], locations: [Double]?) -> GLuint {
        let key = GradientKey(colors: colors.map { ColorKey($0) }, locations: locations)
        if let cached = gradientCache[key] { return cached }
        let stops: [Double] = locations ?? colors.indices.map { colors.count > 1 ? Double($0) / Double(colors.count - 1) : 0 }
        var pixels = [UInt8](repeating: 0, count: 256 * 4)
        for i in 0 ..< 256 {
            let t = Double(i) / 255
            var color = colors.first?.rgba ?? (0, 0, 0, 0)
            if let last = stops.indices.last, t >= stops[last] {
                color = colors[min(last, colors.count - 1)].rgba
            } else if !stops.isEmpty, t > stops[0] {
                for s in 0 ..< stops.count - 1 where t >= stops[s] && t <= stops[s + 1] {
                    let span = stops[s + 1] - stops[s]
                    let f = CGFloat(span > 0 ? (t - stops[s]) / span : 0)
                    let a = colors[min(s, colors.count - 1)].rgba
                    let b = colors[min(s + 1, colors.count - 1)].rgba
                    color = (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f, a.3 + (b.3 - a.3) * f)
                    break
                }
            }
            let alpha = max(0, min(1, color.3))
            pixels[i * 4] = UInt8(max(0, min(1, color.0)) * alpha * 255 + 0.5)
            pixels[i * 4 + 1] = UInt8(max(0, min(1, color.1)) * alpha * 255 + 0.5)
            pixels[i * 4 + 2] = UInt8(max(0, min(1, color.2)) * alpha * 255 + 0.5)
            pixels[i * 4 + 3] = UInt8(alpha * 255 + 0.5)
        }
        var tex: GLuint = 0
        glGenTextures(1, &tex)
        glBindTexture(GL_TEXTURE_2D, tex)
        glPixelStorei(GL_UNPACK_ALIGNMENT, 4)
        glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA8), 256, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_EDGE))
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_EDGE))
        if gradientCache.count > 256 {
            for (_, texture) in gradientCache {
                var t = texture
                glDeleteTextures(1, &t)
            }
            gradientCache.removeAll()
        }
        gradientCache[key] = tex
        return tex
    }

    func acquireTarget(width: Int, height: Int) -> RenderTarget {
        if let index = targetPool.firstIndex(where: { $0.width == width && $0.height == height }) {
            return targetPool.remove(at: index)
        }
        return RenderTarget(width: width, height: height)
    }

    func releaseTarget(_ target: RenderTarget) {
        target.lastUsed = CACurrentMediaTime()
        targetPool.append(target)
        if targetPool.count > 24 {
            targetPool.removeFirst().destroy()
        }
    }
}

enum CompositorError: Error, CustomStringConvertible {
    case shader(String)
    case loader(Int)

    var description: String {
        switch self {
        case let .shader(log): "shader failed: \(log)"
        case let .loader(missing): "\(missing) OpenGL entry points are missing"
        }
    }
}

enum Shaders {
    static let vertex = """
    #version 330 core
    layout(location = 0) in vec2 aPosition;
    uniform mat4 uMVP;
    uniform vec4 uRect;
    uniform vec4 uUV;
    out vec2 vLocal;
    out vec2 vUV;
    void main() {
        vec2 local = uRect.xy + aPosition * uRect.zw;
        vLocal = local;
        vUV = mix(uUV.xy, uUV.zw, aPosition);
        gl_Position = uMVP * vec4(local, 0.0, 1.0);
    }
    """

    static let fragment = """
    #version 330 core
    in vec2 vLocal;
    in vec2 vUV;
    uniform vec4 uColor;
    uniform int uMode;
    uniform vec4 uBounds;
    uniform float uRadius;
    uniform float uBorder;
    uniform vec4 uEdges;
    uniform vec4 uGradient;
    uniform sampler2D uTexture;
    uniform sampler2D uMask;
    // A mask put on as the quad is drawn: 0 none, 1 a picture's alpha, 2 a gradient's alpha.
    uniform int uMaskKind;
    // vLocal * xy + zw is the place in the mask's own square (0...1).
    uniform vec4 uMaskPlace;
    uniform vec4 uMaskGradient;
    // For a box's shadow: the blur's standard deviation and the box's corner radius.
    uniform vec2 uShadow;
    out vec4 fragColor;

    float erfNear(float x) {
        float a = abs(x);
        float t = 1.0 / (1.0 + 0.3275911 * a);
        float y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-a * a);
        return x < 0.0 ? -y : y;
    }

    // How much of a blurred box lies over `p`: 1 well inside, 0 well outside. A plain box's
    // blur is exact (the two directions separate). With rounded corners the blur across is
    // exact for each row, and the rows are summed at a few heights.
    float boxShadow(vec2 p, vec4 box, float sigma, float corner) {
        vec2 half_ = box.zw * 0.5;
        vec2 q = p - (box.xy + half_);
        float k = 0.70710678 / sigma;
        if (corner <= 0.0) {
            float across = erfNear((q.x + half_.x) * k) - erfNear((q.x - half_.x) * k);
            float down = erfNear((q.y + half_.y) * k) - erfNear((q.y - half_.y) * k);
            return 0.25 * across * down;
        }
        float low = q.y - half_.y;
        float high = q.y + half_.y;
        float from = clamp(-3.0 * sigma, low, high);
        float to = clamp(3.0 * sigma, low, high);
        const int rows = 8;
        float gap = (to - from) / float(rows);
        float value = 0.0;
        for (int i = 0; i < rows; i++) {
            float y = from + gap * (float(i) + 0.5);
            // The row this far up or down, and how far its ends are from the middle.
            float inset = min(half_.y - corner - abs(q.y - y), 0.0);
            float reach = half_.x - corner + sqrt(max(0.0, corner * corner - inset * inset));
            float across = 0.5 * (erfNear((q.x + reach) * k) - erfNear((q.x - reach) * k));
            value += across * exp(-(y * y) / (2.0 * sigma * sigma)) / (2.50662827 * sigma) * gap;
        }
        return value;
    }

    float pixels(float distance, float axis) {
        vec2 g = vec2(dFdx(axis), dFdy(axis));
        float len = length(g);
        return len > 0.0 ? distance / len : 1e6;
    }

    // Signed distance (negative inside) to a rounded rectangle.
    float roundedDistance(vec2 p, vec4 rect, float radius) {
        vec2 center = rect.xy + rect.zw * 0.5;
        vec2 half_ = rect.zw * 0.5;
        float r = min(radius, min(half_.x, half_.y));
        vec2 q = abs(p - center) - half_ + vec2(r);
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    void main() {
        vec4 color;
        if (uMode == 1 || uMode == 4) {
            color = texture(uTexture, vUV) * uColor.a;
            if (uMode == 4) color *= texture(uMask, vUV).a;
        } else if (uMode == 2) {
            vec2 dir = uGradient.zw - uGradient.xy;
            float len2 = max(dot(dir, dir), 1e-12);
            float t = clamp(dot(vUV - uGradient.xy, dir) / len2, 0.0, 1.0);
            color = texture(uTexture, vec2(t, 0.5)) * uColor.a;
        } else if (uMode == 3) {
            vec2 radii = max(abs(uGradient.zw - uGradient.xy), vec2(1e-6));
            float t = clamp(length((vUV - uGradient.xy) / radii), 0.0, 1.0);
            color = texture(uTexture, vec2(t, 0.5)) * uColor.a;
        } else if (uMode == 5) {
            color = uColor * texture(uTexture, vUV).a;
        } else if (uMode == 6) {
            color = uColor * boxShadow(vLocal, uGradient, max(uShadow.x, 0.01), uShadow.y);
        } else {
            color = uColor;
        }
        float coverage = 1.0;
        if (uRadius > 0.0 || uBorder > 0.0) {
            float d = roundedDistance(vLocal, uBounds, uRadius);
            float w = length(vec2(dFdx(vLocal.x), dFdy(vLocal.x)));
            float h = length(vec2(dFdx(vLocal.y), dFdy(vLocal.y)));
            float aa = max(max(w, h), 1e-6);
            coverage *= clamp(0.5 - d / aa, 0.0, 1.0);
            if (uBorder > 0.0) {
                float inner = roundedDistance(vLocal, vec4(uBounds.xy + vec2(uBorder), uBounds.zw - vec2(uBorder * 2.0)), max(uRadius - uBorder, 0.0));
                coverage *= clamp(0.5 + inner / aa, 0.0, 1.0);
            }
        }
        // Edge antialiasing on the quad's outer edges (uEdges: left, bottom, right, top).
        if (uEdges.x > 0.0) coverage *= clamp(pixels(vLocal.x - uBounds.x, vLocal.x) + 0.5, 0.0, 1.0);
        if (uEdges.y > 0.0) coverage *= clamp(pixels(vLocal.y - uBounds.y, vLocal.y) + 0.5, 0.0, 1.0);
        if (uEdges.z > 0.0) coverage *= clamp(pixels(uBounds.x + uBounds.z - vLocal.x, vLocal.x) + 0.5, 0.0, 1.0);
        if (uEdges.w > 0.0) coverage *= clamp(pixels(uBounds.y + uBounds.w - vLocal.y, vLocal.y) + 0.5, 0.0, 1.0);
        if (uMaskKind != 0) {
            vec2 m = vLocal * uMaskPlace.xy + uMaskPlace.zw;
            if (m.x < 0.0 || m.y < 0.0 || m.x > 1.0 || m.y > 1.0) {
                coverage = 0.0;
            } else if (uMaskKind == 1) {
                coverage *= texture(uMask, m).a;
            } else {
                vec2 dir = uMaskGradient.zw - uMaskGradient.xy;
                float t = clamp(dot(m - uMaskGradient.xy, dir) / max(dot(dir, dir), 1e-12), 0.0, 1.0);
                coverage *= texture(uMask, vec2(t, 0.5)).a;
            }
        }
        fragColor = color * coverage;
    }
    """

    static let blurVertex = """
    #version 330 core
    layout(location = 0) in vec2 aPosition;
    out vec2 vUV;
    void main() {
        vUV = aPosition;
        gl_Position = vec4(aPosition * 2.0 - 1.0, 0.0, 1.0);
    }
    """

    static let blurFragment = """
    #version 330 core
    in vec2 vUV;
    uniform sampler2D uTexture;
    uniform vec2 uDirection;
    uniform float uSigma;
    out vec4 fragColor;
    void main() {
        int radius = int(ceil(uSigma * 3.0));
        vec2 texel = uDirection / vec2(textureSize(uTexture, 0));
        vec4 sum = vec4(0.0);
        float total = 0.0;
        for (int i = -radius; i <= radius; i++) {
            float w = exp(-0.5 * float(i * i) / (uSigma * uSigma));
            vec2 uv = vUV + texel * float(i);
            vec4 s = (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) ? vec4(0.0) : texture(uTexture, uv);
            sum += s * w;
            total += w;
        }
        fragColor = sum / total;
    }
    """
}
