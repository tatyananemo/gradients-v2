// Validation executable only. Never included in the application target.
import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let casesURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: casesURL)) as! [[String: Any]]
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fatalError("A real Metal device is required; no software substitute is accepted")
}
let source = try String(contentsOf: sourceURL, encoding: .utf8)
// The test invokes the same functions from a compute entry instead of SwiftUI stitching.
// This identical annotation-only adaptation is used for both reference and candidate.
let kernel = """
kernel void validationFrame(texture2d<half,access::write> image [[texture(0)]],
 constant float *u [[buffer(0)]],device const float *h [[buffer(1)]],
 uint2 id [[thread_position_in_grid]]) {
 if(id.x>=image.get_width()||id.y>=image.get_height())return;
 float2 p=float2(id)+0.5;
 half4 c=v2ComposeBackground(p,half4(1),float2(u[0],u[1]),u[2],u[3],
 float2(u[4],u[5]),float2(u[6],u[7]),u[8],u[9],u[10],u[11],u[12],u[13],
 u[14],u[15],u[16],u[17],u[18],u[19],u[20],u[21],u[22],u[23],u[24],u[25],u[26],h,int(u[27]));
 image.write(c,id);
}
kernel void validationDistortion(constant float *u [[buffer(0)]],
 device float2 *out [[buffer(1)]],uint id [[thread_position_in_grid]]) {
 if(id>=360)return;
 float2 p=float2((float(id%40)+.5)*u[0]/40,(float(id/40)+.5)*u[1]/9);
 out[id]=gradientTrailDistortion(p,float2(u[0],u[1]),float2(u[4],u[5]),
 float2(u[6],u[7]),0.65,u[10]);
}
"""
let options = MTLCompileOptions()
options.fastMathEnabled = true
let library = try device.makeLibrary(
    source: source.replacingOccurrences(of: "[[ stitchable ]]", with: "") + "\n" + kernel,
    options: options)
func pipeline(_ name: String) throws -> MTLComputePipelineState {
    guard let function = library.makeFunction(name: name) else { fatalError(name) }
    return try device.makeComputePipelineState(function: function)
}
let framePipeline = try pipeline("validationFrame")
let probePipeline = try pipeline("v2CaptionProbe")
let distortionPipeline = try pipeline("validationDistortion")
let descriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba16Float, width: 390, height: 844, mipmapped: false)
descriptor.storageMode = .shared
descriptor.usage = [.shaderWrite, .shaderRead]
let texture = device.makeTexture(descriptor: descriptor)!
let uniforms = device.makeBuffer(length: 32 * 4, options: .storageModeShared)!
let history = device.makeBuffer(length: 512 * 4, options: .storageModeShared)!
let probes = device.makeBuffer(length: 360 * 16, options: .storageModeShared)!
let distortions = device.makeBuffer(length: 360 * 8, options: .storageModeShared)!
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

for item in cases {
    let name = item["name"] as! String
    let u = (item["uniforms"] as! [NSNumber]).map { $0.floatValue }
    let h = (item["history"] as! [NSNumber]).map { $0.floatValue }
    precondition(u.count == 28 && h.count <= 240 && Int(u[27]) == h.count)
    let input = u + [Float(34), Float(690), Float(356), Float(762)]
    memset(history.contents(), 0, history.length)
    input.withUnsafeBytes {
        memcpy(uniforms.contents(), $0.baseAddress!, $0.count)
        memcpy(history.contents().advanced(by: 256 * 4), $0.baseAddress!, $0.count)
    }
    if !h.isEmpty { h.withUnsafeBytes { memcpy(history.contents(), $0.baseAddress!, $0.count) } }
    let command = queue.makeCommandBuffer()!
    let encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(framePipeline)
    encoder.setTexture(texture, index: 0)
    encoder.setBuffer(uniforms, offset: 0, index: 0)
    encoder.setBuffer(history, offset: 0, index: 1)
    encoder.dispatchThreads(MTLSize(width: 390, height: 844, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    encoder.setComputePipelineState(probePipeline)
    encoder.setBuffer(probes, offset: 0, index: 2)
    encoder.dispatchThreads(MTLSize(width: 360, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
    encoder.setComputePipelineState(distortionPipeline)
    encoder.setBuffer(distortions, offset: 0, index: 1)
    encoder.dispatchThreads(MTLSize(width: 360, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
    encoder.endEncoding()
    command.commit()
    // Blocking is confined to this offline validation executable, never the app.
    command.waitUntilCompleted()
    guard command.status == .completed else { fatalError(String(describing: command.error)) }
    var raw = Data(count: 390 * 844 * 8)
    raw.withUnsafeMutableBytes {
        texture.getBytes($0.baseAddress!, bytesPerRow: 390 * 8,
                         from: MTLRegionMake2D(0, 0, 390, 844), mipmapLevel: 0)
    }
    try raw.write(to: outputURL.appendingPathComponent(name + ".rgba16f"))
    try Data(bytes: probes.contents(), count: probes.length)
        .write(to: outputURL.appendingPathComponent(name + ".probe"))
    try Data(bytes: distortions.contents(), count: distortions.length)
        .write(to: outputURL.appendingPathComponent(name + ".distortion"))
    let pixels: [UInt8] = raw.withUnsafeBytes { bytes in
        bytes.bindMemory(to: UInt16.self).map {
            let value = Float(Float16(bitPattern: $0))
            precondition(value.isFinite)
            return UInt8((min(max(value, 0), 1) * 255).rounded())
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: 390, height: 844, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: 390 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(
        outputURL.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}
let metadata: [String: Any] = ["device": device.name, "frames": cases.count,
    "size": [390, 844], "format": "rgba16Float", "fastMath": true,
    "scope": "Actual offscreen Metal function output; UI compositing tested by unchanged app sources"]
try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    .write(to: outputURL.appendingPathComponent("gpu.json"))
print("Rendered \(cases.count) real Metal frames on \(device.name)")
