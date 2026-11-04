import Foundation
import Metal

private final class GradientResourceMarker:NSObject {}

/// Precompiled library belongs to the SDK framework, never to Bundle.main.
final class GradientGPU {
    let device:MTLDevice,queue:MTLCommandQueue
    let library:MTLLibrary
    let background:MTLComputePipelineState,caption:MTLComputePipelineState
    let distortion:MTLRenderPipelineState,composite:MTLRenderPipelineState
    let clear:MTLTexture
    init() throws {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {
            throw NSError(domain:"GradientsKit.MetalUnavailable",code:1)
        }
        self.device=device;self.queue=queue
        library=try device.makeDefaultLibrary(bundle:Bundle(for:GradientResourceMarker.self))
        let compiledLibrary=library
        compiledLibrary.label="GradientsKit/default.metallib"
        func function(_ name:String) throws -> MTLFunction {
            guard let function=compiledLibrary.makeFunction(name:name) else {throw NSError(domain:"GradientsKit.MissingFunction",code:2,userInfo:[NSLocalizedDescriptionKey:name])}
            return function
        }
        func pipeline(_ name:String,_ format:MTLPixelFormat) throws -> MTLRenderPipelineState {
            let descriptor=MTLRenderPipelineDescriptor()
            descriptor.vertexFunction=try function("prototypeVertex");descriptor.fragmentFunction=try function(name)
            descriptor.colorAttachments[0].pixelFormat=format
            return try device.makeRenderPipelineState(descriptor:descriptor)
        }
        background=try device.makeComputePipelineState(function:function("prototypeComputeBackground"))
        caption=try device.makeComputePipelineState(function:function("v2CaptionProbe"))
        distortion=try pipeline("prototypeDistortion",.rgba16Float)
        composite=try pipeline("prototypeComposite",.bgra8Unorm)
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1,height:1,mipmapped:false)
        descriptor.usage = .shaderRead;descriptor.storageMode = .shared
        guard let texture=device.makeTexture(descriptor:descriptor) else {throw NSError(domain:"GradientsKit.TextureUnavailable",code:3)}
        clear=texture
        var zero:UInt32=0
        clear.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&zero,bytesPerRow:4)
    }
}
