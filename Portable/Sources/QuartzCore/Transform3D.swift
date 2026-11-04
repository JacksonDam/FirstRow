import CoreGraphics
import Foundation

/// A 4x4 transform with Core Animation's layout: points are row vectors, so translation sits
/// in m41...m43 and perspective in m34.
public struct CATransform3D: Equatable, Sendable {
    public var m11: CGFloat, m12: CGFloat, m13: CGFloat, m14: CGFloat
    public var m21: CGFloat, m22: CGFloat, m23: CGFloat, m24: CGFloat
    public var m31: CGFloat, m32: CGFloat, m33: CGFloat, m34: CGFloat
    public var m41: CGFloat, m42: CGFloat, m43: CGFloat, m44: CGFloat

    public init() {
        m11 = 1; m12 = 0; m13 = 0; m14 = 0
        m21 = 0; m22 = 1; m23 = 0; m24 = 0
        m31 = 0; m32 = 0; m33 = 1; m34 = 0
        m41 = 0; m42 = 0; m43 = 0; m44 = 1
    }

    public init(m11: CGFloat, m12: CGFloat, m13: CGFloat, m14: CGFloat,
                m21: CGFloat, m22: CGFloat, m23: CGFloat, m24: CGFloat,
                m31: CGFloat, m32: CGFloat, m33: CGFloat, m34: CGFloat,
                m41: CGFloat, m42: CGFloat, m43: CGFloat, m44: CGFloat)
    {
        self.m11 = m11; self.m12 = m12; self.m13 = m13; self.m14 = m14
        self.m21 = m21; self.m22 = m22; self.m23 = m23; self.m24 = m24
        self.m31 = m31; self.m32 = m32; self.m33 = m33; self.m34 = m34
        self.m41 = m41; self.m42 = m42; self.m43 = m43; self.m44 = m44
    }

    init(rows: [[CGFloat]]) {
        self.init(m11: rows[0][0], m12: rows[0][1], m13: rows[0][2], m14: rows[0][3],
                  m21: rows[1][0], m22: rows[1][1], m23: rows[1][2], m24: rows[1][3],
                  m31: rows[2][0], m32: rows[2][1], m33: rows[2][2], m34: rows[2][3],
                  m41: rows[3][0], m42: rows[3][1], m43: rows[3][2], m44: rows[3][3])
    }

    var rows: [[CGFloat]] {
        [[m11, m12, m13, m14], [m21, m22, m23, m24], [m31, m32, m33, m34], [m41, m42, m43, m44]]
    }

    var values: [CGFloat] { rows.flatMap { $0 } }

    init(values v: [CGFloat]) {
        self.init(m11: v[0], m12: v[1], m13: v[2], m14: v[3], m21: v[4], m22: v[5], m23: v[6], m24: v[7],
                  m31: v[8], m32: v[9], m33: v[10], m34: v[11], m41: v[12], m42: v[13], m43: v[14], m44: v[15])
    }

    /// `self` applied first, then `other`.
    func then(_ other: CATransform3D) -> CATransform3D {
        let a = rows
        let b = other.rows
        var out = [[CGFloat]](repeating: [0, 0, 0, 0], count: 4)
        for i in 0 ..< 4 {
            for j in 0 ..< 4 {
                out[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j]
            }
        }
        return CATransform3D(rows: out)
    }

    /// Maps a point, returning homogeneous coordinates.
    func apply(x: CGFloat, y: CGFloat, z: CGFloat = 0) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        (x * m11 + y * m21 + z * m31 + m41,
         x * m12 + y * m22 + z * m32 + m42,
         x * m13 + y * m23 + z * m33 + m43,
         x * m14 + y * m24 + z * m34 + m44)
    }

    /// Drops z, as a layer does when it draws its sublayers into its own plane.
    var flattened: CATransform3D {
        var t = self
        t.m13 = 0; t.m23 = 0; t.m43 = 0
        t.m31 = 0; t.m32 = 0; t.m33 = 1; t.m34 = 0
        return t
    }
}

public let CATransform3DIdentity = CATransform3D()

public func CATransform3DIsIdentity(_ t: CATransform3D) -> Bool { t == CATransform3DIdentity }
public func CATransform3DEqualToTransform(_ a: CATransform3D, _ b: CATransform3D) -> Bool { a == b }

public func CATransform3DMakeTranslation(_ tx: CGFloat, _ ty: CGFloat, _ tz: CGFloat) -> CATransform3D {
    var t = CATransform3D()
    t.m41 = tx; t.m42 = ty; t.m43 = tz
    return t
}

public func CATransform3DMakeScale(_ sx: CGFloat, _ sy: CGFloat, _ sz: CGFloat) -> CATransform3D {
    var t = CATransform3D()
    t.m11 = sx; t.m22 = sy; t.m33 = sz
    return t
}

public func CATransform3DMakeRotation(_ angle: CGFloat, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CATransform3D {
    let length = sqrt(x * x + y * y + z * z)
    guard length > 0 else { return CATransform3DIdentity }
    let (ux, uy, uz) = (x / length, y / length, z / length)
    let c = cos(angle)
    let s = sin(angle)
    let t = 1 - c
    var m = CATransform3D()
    m.m11 = t * ux * ux + c
    m.m12 = t * ux * uy + s * uz
    m.m13 = t * ux * uz - s * uy
    m.m21 = t * ux * uy - s * uz
    m.m22 = t * uy * uy + c
    m.m23 = t * uy * uz + s * ux
    m.m31 = t * ux * uz + s * uy
    m.m32 = t * uy * uz - s * ux
    m.m33 = t * uz * uz + c
    return m
}

/// `a` applied first, then `b`.
public func CATransform3DConcat(_ a: CATransform3D, _ b: CATransform3D) -> CATransform3D { a.then(b) }

public func CATransform3DTranslate(_ t: CATransform3D, _ tx: CGFloat, _ ty: CGFloat, _ tz: CGFloat) -> CATransform3D {
    CATransform3DMakeTranslation(tx, ty, tz).then(t)
}

public func CATransform3DScale(_ t: CATransform3D, _ sx: CGFloat, _ sy: CGFloat, _ sz: CGFloat) -> CATransform3D {
    CATransform3DMakeScale(sx, sy, sz).then(t)
}

public func CATransform3DRotate(_ t: CATransform3D, _ angle: CGFloat, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CATransform3D {
    CATransform3DMakeRotation(angle, x, y, z).then(t)
}

public func CATransform3DInvert(_ t: CATransform3D) -> CATransform3D {
    let m = t.values.map { Double($0) }
    var inv = [Double](repeating: 0, count: 16)
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10]
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10]
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9]
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9]
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10]
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10]
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9]
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9]
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6]
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6]
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5]
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5]
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6]
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6]
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5]
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5]
    let det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12]
    guard abs(det) > 1e-12 else { return t }
    return CATransform3D(values: inv.map { CGFloat($0 / det) })
}

public func CATransform3DMakeAffineTransform(_ m: CGAffineTransform) -> CATransform3D {
    var t = CATransform3D()
    t.m11 = m.a; t.m12 = m.b
    t.m21 = m.c; t.m22 = m.d
    t.m41 = m.tx; t.m42 = m.ty
    return t
}

public func CATransform3DIsAffine(_ t: CATransform3D) -> Bool {
    t.m13 == 0 && t.m14 == 0 && t.m23 == 0 && t.m24 == 0 && t.m31 == 0 && t.m32 == 0 && t.m33 == 1 && t.m34 == 0 && t.m43 == 0 && t.m44 == 1
}

public func CATransform3DGetAffineTransform(_ t: CATransform3D) -> CGAffineTransform {
    CGAffineTransform(a: t.m11, b: t.m12, c: t.m21, d: t.m22, tx: t.m41, ty: t.m42)
}

// MARK: Boxing

/// Holds a transform where Core Animation code expects an `NSValue`.
public final class CATransform3DValue: NSValue, @unchecked Sendable {
    public let transform: CATransform3D
    private static let typeEncoding: UnsafePointer<CChar> = UnsafePointer(strdup("{CATransform3D=dddddddddddddddd}")!)

    public init(_ transform: CATransform3D) {
        self.transform = transform
        super.init()
    }

    public required init(bytes value: UnsafeRawPointer, objCType type: UnsafePointer<CChar>) {
        transform = value.load(as: CATransform3D.self)
        super.init()
    }

    public required init?(coder _: NSCoder) {
        nil
    }

    override public var objCType: UnsafePointer<CChar> { Self.typeEncoding }

    override public func isEqual(_ object: Any?) -> Bool {
        (object as? CATransform3DValue)?.transform == transform
    }

    override public var hash: Int { Int(transform.m11 * 1000 + transform.m22 * 100 + transform.m41 + transform.m42) }

    override public func copy(with _: NSZone? = nil) -> Any { self }
}

/// Spelled like the initialiser on Apple platforms, which Linux's NSValue can't provide.
public func NSValue(caTransform3D transform: CATransform3D) -> NSValue {
    CATransform3DValue(transform)
}

extension NSValue {
    public var caTransform3DValue: CATransform3D {
        (self as? CATransform3DValue)?.transform ?? CATransform3DIdentity
    }
}

// MARK: Interpolation

/// A transform split into parts that interpolate sensibly, as Core Animation does between
/// two arbitrary matrices.
struct DecomposedTransform {
    var scale: (CGFloat, CGFloat, CGFloat)
    var skew: (CGFloat, CGFloat, CGFloat)
    var quaternion: (Double, Double, Double, Double)
    var translate: (CGFloat, CGFloat, CGFloat)
    var perspective: (CGFloat, CGFloat, CGFloat, CGFloat)

    init?(_ t: CATransform3D) {
        var m = t.rows.map { $0.map { Double($0) } }
        guard abs(m[3][3]) > 1e-12 else { return nil }
        for i in 0 ..< 4 { for j in 0 ..< 4 { m[i][j] /= m[3][3] } }
        var pm = m
        for i in 0 ..< 3 { pm[i][3] = 0 }
        pm[3][3] = 1
        let det = Self.determinant(pm)
        guard abs(det) > 1e-12 else { return nil }
        if m[0][3] != 0 || m[1][3] != 0 || m[2][3] != 0 {
            let rhs = [m[0][3], m[1][3], m[2][3], m[3][3]]
            let inverse = CATransform3DInvert(CATransform3D(rows: pm.map { $0.map { CGFloat($0) } })).rows.map { $0.map { Double($0) } }
            // Solve rhs = perspective * pm, so perspective = rhs * inverse(pm) transposed.
            var p = [0.0, 0.0, 0.0, 0.0]
            for j in 0 ..< 4 {
                p[j] = rhs[0] * inverse[j][0] + rhs[1] * inverse[j][1] + rhs[2] * inverse[j][2] + rhs[3] * inverse[j][3]
            }
            perspective = (CGFloat(p[0]), CGFloat(p[1]), CGFloat(p[2]), CGFloat(p[3]))
        } else {
            perspective = (0, 0, 0, 1)
        }
        translate = (CGFloat(m[3][0]), CGFloat(m[3][1]), CGFloat(m[3][2]))
        var row = [[m[0][0], m[0][1], m[0][2]], [m[1][0], m[1][1], m[1][2]], [m[2][0], m[2][1], m[2][2]]]
        func length(_ v: [Double]) -> Double { sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) }
        func normalize(_ v: [Double]) -> [Double] { let l = length(v); return l == 0 ? v : v.map { $0 / l } }
        func dot(_ a: [Double], _ b: [Double]) -> Double { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
        func combine(_ a: [Double], _ b: [Double], _ ascl: Double, _ bscl: Double) -> [Double] {
            [ascl * a[0] + bscl * b[0], ascl * a[1] + bscl * b[1], ascl * a[2] + bscl * b[2]]
        }
        func cross(_ a: [Double], _ b: [Double]) -> [Double] {
            [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
        }
        var sx = length(row[0])
        row[0] = normalize(row[0])
        var xy = dot(row[0], row[1])
        row[1] = combine(row[1], row[0], 1, -xy)
        var sy = length(row[1])
        row[1] = normalize(row[1])
        xy /= sy
        var xz = dot(row[0], row[2])
        row[2] = combine(row[2], row[0], 1, -xz)
        var yz = dot(row[1], row[2])
        row[2] = combine(row[2], row[1], 1, -yz)
        var sz = length(row[2])
        row[2] = normalize(row[2])
        xz /= sz
        yz /= sz
        if dot(row[0], cross(row[1], row[2])) < 0 {
            sx = -sx; sy = -sy; sz = -sz
            row = row.map { $0.map { -$0 } }
        }
        scale = (CGFloat(sx), CGFloat(sy), CGFloat(sz))
        skew = (CGFloat(xy), CGFloat(xz), CGFloat(yz))
        var w = 0.5 * sqrt(max(1 + row[0][0] + row[1][1] + row[2][2], 0))
        var x = 0.5 * sqrt(max(1 + row[0][0] - row[1][1] - row[2][2], 0))
        var y = 0.5 * sqrt(max(1 - row[0][0] + row[1][1] - row[2][2], 0))
        var z = 0.5 * sqrt(max(1 - row[0][0] - row[1][1] + row[2][2], 0))
        if row[2][1] > row[1][2] { x = -x }
        if row[0][2] > row[2][0] { y = -y }
        if row[1][0] > row[0][1] { z = -z }
        // Row-vector matrices store the transposed rotation, so flip the axis.
        x = -x; y = -y; z = -z
        let n = sqrt(x * x + y * y + z * z + w * w)
        if n > 0 { x /= n; y /= n; z /= n; w /= n }
        quaternion = (x, y, z, w)
    }

    static func determinant(_ m: [[Double]]) -> Double {
        let t = CATransform3D(rows: m.map { $0.map { CGFloat($0) } })
        let inv = CATransform3DInvert(t)
        // Cheap route: det via cofactor of first row from the inverse identity.
        let v = t.values.map { Double($0) }
        let i = inv.values.map { Double($0) }
        let d = v[0] * i[0] + v[1] * i[4] + v[2] * i[8] + v[3] * i[12]
        return d == 0 ? 0 : 1 / d
    }

    func recomposed() -> CATransform3D {
        let (x, y, z, w) = quaternion
        var r = CATransform3D()
        r.m11 = CGFloat(1 - 2 * (y * y + z * z))
        r.m12 = CGFloat(2 * (x * y - z * w))
        r.m13 = CGFloat(2 * (x * z + y * w))
        r.m21 = CGFloat(2 * (x * y + z * w))
        r.m22 = CGFloat(1 - 2 * (x * x + z * z))
        r.m23 = CGFloat(2 * (y * z - x * w))
        r.m31 = CGFloat(2 * (x * z - y * w))
        r.m32 = CGFloat(2 * (y * z + x * w))
        r.m33 = CGFloat(1 - 2 * (x * x + y * y))
        var linear = r
        if skew.2 != 0 { var s = CATransform3D(); s.m32 = skew.2; linear = s.then(linear) }
        if skew.1 != 0 { var s = CATransform3D(); s.m31 = skew.1; linear = s.then(linear) }
        if skew.0 != 0 { var s = CATransform3D(); s.m21 = skew.0; linear = s.then(linear) }
        linear = CATransform3DMakeScale(scale.0, scale.1, scale.2).then(linear)
        var affine = linear
        affine.m41 = translate.0; affine.m42 = translate.1; affine.m43 = translate.2
        // The perspective part is applied after everything else.
        var p = CATransform3D()
        p.m14 = perspective.0; p.m24 = perspective.1; p.m34 = perspective.2; p.m44 = perspective.3
        if perspective == (0, 0, 0, 1) { return affine }
        // Undo the earlier split: rows were divided through by the perspective factor.
        return affine.then(Self.perspectiveSolve(p))
    }

    /// The perspective matrix in the form the split recorded it.
    private static func perspectiveSolve(_ p: CATransform3D) -> CATransform3D {
        var m = CATransform3D()
        m.m14 = p.m14; m.m24 = p.m24; m.m34 = p.m34; m.m44 = p.m44
        return m
    }

    static func interpolate(_ a: DecomposedTransform, _ b: DecomposedTransform, _ t: Double) -> DecomposedTransform {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * CGFloat(t) }
        var out = a
        out.scale = (mix(a.scale.0, b.scale.0), mix(a.scale.1, b.scale.1), mix(a.scale.2, b.scale.2))
        out.skew = (mix(a.skew.0, b.skew.0), mix(a.skew.1, b.skew.1), mix(a.skew.2, b.skew.2))
        out.translate = (mix(a.translate.0, b.translate.0), mix(a.translate.1, b.translate.1), mix(a.translate.2, b.translate.2))
        out.perspective = (mix(a.perspective.0, b.perspective.0), mix(a.perspective.1, b.perspective.1), mix(a.perspective.2, b.perspective.2), mix(a.perspective.3, b.perspective.3))
        var (qa, qb) = (a.quaternion, b.quaternion)
        var dot = qa.0 * qb.0 + qa.1 * qb.1 + qa.2 * qb.2 + qa.3 * qb.3
        if dot < 0 {
            qb = (-qb.0, -qb.1, -qb.2, -qb.3)
            dot = -dot
        }
        dot = min(1, dot)
        if dot > 0.9995 {
            qa = (qa.0 + (qb.0 - qa.0) * t, qa.1 + (qb.1 - qa.1) * t, qa.2 + (qb.2 - qa.2) * t, qa.3 + (qb.3 - qa.3) * t)
            let n = sqrt(qa.0 * qa.0 + qa.1 * qa.1 + qa.2 * qa.2 + qa.3 * qa.3)
            out.quaternion = (qa.0 / n, qa.1 / n, qa.2 / n, qa.3 / n)
        } else {
            let theta = acos(dot)
            let sine = sin(theta)
            let wa = sin((1 - t) * theta) / sine
            let wb = sin(t * theta) / sine
            out.quaternion = (qa.0 * wa + qb.0 * wb, qa.1 * wa + qb.1 * wb, qa.2 * wa + qb.2 * wb, qa.3 * wa + qb.3 * wb)
        }
        return out
    }
}

/// Interpolates two transforms, falling back to element-wise blending when either can't be
/// decomposed.
func interpolateTransform(_ a: CATransform3D, _ b: CATransform3D, _ t: Double) -> CATransform3D {
    if a == b { return a }
    if let da = DecomposedTransform(a), let db = DecomposedTransform(b) {
        return DecomposedTransform.interpolate(da, db, t).recomposed()
    }
    return CATransform3D(values: zip(a.values, b.values).map { $0 + ($1 - $0) * CGFloat(t) })
}
