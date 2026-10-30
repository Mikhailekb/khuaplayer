import AppKit
import Metal
import QuartzCore

// Event-driven particle timeline. Played particles settle into a readable
// progress rail; unplayed particles remain suspended. Density comes from
// keyframe bitrate, color from thumbnail samples, and coverage from the
// thumbnail worker. Data is rebuilt for each media session.
//
// One floating-point Metal layer draws particles and additive halos. EDR is
// enabled only while hovering. Redraws stop when the effect converges and follow
// control visibility. User settings select the timeline style.

/// Rendering and interaction parameters, in points or seconds where indicated.
struct SPDustTuning {
    var grainsPerPt: Float = 5.5      // Particle budget per point of timeline width.
    var spread: Float = 6.4           // Hover band half-height in points; the unplayed side is tightened further to separate it from the played band.
    var spreadBias: Float = 2.0       // Vertical distribution pow(q, bias): larger values hug the line and thin out the fringe.
    var zone: Float = 15              // Transition-zone width around the playback frontier.
    var sizePt: Float = 1.09          // Base floating grain size in points.
    var restA: Float = 0.26           // Baseline opacity at rest.
    // A persistent central rail remains visible independently of thumbnail coverage.
    var railFrac: Float = 0.50        // Fraction of particles assigned to the persistent rail.
    var railHalf: Float = 2.0         //   Half-height, matched to the played band's visual thickness.
    var railA: Float = 0.45           // Rail baseline brightness.
    var lift: Float = 0.80            // Global brightness lift while hovering.
    var peak: Float = 1.9             // peak scales the profile-driven brightness lift.
    // The normalized shape combines an exponential spike with a wider Gaussian tail:
    // gs(d) = [exp(-d/glowTau) + glowTail*exp(-(d/glowTailR)^2)] / (1+glowTail).
    // The active profile is g = pk * gs, where pk includes hover and press strength.
    var glowTau: Float = 7            // Exponential spike decay length in points, excluding the wider Gaussian tail.
    var glowTail: Float = 0.25        // Relative afterglow amplitude.
    var glowTailR: Float = 20         // Afterglow gaussian radius in points.
    var hlG: Float = 0.375            // Geometric pull strength: c = g * hlG.
    var glowOver: Float = 2.2         // Overrange amplitude is A * tanh(glowOver * g), with A equal to
    // min(edrRef, max(0, currentHeadroom - 1)). Hover and press strength
    // determine the fraction used at the pointer; the profile attenuates it away from the pointer.
    var swell: Float = 0.5            // Settled-band half-height is settleHalf * (1 + swell * gs * O), where
    // gs is the normalized pointer profile and O is the hover expansion.
    // unplayedGain and playedGain scale their respective sides (defaults 0.7
    // and 0.8). The played-side SDR cap starts at playedGain and approaches
    // 1.0 only inside the active profile.
    var unplayedGain: Float = 0.7
    var playedGain: Float = 0.8
    var whitenK: Float = 1.0, whitenMax: Float = 0.7 // Grain whitening = min(whitenMax, whitenK * g): continuous, visible on non-EDR displays too.
    var haloR: Float = 5              // Halo radius in points: spills just past the line.
    var haloA: Float = 1.0            // Peak target after halo accumulation: normalized by grains per pixel so it no longer saturates into a flat top.
    var emberP: Float = 0.06, emberBase: Float = 1.22, emberK: Float = 2.3
    var unify: Float = 5.0            // Suspended-particle brightness and size compensation.
    var crest: Float = 2.34           // Front pile height in points.
    var settleA: Float = 2.2          // aMul = 1 + settleA·t
    var pressPk: Float = 0.34         // pk = O·(0.66 + pressPk·press)
    var aMin: Float = 0.62, aMax: Float = 1.0   // Unplayed-particle survival range as a fraction of the particle budget.
    var fogSize: Float = 1.3          // Suspended-particle size multiplier, approaching one as particles settle.
    var settleHalf: Float = 2.0       // Settled layer half-height in points; wider on the played side.
    var settleSize: Float = 0.25      // Settled-particle size multiplier: 1 + settleSize * tt, where tt progresses
    // from zero on the unplayed side to one on the played side.
    var gain: Float = 0.8             // Overall brightness gain at rest and during interaction.
    var sizeJitter: Float = 0.6       // Particle size variation around the base size.
    var haze: Float = 0.12            // Sparse haze in regions without thumbnail coverage.
    // Percentile-clipped bitrate range controls density modulation strength.
    var flatLo: Float = 1.25, flatHi: Float = 3.0
    var edrRef: Float = 4.0           // Upper bound on display headroom above SDR used by the particle effect.
    var layerH: Float = 64            // Layer height in points, including space for particles and halos.
    // Thumbnail saturation is normalized within the media before color mapping.
    var colorSatMin: Float = 0.37, colorSatMax: Float = 0.95   // Bounds of the normalized thumbnail saturation range.
    var colorBlurPt: Float = 8        // Minimum color-kernel width, in points. Gaussian sigma is at least
                                      // half this width or half a scan bucket.
    var playedWhite: Float = 0.20     // Neutral-white mixture on the played side.
    var playedChroma: Float = 1.45    // Chroma gain on the played side.
    var colorEaseS: Float = 0.35      // Exponential color time constant in seconds; zero applies changes immediately.
    var colorBloomS: Float = 0.8      // New-sample color bloom duration in seconds; zero disables the bloom.

    static func fromEnvironment() -> SPDustTuning {
        var t = SPDustTuning()
#if !SP_APP_STORE
        guard let raw = ProcessInfo.processInfo.environment["SP_DUST_TUNE"] else { return t }
        for pair in raw.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, let v = Float(kv[1].trimmingCharacters(in: .whitespaces)) else { continue }
            switch kv[0].trimmingCharacters(in: .whitespaces) {
            case "grainsPerPt": t.grainsPerPt = v
            case "spread": t.spread = v
            case "zone": t.zone = v
            case "sizePt": t.sizePt = v
            case "restA": t.restA = v
            case "lift": t.lift = v
            case "peak": t.peak = v
            case "glowTau": t.glowTau = v
            case "glowTail": t.glowTail = v
            case "glowTailR": t.glowTailR = v
            case "hlG": t.hlG = v
            case "glowOver": t.glowOver = v
            case "unplayedGain": t.unplayedGain = v
            case "playedGain": t.playedGain = v
            case "swell": t.swell = v
            case "whitenK": t.whitenK = v
            case "whitenMax": t.whitenMax = v
            case "haloR": t.haloR = v
            case "haloA": t.haloA = v
            case "emberP": t.emberP = v
            case "emberBase": t.emberBase = v
            case "emberK": t.emberK = v
            case "unify": t.unify = v
            case "crest": t.crest = v
            case "settleA": t.settleA = v
            case "pressPk": t.pressPk = v
            case "aMin": t.aMin = v
            case "aMax": t.aMax = v
            case "haze": t.haze = v
            case "flatLo": t.flatLo = v
            case "flatHi": t.flatHi = v
            case "edrRef": t.edrRef = v
            case "layerH": t.layerH = v
            case "railFrac": t.railFrac = v
            case "railHalf": t.railHalf = v
            case "railA": t.railA = v
            case "settleHalf": t.settleHalf = v
            case "gain": t.gain = v
            case "colorSatMin": t.colorSatMin = v
            case "colorSatMax": t.colorSatMax = v
            case "playedWhite": t.playedWhite = v
            case "playedChroma": t.playedChroma = v
            case "colorBlurPt": t.colorBlurPt = v
            case "colorEaseS": t.colorEaseS = v
            case "colorBloomS": t.colorBloomS = v
            case "fogSize": t.fogSize = v
            case "spreadBias": t.spreadBias = v
            case "settleSize": t.settleSize = v
            case "sizeJitter": t.sizeJitter = v
            default: break
            }
        }
#endif
        return t
    }
}

// MARK: - Snapshot-to-screen resampling
struct SPDustBins {
    var count: Int
    var alive: [Float]        // Unplayed-particle survival after coverage and density modulation.
    var bright: [Float]       // Normalized bitrate brightness weight; unknown regions use 0.5.
    var color: [SIMD3<Float>] // Linear sRGB.
    var coveredBins: Int
    var dynRange: Float
    var depth: Float
    var settling: Bool = false   // Samples are still blooming, so the host must rebuild next frame.
}

enum SPDustModel {
    static let neutral = SIMD3<Float>(1.0, 0.94, 0.86)

    /// ageOf(keyUs) returns sample age in seconds; infinity means fully established.
    static func build(snapshot: SPThumbDustSnapshot?, durationUs: Int64, bins B: Int, tuning t: SPDustTuning,
                      ageOf: (Int64) -> Float = { _ in .infinity }) -> SPDustBins {
        var out = SPDustBins(count: B, alive: Array(repeating: t.haze, count: B),
                             bright: Array(repeating: 0.5, count: B),
                             color: Array(repeating: neutral, count: B),
                             coveredBins: 0, dynRange: 1, depth: 0)
        guard let snapshot, B > 0, durationUs > 0 else { return out }
        let binUs = Double(durationUs) / Double(B)

        // Weight each adjacent-keyframe bitrate by its overlap with the screen bucket.
        var rate = [Float](repeating: 0, count: B)
        var weight = [Float](repeating: 0, count: B)
        snapshot.keys.withUnsafeBytes { raw in
            let keys = raw.bindMemory(to: SPDustKey.self)
            guard keys.count >= 2 else { return }
            for i in 0..<(keys.count - 1) {
                let a = Double(keys[i].tsUs), b = Double(keys[i + 1].tsUs)
                let db = Double(keys[i + 1].pos - keys[i].pos)
                guard b > a, db > 0 else { continue }
                let r = Float(db / (b - a))
                var bin = max(0, Int(a / binUs))
                let last = min(B - 1, Int(b / binUs))
                while bin <= last {
                    let lo = max(a, Double(bin) * binUs), hi = min(b, Double(bin + 1) * binUs)
                    let ov = Float(max(0, hi - lo))
                    if ov > 0 { rate[bin] += r * ov; weight[bin] += ov }
                    bin += 1
                }
            }
        }
        var haveRate = false
        var samples: [Float] = []
        samples.reserveCapacity(B)
        for i in 0..<B where weight[i] > 0 {
            rate[i] /= weight[i]
            samples.append(rate[i])
            haveRate = true
        }
        // Normalize with percentile clipping and adapt modulation to bitrate range.
        var lo: Float = 0, hi: Float = 1, depth: Float = 0, dyn: Float = 1
        if haveRate, samples.count >= 8 {
            samples.sort()
            lo = samples[Int(Float(samples.count - 1) * 0.05)]
            hi = samples[Int(Float(samples.count - 1) * 0.95)]
            if lo > 0, hi > lo {
                dyn = hi / lo
                let u = min(1, max(0, (dyn - t.flatLo) / max(0.001, t.flatHi - t.flatLo)))
                depth = u * u * (3 - 2 * u)
            }
        }
        out.dynRange = dyn
        out.depth = depth

        // Extend verified coverage by half a scan bucket at each end.
        let pad = snapshot.sweepSpacingUs > 0 ? Double(snapshot.sweepSpacingUs) / 2 : 2_500_000
        var covered = [Bool](repeating: false, count: B)
        // Blend thumbnail colors with distance-weighted Gaussian kernels. New samples
        // influence nearby buckets smoothly rather than repainting whole intervals.
        // Colorless samples extend coverage only. During bloom, sample color,
        // weight and kernel width gradually approach their established values.
        struct Sample { var pos: Double; var rgb: SIMD3<Float>; var sigma: Double; var amp: Float }
        var points: [Sample] = []
        var settling = false
        let sigma0 = max(pad, Double(t.colorBlurPt) / 2 / Double(W_hint(B: B, durationUs: durationUs)) * binUs)
        snapshot.covers.withUnsafeBytes { raw in
            let covers = raw.bindMemory(to: SPDustCover.self)
            // Stretch saturation within the media; use fixed mapping until enough samples
            // exist to keep early percentile estimates from shifting every frame.
            var sats: [Float] = []
            for c in covers where c.valid > 0.5 && c.sat >= 0.06 { sats.append(c.sat) }
            sats.sort()
            var sLo: Float = 0.08, sHi: Float = 0.5
            if sats.count >= 12 {
                sLo = sats[Int(Float(sats.count - 1) * 0.10)]
                sHi = max(sLo + 0.02, sats[Int(Float(sats.count - 1) * 0.90)])
            }
            for c in covers {
                let from = Double(c.fromUs) - pad, until = Double(c.untilUs) + pad
                let b0 = max(0, Int(from / binUs)), b1 = min(B - 1, Int(until / binUs))
                if b1 >= b0 { for b in b0...b1 { covered[b] = true } }
                // Keep genuinely monochrome samples neutral instead of adding a minimum saturation.
                guard c.valid > 0.5, c.sat >= 0.06 else { continue }
                let u = min(1, max(0, (c.sat - sLo) / (sHi - sLo)))
                // Choose saturation in encoded sRGB, then linearize for the extended-linear layer.
                let rgb = srgbToLinear(hsv(h: c.hue, s: t.colorSatMin + (t.colorSatMax - t.colorSatMin) * u, v: 1))
                var e: Float = 1
                let age = ageOf(c.keyUs)
                if t.colorBloomS > 0, age < t.colorBloomS {
                    let x = max(0, age / t.colorBloomS)
                    e = x * x * (3 - 2 * x)
                    settling = true
                }
                // Blend new sample color from neutral as well as increasing its kernel weight.
                let bloomRGB = neutral + (rgb - neutral) * e
                points.append(Sample(pos: (Double(c.fromUs) + Double(c.untilUs)) / 2, rgb: bloomRGB,
                                      sigma: sigma0 * Double(0.25 + 0.75 * e), amp: max(e, 0.05)))
            }
        }
        // A weak neutral prior keeps distant, unsampled buckets from inheriting remote colors.
        let prior: Float = 0.02
        var acc = [SIMD3<Float>](repeating: neutral * prior, count: B)
        var wsum = [Float](repeating: prior, count: B)
        for smp in points where smp.amp > 0 {
            let reach = 3 * smp.sigma
            let b0 = max(0, Int((smp.pos - reach) / binUs)), b1 = min(B - 1, Int((smp.pos + reach) / binUs))
            guard b1 >= b0 else { continue }
            let inv = 1 / Float(smp.sigma)
            for b in b0...b1 {
                let d = Float((Double(b) + 0.5) * binUs - smp.pos) * inv
                let w = smp.amp * expf(-d * d)
                acc[b] += smp.rgb * w
                wsum[b] += w
            }
        }
        // Preserve the natural dimming of mixed hues; peak normalization would whiten transitions.
        for b in 0..<B where covered[b] { out.color[b] = acc[b] / wsum[b] }
        out.settling = settling
        var n = 0
        for b in 0..<B {
            guard covered[b] else { continue }
            n += 1
            var rank: Float = 0.5
            if haveRate, weight[b] > 0, hi > lo {
                rank = min(1, max(0, (rate[b] - lo) / (hi - lo)))
            }
            out.bright[b] = rank
            out.alive[b] = t.aMin + (t.aMax - t.aMin) * (0.5 + depth * (rank - 0.5))
        }
        out.coveredBins = n
        return out
    }

    /// Keep the screen-resampling convention of approximately two points per bucket.
    static func W_hint(B: Int, durationUs: Int64) -> Float { 2 }

    /// Exact piecewise conversion from encoded sRGB to linear light.
    static func srgbToLinear(_ c: SIMD3<Float>) -> SIMD3<Float> {
        func f(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : powf((x + 0.055) / 1.055, 2.4) }
        return SIMD3(f(c.x), f(c.y), f(c.z))
    }

    static func hsv(h: Float, s: Float, v: Float) -> SIMD3<Float> {
        let i = Int(h * 6) % 6
        let f = h * 6 - Float(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), u = v * (1 - (1 - f) * s)
        switch i {
        case 0: return SIMD3(v, u, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, u)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(u, p, v)
        default: return SIMD3(v, p, q)
        }
    }
}

// MARK: - Tween
private struct SPDustTween {
    var value: Float
    private var from: Float, to: Float, dur: Float = 0, t: Float = 0
    var done: Bool { t >= dur }
    init(_ v: Float) { value = v; from = v; to = v }
    mutating func go(_ target: Float, _ d: Float) { from = value; to = target; dur = max(0.001, d); t = 0 }
    mutating func set(_ v: Float) { value = v; from = v; to = v; t = dur }
    mutating func step(_ dt: Float) {
        guard !done else { return }
        t = min(dur, t + dt)
        let u = t / dur
        let e = 1 - (1 - u) * (1 - u) * (1 - u) // outCubic
        value = from + (to - from) * e
    }
}

// GPU particle layout matches the shader's 32-byte G structure.
private struct SPDustGrain {
    var pos: SIMD2<Float>
    var size: Float
    var lum: Float
    var col: SIMD4<Float>
}

private let spDustShader = """
#include <metal_stdlib>
using namespace metal;
// col.w = 指针剖面 g（0..1，已乘出生度）：驱动连续混白与光晕幅度
struct G { float2 pos; float size; float lum; float4 col; };
struct VOut { float4 pos [[position]]; float size [[point_size]]; float4 col; float lum; float halo; float white; };
// u = (W, H, scale, haloPass)；h = (haloR pt, 光晕归一幅度, whitenK, whitenMax)
vertex VOut dust_v(uint vid [[vertex_id]], const device G* g [[buffer(0)]], constant float4& u [[buffer(1)]],
                   constant float4& h [[buffer(2)]]) {
  G p = g[vid]; VOut o;
  o.pos = float4(p.pos.x / u.x * 2.0 - 1.0, 1.0 - p.pos.y / u.y * 2.0, 0.0, 1.0);
  float glow = p.col.w;
  bool halo = u.w > 0.5;
  float px = p.size * u.z;
  float lum = p.lum;
  if (halo) {
    // 光晕：固定小半径，幅度 ∝ g²（只有尖峰核心发光），远端颗粒直接顶出裁剪
    px = glow > 0.02 ? h.x * 2.0 * u.z : 0.0;
    if (px <= 0.0) o.pos = float4(2.0, 2.0, 0.0, 1.0);
  } else {
    // 次像素颗粒：点精灵最小 1px，用覆盖率折亮度，复现 fillRect(0.5px) 的观感
    if (px < 1.0) { lum *= px * px; px = 1.0; }
  }
  o.size = px;
  o.col = p.col;
  o.lum = lum;
  o.halo = halo ? h.y * glow * glow : -1.0;
  o.white = min(h.w, h.z * glow);
  return o;
}
fragment float4 dust_f(VOut in [[stage_in]], float2 pc [[point_coord]]) {
  float2 d = pc - 0.5; float r2 = dot(d, d) * 4.0;
  if (in.halo >= 0.0) {
    float a = exp(-r2 * 2.5) * in.halo;
    float3 c = mix(in.col.rgb, float3(1.0), 0.55);
    return float4(c * a, a);
  }
  if (r2 > 1.0) discard_fragment();
  // 混白随剖面连续（旧版 lum>1 才一刀切混 55%，窗边界处彩→白硬跳）
  float3 c = mix(in.col.rgb, float3(1.0), in.white);
  return float4(c * in.lum, min(1.0, in.lum));
}
"""

// Timeline styles are stored globally in UserDefaults. Star Trail uses the
// particle layer; Tide uses a pointer-following raised rail; Classic remains
// flat. Preserve stored raw values when changing user-facing labels.
enum SPTimelineStyleSettings {
    enum Style: String { case starTrail, tide, classic }
    static let key = "sp.timeline.style"
    static let changed = Notification.Name("sp.timelineStyleChanged")
    static var style: Style {
        get { Style(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .starTrail }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}

// CADisplayLink retains its target. A weak proxy avoids retaining the host,
// GPU resources and layer after the view closes or changes style.
@MainActor
private final class SPDustLinkProxy: NSObject {
    weak var host: SPDustHost?
    @objc func tick(_ l: CADisplayLink) {
        if let host { host.tick(l) } else { l.invalidate() }
    }
}

// MARK: - Layer host and event-driven animation
@MainActor
final class SPDustHost: NSObject {
    /// Non-store builds may override the selected timeline style for diagnostics.
    static var enabled: Bool {
#if SP_APP_STORE
        return SPTimelineStyleSettings.style == .starTrail
#else
        switch ProcessInfo.processInfo.environment["SP_UI_DUST"] {
        case "1": return true
        case "0": return false
        default: return SPTimelineStyleSettings.style == .starTrail
        }
#endif
    }

    let layer = CAMetalLayer()
    private let tuning = SPDustTuning.fromEnvironment()
    private weak var view: NSView?

    // Metal
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pso: MTLRenderPipelineState?      // Particles use maximum blending to preserve color in dense regions.
    private var haloPSO: MTLRenderPipelineState?  // Halos use additive blending.
    private var buffers: [MTLBuffer] = []
    private var bufferIndex = 0

    // Geometry.
    private var W: Float = 0
    private var H: Float = 0
    private var scale: CGFloat = 2
    private var viewBounds = CGRect.zero

    // Particle state in structure-of-arrays form.
    private var n = 0
    private var home: [Float] = [], side: [Float] = [], rest: [Float] = []
    private var j2: [Float] = [], j3: [Float] = [], u: [Float] = []
    private var ember: [Bool] = []
    private var rail: [Bool] = []
    private var xs: [Float] = [], ys: [Float] = [], born: [Float] = []
    private var grains: [SPDustGrain] = []
    private var firstFrame = true

    // Resident torrent ranges are independent of thumbnail coverage. Classify
    // each grain at its exact media coordinate, rather than rounding to the
    // two-point thumbnail bins (which could paint across an uncached gap).
    private var bufferedRanges: [ClosedRange<Double>] = []
    private var showsBufferedRanges = false
    private var bufferedParticles: [Bool] = []

    // Interaction state.
    private var split: Float = 0
    private var px: Float = -10_000
    private var hovering = false
    private var open = SPDustTween(0)
    private var press = SPDustTween(0)
    private var rebound = 0
    private var edrAvail: Float = 0   // Current usable overrange of the display (cur - 1, capped at edrRef).

    // Snapshot data.
    private var bins: SPDustBins?
    private var snapshotGen: UInt64 = .max
    private var durationUs: Int64 = 0
    private var colorCur: [SIMD3<Float>] = []              // Current particle colors ease toward the resampled bucket colors.
    private var sampleBorn: [Int64: CFTimeInterval] = [:]  // First-seen timestamps determine sample bloom age.
    private var seenSnapshot = false

    // Redraw scheduling. Swift 6 deinit is nonisolated, but this state is accessed
    // only on the main thread, including main-thread view destruction.
    nonisolated(unsafe) private var link: CADisplayLink?
    private var dirty = false
    private var visible = true
    private var lastTs: CFTimeInterval = 0
    private var frames = 0
    private let debug = ProcessInfo.processInfo.environment["SP_DEBUG"] != nil

    override init() {
        super.init()
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.presentsWithTransaction = false
        layer.maximumDrawableCount = 3
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.wantsExtendedDynamicRangeContent = false // EDR is active only during hover.
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                         "hidden": NSNull(), "opacity": NSNull()]
        // Build render pipelines in the background; earlier events only mark state dirty.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let dev = MTLCreateSystemDefaultDevice() else { return }
            do {
                let lib = try dev.makeLibrary(source: spDustShader, options: nil)
                func make(_ op: MTLBlendOperation) throws -> MTLRenderPipelineState {
                    let d = MTLRenderPipelineDescriptor()
                    d.vertexFunction = lib.makeFunction(name: "dust_v")
                    d.fragmentFunction = lib.makeFunction(name: "dust_f")
                    let ca = d.colorAttachments[0]!
                    ca.pixelFormat = .rgba16Float
                    ca.isBlendingEnabled = true
                    ca.rgbBlendOperation = op
                    ca.alphaBlendOperation = op
                    ca.sourceRGBBlendFactor = .one
                    ca.destinationRGBBlendFactor = .one
                    ca.sourceAlphaBlendFactor = .one
                    ca.destinationAlphaBlendFactor = .one
                    return try dev.makeRenderPipelineState(descriptor: d)
                }
                // Maximum blending preserves particle color where several grains overlap.
                // Halos remain additive so their light accumulates.
                let p = try make(.max)
                let ph = try make(.add)
                let q = dev.makeCommandQueue()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.device = dev
                    self.queue = q
                    self.pso = p
                    self.haloPSO = ph
                    self.layer.device = dev
                    self.allocBuffers()
                    self.kick()
                }
            } catch {
                NSLog("[Dust] shader/PSO 失败: \(error)")
            }
        }
    }

    func attach(to view: NSView) { self.view = view }
    /// Detach immediately when changing style or destroying the view. The weak
    /// target prevents leaks, but explicit invalidation removes the paused link promptly.
    func detach() {
        link?.invalidate(); link = nil
        view = nil
    }
    deinit {
        // The display link owns only a weak proxy. Invalidate here as a final teardown guard.
        link?.invalidate()
        if debug { NSLog("[Dust] 宿主释放") }
    }

    // MARK: Inputs

    func setGeometry(bounds: CGRect, scale s: CGFloat) {
        guard bounds.width > 0 else { return }
        if bounds == viewBounds && s == scale && n > 0 { return }
        viewBounds = bounds
        scale = s
        W = Float(bounds.width)
        H = tuning.layerH
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = s
        layer.frame = CGRect(x: 0, y: (bounds.height - CGFloat(H)) / 2, width: bounds.width, height: CGFloat(H))
        layer.drawableSize = CGSize(width: CGFloat(W) * s, height: CGFloat(H) * s)
        CATransaction.commit()
        regenerateGrains()
        rebuildBins()
        kick()
    }

    func setSnapshot(_ snap: SPThumbDustSnapshot?, duration: Double) {
        let gen = snap?.generation ?? 0
        let dur = Int64(duration * 1e6)
        if gen == snapshotGen && dur == durationUs { return }
        snapshotGen = gen
        durationUs = dur
        pendingSnapshot = snap
        noteSamples(snap)
        rebuildBins()
        kick()
    }
    private var pendingSnapshot: SPThumbDustSnapshot?

    func setBufferedRanges(_ ranges: [ClosedRange<Double>], visible: Bool) {
        let normalized = visible ? SPBufferedTimeline.normalized(ranges) : []
        guard bufferedRanges != normalized || showsBufferedRanges != visible else { return }
        bufferedRanges = normalized
        showsBufferedRanges = visible
        rebuildBufferedParticles()
        kick()
    }

    private func rebuildBufferedParticles() {
        guard showsBufferedRanges, W > 0, !home.isEmpty else {
            bufferedParticles = []
            return
        }
        var next = 0
        bufferedParticles = home.map { x in
            let fraction = Double(x) / Double(W)
            while next < bufferedRanges.count && bufferedRanges[next].upperBound <= fraction { next += 1 }
            return next < bufferedRanges.count && bufferedRanges[next].lowerBound <= fraction
        }
    }
    // Resilient playback damage bands (bucket-level channel): 0 fluent, 1 partial, 2 none, 3 not downloaded yet; healthy files pass an empty array at zero cost.
    private var damageBands: [SPDamageBand] = []
    private var damageBins: [UInt8] = []
    func setDamage(bands: [SPDamageBand], duration: Double) {
        damageBands = bands
        if duration > 0 { durationUs = Int64(duration * 1e6) }
        rebuildDamageBins()
        kick()
    }
    private func rebuildDamageBins() {
        guard let bins, !damageBands.isEmpty, durationUs > 0 else { damageBins = []; return }
        let B = bins.count
        var out = [UInt8](repeating: 0, count: B)
        let dur = Double(durationUs) / 1e6
        for b in damageBands {
            let b0 = max(0, min(B - 1, Int(b.from / dur * Double(B))))
            let b1 = max(0, min(B - 1, Int((b.until / dur * Double(B)).rounded(.up)) - 1))
            if b1 >= b0 { for i in b0...b1 { out[i] = max(out[i], UInt8(clamping: b.cls)) } }
        }
        damageBins = out
    }

    /// Track when each sample key appears. Treat the initial snapshot as established
    /// so style changes do not replay every bloom; discard timestamps for evicted keys.
    private func noteSamples(_ snap: SPThumbDustSnapshot?) {
        let now = CACurrentMediaTime()
        var live = Set<Int64>()
        snap?.covers.withUnsafeBytes { raw in
            for c in raw.bindMemory(to: SPDustCover.self) {
                live.insert(c.keyUs)
                if sampleBorn[c.keyUs] == nil { sampleBorn[c.keyUs] = seenSnapshot ? now : -1e9 }
            }
        }
        seenSnapshot = true
        if sampleBorn.count != live.count { sampleBorn = sampleBorn.filter { live.contains($0.key) } }
    }

    func setSplit(_ x: CGFloat) {
        let v = Float(x)
        if abs(v - split) < 0.25 && !firstFrame { return }
        split = v
        kick()
    }

    func pointerEntered(x: CGFloat) {
        hovering = true
        px = Float(x)
        open.go(1, 0.24)
        layer.wantsExtendedDynamicRangeContent = true
        kick()
    }
    func pointerMoved(x: CGFloat) {
        px = Float(x)
        if !hovering { hovering = true; open.go(1, 0.24); layer.wantsExtendedDynamicRangeContent = true }
        kick()
    }
    func pointerExited() {
        hovering = false
        open.go(0, 0.28)
        press.set(0)
        rebound = 0
        kick()
    }
    func pressed(x: CGFloat) {
        px = Float(x)
        press.go(reduceMotion ? 0 : 1, 0.12)
        rebound = 0
        kick()
    }
    func released(hovering stillHovering: Bool) {
        if stillHovering && !reduceMotion { press.go(-0.20, 0.14); rebound = 1 }
        else { press.go(0, 0.18) }
        if !stillHovering && hovering { pointerExited() } else { kick() }
    }
    func setVisible(_ v: Bool) {
        visible = v
        if v { kick() } else { link?.isPaused = true }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Particle and snapshot data

    private func regenerateGrains() {
        n = max(0, Int(tuning.grainsPerPt * W))
        var seed: UInt32 = 0x9E3779B9 ^ UInt32(truncatingIfNeeded: Int(W))
        func rnd() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 8) / Float(1 << 24) }
        home = []; side = []; rest = []; j2 = []; j3 = []; u = []; ember = []; rail = []
        home.reserveCapacity(n); side.reserveCapacity(n); rest.reserveCapacity(n)
        j2.reserveCapacity(n); j3.reserveCapacity(n); u.reserveCapacity(n); ember.reserveCapacity(n)
        rail.reserveCapacity(n)
        let rf = min(0.9, max(0, tuning.railFrac))
        for i in 0..<n {
            home.append((Float(i) + rnd()) / Float(max(1, n)) * W)   // Stratified placement gives continuous timeline coverage.
            side.append(rnd() < 0.5 ? -1 : 1)
            let jj = rnd()
            j2.append(jj)
            j3.append(rnd())
            u.append(rnd())
            let isRail = jj < rf
            rail.append(isRail)
            ember.append(!isRail && rnd() < tuning.emberP)
            if isRail {
                rest.append(tuning.railHalf * (jj / max(0.001, rf)))
            } else {
                let q = (jj - rf) / max(0.001, 1 - rf)
                rest.append(tuning.spread * (0.06 + 0.94 * powf(q, tuning.spreadBias)))
            }
        }
        xs = Array(repeating: 0, count: n)
        ys = Array(repeating: H / 2, count: n)
        born = Array(repeating: 0, count: n)
        grains = Array(repeating: SPDustGrain(pos: .zero, size: 0, lum: 0, col: SIMD4(1, 1, 1, 0)), count: n)
        firstFrame = true
        rebuildBufferedParticles()
        allocBuffers()
    }

    private func allocBuffers() {
        guard let dev = device, n > 0 else { buffers = []; return }
        let bytes = MemoryLayout<SPDustGrain>.stride * n
        if let first = buffers.first, first.length >= bytes { return }
        buffers = (0..<3).compactMap { _ in dev.makeBuffer(length: bytes, options: .storageModeShared) }
        bufferIndex = 0
    }

    /// quiet suppresses diagnostics during per-frame bloom rebuilds.
    private func rebuildBins(quiet: Bool = false) {
        guard W > 0 else { return }
        let B = max(8, Int(W / 2))
        let now = CACurrentMediaTime()
        let born = sampleBorn
        let rm = reduceMotion
        bins = SPDustModel.build(snapshot: pendingSnapshot, durationUs: durationUs, bins: B, tuning: tuning,
                                 ageOf: { k in rm ? .infinity : (born[k].map { Float(now - $0) } ?? .infinity) })
        if !damageBands.isEmpty { rebuildDamageBins() }
        // Initialize colors to neutral; on resize, resample existing colors without resetting them.
        if colorCur.count != B {
            if colorCur.isEmpty {
                colorCur = Array(repeating: SPDustModel.neutral, count: B)
            } else {
                let old = colorCur
                colorCur = (0..<B).map { old[min(old.count - 1, $0 * old.count / B)] }
            }
        }
        if debug, !quiet, let b = bins {
            NSLog("[Dust] 桶 %d 覆盖 %d 动态范围 %.1f× 深度 %.2f 关键帧 %lu 覆盖区间 %lu",
                  B, b.coveredBins, b.dynRange, b.depth,
                  (pendingSnapshot?.keys.count ?? 0) / MemoryLayout<SPDustKey>.stride,
                  (pendingSnapshot?.covers.count ?? 0) / MemoryLayout<SPDustCover>.stride)
        }
    }

    // MARK: Redraw scheduling

    private func kick() {
        dirty = true
        guard visible, pso != nil, n > 0, let view else { return }
        if link == nil {
            let proxy = SPDustLinkProxy(); proxy.host = self
            let l = view.displayLink(target: proxy, selector: #selector(SPDustLinkProxy.tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        if link?.isPaused == true { lastTs = 0; link?.isPaused = false }
    }

    fileprivate func tick(_ l: CADisplayLink) {
        guard visible, !(view?.isHiddenOrHasHiddenAncestor ?? true) else { l.isPaused = true; return }
        let dt: Float = lastTs > 0 ? Float(min(0.05, l.targetTimestamp - lastTs)) : 1 / 60
        lastTs = l.targetTimestamp
        let converged = step(dt: dt)
        draw()
        dirty = false
        if converged { l.isPaused = true; lastTs = 0 }
    }

    /// Advance animation and return true when no further visible change remains.
    private func step(dt: Float) -> Bool {
        guard n > 0 else { return true }
        if bins?.settling == true { rebuildBins(quiet: true) }   // Rebuild target colors as sample bloom ages advance.
        guard let bins else { return true }
        open.step(dt); press.step(dt)
        if rebound == 1 && press.done { press.go(0, 0.16); rebound = 0 }
        let t = tuning
        let cy = H / 2
        let O = open.value
        let pk = O * (0.66 + t.pressPk * press.value)
        let B = bins.count
        let binScale = Float(B) / max(1, W)
        // Read display headroom during hover; non-EDR displays contribute no excess range.
        if hovering, let scr = view?.window?.screen {
            let cur = Float(scr.maximumExtendedDynamicRangeColorComponentValue)
            let avail = min(t.edrRef, max(0, cur - 1))
            if debug, abs(avail - edrAvail) > 0.05 {
                NSLog("[Dust] 屏 EDR 余量 %.2f（潜在 %.2f）→ 过范围可用 %.2f", cur,
                      Float(scr.maximumPotentialExtendedDynamicRangeColorComponentValue), avail)
            }
            edrAvail = avail
        }
        let rm = reduceMotion
        var maxMove: Float = 0
        var bornDelta: Float = 0
        // Profile constants normalized so g(0)=pk; beyond glowReach (afterglow under 1%) the value is 0, saving two expf calls.
        let glowNorm = 1 / (1 + t.glowTail)
        let tailInv2 = 1 / max(0.01, t.glowTailR * t.glowTailR)
        let glowReach = max(t.glowTau * 6, t.glowTailR * 2.2)
        // Ease colors exponentially rather than switching abruptly when snapshots change.
        // Newly covered regions follow the same transition from neutral.
        var colorDelta: Float = 0
        if colorCur.count == B {
            let ke: Float = (rm || tuning.colorEaseS <= 0) ? 1 : 1 - expf(-dt / tuning.colorEaseS)
            for b in 0..<B {
                let d = bins.color[b] - colorCur[b]
                colorDelta = max(colorDelta, max(abs(d.x), max(abs(d.y), abs(d.z))))
                colorCur[b] += d * ke
            }
        } else {
            colorCur = bins.color
        }

        for i in 0..<n {
            let hx = home[i]
            let bi = min(B - 1, max(0, Int(hx * binScale)))
            let cached = bufferedParticles.isEmpty ? false : bufferedParticles[i]
            let cacheAhead = showsBufferedRanges && hx > split
            var dv = bins.alive[bi]
            // Cached grains remain readable before preview thumbnails arrive.
            // Uncached grains keep the sparse guide instead of borrowing the
            // thumbnail scanner's coverage as proof that video is resident.
            if cacheAhead { dv = cached ? max(dv, 0.82) : min(dv, 0.16) }
            let br = bins.bright[bi]
            // Reduce unplayed non-rail survival for unavailable and pending regions.
            // The guide rail stays present. Later color mapping uses amber for partial
            // content, red for unavailable content, and neutral gray for pending data.
            let dmg: UInt8 = damageBins.isEmpty ? 0 : damageBins[bi]
            if dmg == 2 { dv *= 0.12 } else if dmg == 3 { dv *= 0.3 }
            let tt = min(1, max(0, (split - hx) / t.zone + 0.5))
            let isRail = rail[i]
            let aliveP = isRail ? 1 : dv * (1 - tt) + tt   // The central guide rail remains present.
            let bt: Float = u[i] <= aliveP ? 1 : 0
            if firstFrame { born[i] = bt }
            var bn = born[i]
            if bt == 0 && bn < 0.012 {
                born[i] = 0
                grains[i].lum = 0
                grains[i].col.w = 0   // Halo amplitude is cleared as well; otherwise dead grains would pile ghost halos at their old position.
                continue
            }
            let bn0 = bn
            let lamB: Float = rm ? 60 : (bt > 0 ? 19 : 9)
            bn += (bt - bn) * (1 - expf(-lamB * dt))
            born[i] = bn
            bornDelta = max(bornDelta, abs(bt - bn))

            // Pointer profile g in [0, pk]: exponential spike plus faint afterglow; shared by both sides and drives geometry, brightness, overrange, whitening and halo.
            let dE = abs(hx - px)
            let gs: Float = dE > glowReach ? 0   // Shape 0..1 (independent of expansion or pressing).
                : (expf(-dE / t.glowTau) + t.glowTail * expf(-(dE * dE) * tailInv2)) * glowNorm
            let g = pk * gs
            let c = g * t.hlG

            let crest = expf(-((hx - split) / 9) * ((hx - split) / 9))
            var ty = cy + side[i] * (rest[i] * (1 - tt) * (1 - 0.94 * c)
                                     + (t.settleHalf * (1 + t.swell * gs * O) * (j3[i] - 0.5) * 2 + t.crest * crest) * tt)
            let tx = hx + (px - hx) * c * 0.16
            let jit = isRail ? 1 : (1 - t.sizeJitter / 2 + t.sizeJitter * j3[i]) * (1 + (t.fogSize - 1) * (1 - tt))
            let sz = t.sizePt * (isRail ? 1.2 : jit) * (1 + t.settleSize * tt)
            let aMul = 1 + t.settleA * tt + 1.2 * crest * tt

            ty = cy + (ty - cy) * bn
            if firstFrame || bn0 < 0.02 { xs[i] = tx; ys[i] = ty }
            maxMove = max(maxMove, max(abs(tx - xs[i]), abs(ty - ys[i])))
            let lam: Float = rm ? 70 : (13 + 24 * j2[i])
            let k = 1 - expf(-lam * dt)
            xs[i] += (tx - xs[i]) * k
            ys[i] += (ty - ys[i]) * k
            let x = xs[i], y = ys[i]

            let dy = abs(y - cy)
            let prof = 1 - 0.42 * min(1, dy / t.spread)
            var L = (isRail ? t.railA : t.restA * (0.42 + 0.58 * br)) * prof * aMul * bn
            L *= 1 + t.lift * O
            L *= 1 + t.peak * c
            L *= 1 + t.unify * c * (1 - tt)   // The unplayed-side boost multiplies the profile (the old additive form pushed the pointer past 1 and flattened it).
            if ember[i] { L *= t.emberBase + (t.emberK - t.emberBase) * g }
            L *= t.gain
            // SDR stays clamped at or below 1 (with max blending 1.0 is full color; a lift must never push the played line past 1, or channel clamping turns it white).
            // Overrange is driven only by the profile and decays with g: no hard window, no flat top; at rest (O=0, g=0) everything stays at or below 1 with no halo.
            L *= t.unplayedGain * (1 - tt) + t.playedGain * tt
            // Played-side SDR cap keeps headroom: resting and hovered-outside stay at or below playedGain, inside the profile rises to 1.0 (shape = the profile itself).
            let cap = 1 - (1 - t.playedGain) * tt * (1 - gs * O)
            let Ls = min(cap, L)
            let over: Float = edrAvail * tanhf(t.glowOver * g)
            L = Ls + over * bn

            var col = colorCur[bi]
            let wmix = t.playedWhite * tt
            col = col * (1 - wmix) + SIMD3<Float>(repeating: 1) * wmix
            if tt > 0 {   // Adjust played-side chroma around constant luminance.
                let Y = 0.2126 * col.x + 0.7152 * col.y + 0.0722 * col.z
                let k = 1 + (t.playedChroma - 1) * tt
                col = SIMD3(max(0, Y + (col.x - Y) * k), max(0, Y + (col.y - Y) * k), max(0, Y + (col.z - Y) * k))
                // Chroma gain may exceed one. Normalize by the largest channel to preserve
                // hue and keep resting particles within the layer's SDR range.
                let m = max(col.x, max(col.y, col.z))
                if m > 1 { col /= m }
            }
            if cacheAhead {
                col = SIMD3(repeating: 1)
                if cached {
                    // A denser, light-neutral cloud marks resident media. Keep
                    // every mark a particle, including while hovering/dragging.
                    L = max(L, (isRail ? 0.58 : 0.30) * bn)
                } else {
                    L *= 0.24
                }
            }
            if dmg == 1 {
                col = col * 0.45 + SIMD3<Float>(1.0, 0.62, 0.18) * 0.55
            } else if dmg == 2 {
                col = col * 0.35 + SIMD3<Float>(1.0, 0.30, 0.26) * 0.65
                L *= 0.7
            } else if dmg == 3 {
                let Y = (col.x + col.y + col.z) / 3
                col = SIMD3(repeating: Y * 0.6)
                L *= 0.55
            }
            let w = sz * (ember[i] ? 1.6 : 1) * (1 + 0.22 * c) * (1 + 0.24 * t.unify * c * (1 - tt))
            grains[i] = SPDustGrain(pos: SIMD2(x, y), size: w, lum: L, col: SIMD4(col.x, col.y, col.z, g * bn))
        }
        firstFrame = false
        let tweensDone = open.done && press.done && rebound == 0
        return maxMove < 0.02 && bornDelta < 0.01 && tweensDone && colorDelta < 0.004 && !bins.settling
    }

    private func draw() {
        guard let pso, let haloPSO, let queue, n > 0, !buffers.isEmpty else { return }
        guard layer.drawableSize.width > 0, let drawable = layer.nextDrawable() else { return }
        let buf = buffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % buffers.count
        grains.withUnsafeBytes { raw in
            buf.contents().copyMemory(from: raw.baseAddress!, byteCount: min(raw.count, buf.length))
        }
        guard let cb = queue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pso)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        var uni = SIMD4<Float>(W, H, Float(scale), 0)
        enc.setVertexBytes(&uni, length: 16, index: 1)
        // Halo amplitude is normalized by the grains stacked per pixel: about grainsPerPt * 1.12 * haloR halos overlap under one pixel along the line
        // (integral of exp(-2.5 (dx/R)^2) along x = 1.12R), so the stacked peak is about haloA rather than dozens of 0.55 adding up to white.
        let haloNorm = tuning.haloA / max(1, tuning.grainsPerPt * 1.12 * tuning.haloR)
        var halo = SIMD4<Float>(tuning.haloR, haloNorm, tuning.whitenK, tuning.whitenMax)
        enc.setVertexBytes(&halo, length: 16, index: 2)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: n)
        uni.w = 1
        enc.setRenderPipelineState(haloPSO)
        enc.setVertexBytes(&uni, length: 16, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: n)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
        frames += 1
        if debug && (frames == 1 || frames % 600 == 0) {
            NSLog("[Dust] 帧 %d 颗粒 %d 尺寸 %.0fx%.0f@%.0fx EDR=%d", frames, n, W, H, Float(scale),
                  layer.wantsExtendedDynamicRangeContent ? 1 : 0)
        }
    }
}
