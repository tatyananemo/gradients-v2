// Test executable, not app code: compare real fragment output to frozen compute reference.
import Foundation
import Metal
let args=CommandLine.arguments
let device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
let source=try String(contentsOfFile:args[1],encoding:.utf8).replacingOccurrences(of:"[[ stitchable ]]",with:"")
let options=MTLCompileOptions();options.fastMathEnabled=true
let library=try device.makeLibrary(source:source,options:options)
let desc=MTLRenderPipelineDescriptor();desc.vertexFunction=library.makeFunction(name:"prototypeVertex");desc.fragmentFunction=library.makeFunction(name:"prototypeBackground");desc.colorAttachments[0].pixelFormat = .rgba16Float
let pipeline=try device.makeRenderPipelineState(descriptor:desc)
let compute=try device.makeComputePipelineState(function:library.makeFunction(name:"prototypeComputeBackground")!)
let cases=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[2]))) as! [[String:Any]]
let folder=URL(fileURLWithPath:args[3]);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
let td=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:390,height:844,mipmapped:false);td.usage=[.renderTarget,.shaderRead,.shaderWrite];td.storageMode = .shared
let texture=device.makeTexture(descriptor:td)!
for item in cases {
 let u=(item["uniforms"] as! [NSNumber]).map{$0.floatValue}
 let h=(item["history"] as! [NSNumber]).map{$0.floatValue}
 let ub=device.makeBuffer(bytes:u,length:u.count*4,options:.storageModeShared)!
 let history=h.isEmpty ? [Float](repeating:0,count:1):h
 let hb=device.makeBuffer(bytes:history,length:history.count*4,options:.storageModeShared)!
 let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=texture;pass.colorAttachments[0].loadAction = .dontCare;pass.colorAttachments[0].storeAction = .store
 let command=queue.makeCommandBuffer()!
 var scale:Float=1
 if args.count>4 && args[4]=="compute" {
  let encoder=command.makeComputeCommandEncoder()!
  encoder.setComputePipelineState(compute);encoder.setTexture(texture,index:0)
  encoder.setBuffer(ub,offset:0,index:0);encoder.setBuffer(hb,offset:0,index:1);encoder.setBytes(&scale,length:4,index:2)
  encoder.dispatchThreads(MTLSize(width:390,height:844,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));encoder.endEncoding()
 }else{
  let encoder=command.makeRenderCommandEncoder(descriptor:pass)!
  encoder.setRenderPipelineState(pipeline);encoder.setFragmentBuffer(ub,offset:0,index:0);encoder.setFragmentBuffer(hb,offset:0,index:1)
  encoder.setFragmentBytes(&scale,length:4,index:2)
  encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);encoder.endEncoding()
 }
 command.commit();command.waitUntilCompleted()
 guard command.status == .completed else{fatalError(String(describing:command.error))}
 var bytes=[UInt8](repeating:0,count:390*844*8)
 texture.getBytes(&bytes,bytesPerRow:390*8,from:MTLRegionMake2D(0,0,390,844),mipmapLevel:0)
 try Data(bytes).write(to:folder.appendingPathComponent((item["name"] as! String)+".rgba16f"))
}
print("Rendered \(cases.count) actual adapter frames on \(device.name)")
