import AppKit
import Metal
import QuartzCore

struct SPDustKey { var tsUs: Int64; var pos: Int64 }
struct SPDustCover {
    var keyUs: Int64; var fromUs: Int64; var untilUs: Int64
    var hue: Float; var sat: Float; var luma: Float; var valid: Float
}
final class SPThumbDustSnapshot {
    let generation: UInt64 = 1
    let keys = Data(), covers = Data()
    let sweepSpacingUs: Int64 = 0
}
struct SPDamageBand {
    let cls: Int32
    let from: Double
    let until: Double
}
// INSERT_NORMALIZATION
// INSERT_DUST

@main @MainActor struct ParticleCacheChecks {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
        print("PASS \(checks): \(message)")
    }
    static func settle(_ host: SPDustHost) {
        for _ in 0..<200 { _ = host.step(dt: 1 / 60) }
    }
    static func level(_ host: SPDustHost, from: Float, until: Float) -> Float {
        let selected = host.home.indices.filter { host.home[$0] / host.W >= from && host.home[$0] / host.W < until }
        return selected.reduce(Float(0)) { $0 + host.grains[$1].lum } / Float(selected.count)
    }
    static func image(_ host: SPDustHost, background: Float = 0) throws -> NSBitmapImageRep {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("A Metal device is required for the actual shader rendering check")
        }
        let library = try device.makeLibrary(source: spDustShader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "dust_v")
        descriptor.fragmentFunction = library.makeFunction(name: "dust_f")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .rgba16Float
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .max
        attachment.alphaBlendOperation = .max
        attachment.sourceRGBBlendFactor = .one; attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one; attachment.destinationAlphaBlendFactor = .one
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        let haloPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let width = Int(host.W) * 2, height = Int(host.H) * 2
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: width, height: height, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: textureDescriptor)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let buffer = host.grains.withUnsafeBytes { raw in device.makeBuffer(bytes: raw.baseAddress!, length: raw.count)! }
        let command = queue.makeCommandBuffer()!, encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var uniform = SIMD4<Float>(host.W, host.H, 2, 0)
        let haloNorm = host.tuning.haloA / max(1, host.tuning.grainsPerPt * 1.12 * host.tuning.haloR)
        var halo = SIMD4<Float>(host.tuning.haloR, haloNorm, host.tuning.whitenK, host.tuning.whitenMax)
        encoder.setVertexBytes(&uniform, length: 16, index: 1)
        encoder.setVertexBytes(&halo, length: 16, index: 2)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: host.n)
        uniform.w = 1
        encoder.setRenderPipelineState(haloPipeline)
        encoder.setVertexBytes(&uniform, length: 16, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: host.n)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        expect(command.status == .completed, "Actual Metal particle shader completes offscreen")
        var half = [UInt16](repeating: 0, count: width * height * 4)
        half.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: width * 8,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        for i in 0..<(width * height) {
            for channel in 0..<3 {
                let alpha = min(1, max(0, Float(Float16(bitPattern: half[i * 4 + 3]))))
                let linear = Float(Float16(bitPattern: half[i * 4 + channel])) + background * (1 - alpha)
                let encoded = linear <= 0.0031308 ? linear * 12.92 : 1.055 * powf(max(0, linear), 1 / 2.4) - 0.055
                image.bitmapData![i * 4 + channel] = UInt8(clamping: Int(min(1, max(0, encoded)) * 255))
            }
            image.bitmapData![i * 4 + 3] = 255
        }
        return image
    }
    static func brightness(_ image: NSBitmapImageRep, from: Double, until: Double) -> Double {
        var sum = 0.0, count = 0
        for x in Int(from * Double(image.pixelsWide))..<Int(until * Double(image.pixelsWide)) {
            for y in (image.pixelsHigh / 2 - 8)..<(image.pixelsHigh / 2 + 8) {
                let color = image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                sum += 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                count += 1
            }
        }
        return sum / Double(count)
    }
    static func blueSeparation(_ image: NSBitmapImageRep, from: Double, until: Double) -> Double {
        var sum = 0.0, count = 0
        for x in Int(from * Double(image.pixelsWide))..<Int(until * Double(image.pixelsWide)) {
            for y in (image.pixelsHigh / 2 - 3)..<(image.pixelsHigh / 2 + 3) {
                let color = image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                sum += color.blueComponent - color.redComponent
                count += 1
            }
        }
        return sum / Double(count)
    }
    static func main() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            print("SKIP: no native Metal device; particle GPU checks were not run.")
            exit(77)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        let beforeGeometry = SPDustHost()
        beforeGeometry.setBufferedRanges([0.3...0.6], visible: true)
        beforeGeometry.setGeometry(bounds: CGRect(x: 0, y: 0, width: 400, height: 44), scale: 2)
        expect(beforeGeometry.bufferedParticles.contains(true),
               "Ranges received before geometry are applied when grains become available")
        let host = SPDustHost()
        host.setGeometry(bounds: CGRect(x: 0, y: 0, width: 900, height: 44), scale: 2)
        host.setSplit(180)
        settle(host)
        let local = host.grains
        expect(host.view == nil && host.link == nil, "Particle checks never attach to a live view or display link")
        host.setBufferedRanges([0.25...0.40, 0.55...0.65, 0.8...0.9], visible: true)
        settle(host)
        expect(host.bins?.coveredBins == 0, "No thumbnail snapshot is required for resident-cache presentation")
        expect(host.bufferedParticles.count == host.n, "Every particle has its own exact resident-range classification")
        expect(host.home.indices.allSatisfy { i in
            let x = Double(host.home[i]) / Double(host.W)
            return host.bufferedParticles[i] == ((0.25..<0.4).contains(x) || (0.55..<0.65).contains(x) || (0.8..<0.9).contains(x))
        }, "Disjoint loaded segments and their gaps match each particle's media coordinate")
        expect(level(host, from: 0.27, until: 0.38) > 4 * level(host, from: 0.43, until: 0.5),
               "Cached particles are clearly brighter than unloaded particles without thumbnails")
        expect(host.home.indices.filter { host.home[$0] < 160 }.allSatisfy { i in
            abs(host.grains[i].lum - local[i].lum) < 0.001 && host.grains[i].col.x == host.grains[i].col.z
        }, "Played particles retain brightness and stay neutral white above cache state")
        let baseline = try image(host)
        let light = try image(host, background: 1)
        expect(blueSeparation(baseline, from: 0.27, until: 0.38) > 0.1 &&
               abs(blueSeparation(baseline, from: 0.04, until: 0.15)) < 0.01,
               "Rendered loaded particles are blue while played particles stay white on dark video")
        expect(blueSeparation(light, from: 0.27, until: 0.38) > 0.03 &&
               abs(blueSeparation(light, from: 0.04, until: 0.15)) < 0.01,
               "Loaded and played states retain separate hues on bright video")
        expect(brightness(baseline, from: 0.27, until: 0.38) > brightness(baseline, from: 0.43, until: 0.5) * 2,
               "Rendered Metal pixels distinguish resident segments from unloaded gaps")
        let stripe = baseline.pixelsHigh / 2 - 2
        let dark = (Int(0.27 * Double(baseline.pixelsWide))..<Int(0.38 * Double(baseline.pixelsWide))).filter {
            baseline.colorAt(x: $0, y: stripe)!.redComponent < 0.03
        }
        expect(!dark.isEmpty, "Even the loaded segment contains spaces between circular grains, not a filled rectangle")
        host.setBufferedRanges([0.55...0.65], visible: true)
        _ = host.step(dt: 1 / 60)
        expect(level(host, from: 0.27, until: 0.38) < 0.15, "Eviction immediately dims its old particles without waiting for a bloom")
        // Place a sub-thumbnail-bin gap around a real particle coordinate.
        let midpoint = Double(host.home[host.n / 2]) / Double(host.W)
        host.setBufferedRanges([0.1...(midpoint - 0.000001), (midpoint + 0.000001)...0.9], visible: true)
        expect(host.bufferedParticles[host.n / 2] == false,
               "A gap smaller than a thumbnail bin is never rounded into cached coverage")
        host.setGeometry(bounds: CGRect(x: 0, y: 0, width: 480, height: 44), scale: 1)
        expect(host.bufferedParticles.count == host.n && host.home.indices.allSatisfy { i in
            let x = Double(host.home[i]) / Double(host.W)
            return host.bufferedParticles[i] == ((0.1..<(midpoint - 0.000001)).contains(x) || ((midpoint + 0.000001)..<0.9).contains(x))
        }, "Resize regenerates exact particle coverage at the new width")
        host.setBufferedRanges([], visible: true); settle(host)
        expect(!host.bufferedParticles.contains(true) && level(host, from: 0.8, until: 0.9) < 0.1,
               "An empty resident cache keeps an honest dim particle guide")
        host.setBufferedRanges([0.2...0.95], visible: true)
        host.pointerEntered(x: 300); settle(host)
        expect(host.grains.contains { $0.col.w > 0 }, "Hover retains the original particle glow profile")
        host.pressed(x: 300); settle(host); host.released(hovering: true); settle(host)
        expect(host.bufferedParticles.contains(true), "Hover, press and release preserve cache classification")
        host.edrAvail = 4
        host.pressed(x: 300); settle(host)
        let hovered = try image(host)
        expect(blueSeparation(hovered, from: 0.60, until: 0.66) > 0.1,
               "Hover and press with HDR headroom cannot wash cached particles into played white")
        host.pointerExited(); host.setSplit(96)
        host.setBufferedRanges([0.2...0.95], visible: false); settle(host)
        let localAfter = SPDustHost()
        localAfter.setGeometry(bounds: CGRect(x: 0, y: 0, width: 480, height: 44), scale: 1)
        localAfter.setSplit(96); settle(localAfter)
        expect(host.bufferedParticles.isEmpty && host.grains.indices.allSatisfy { i in
            abs(host.grains[i].lum - localAfter.grains[i].lum) < 0.001
        }, "Leaving torrent mode restores the original local-media particle brightness")
        if CommandLine.arguments.count == 2 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try baseline.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("particle-cache-metal.png"))
            try light.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("particle-cache-metal-light.png"))
            try hovered.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("particle-cache-metal-hover.png"))
        }
        print("Particle cache checks passed (\(checks) assertions; actual grain generation and offscreen Metal shader).")
    }
}
