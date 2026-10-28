// Native macOS validation/benchmark only. Never launches an iOS app.
import Foundation
import Metal
import CryptoKit

struct Variant:Decodable {
    let name:String,source:String
    let width:Int,height:Int,zeros:Bool
}
struct Frame:Decodable {
    let name:String,uniforms:[Float],history:[Float]
}
struct Manifest:Decodable {
    let variants:[Variant],cases:String,oracle:String,output:String
    let rounds:Int
}
struct Prepared {
    let frame:Frame,u:MTLBuffer,h:MTLBuffer
}
enum Failure:Error {case unavailable,command(String),invalid(String)}
let args=CommandLine.arguments
let manifest=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:URL(fileURLWithPath:args[1])))
guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {throw Failure.unavailable}
let inputs=try JSONDecoder().decode([Frame].self,from:Data(contentsOf:URL(fileURLWithPath:manifest.cases)))
let approved=inputs.filter {$0.name.hasPrefix("yellow-")}
guard approved.count==36 else {throw Failure.invalid("Expected 36 unchanged Yellow reference frames")}
let oracleObject=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:manifest.oracle))) as! [String:Any]
let oracle=oracleObject["render_sha256"] as! [String:String]
let options=MTLCompileOptions();options.fastMathEnabled=true
var pipelines:[MTLComputePipelineState]=[]
for v in manifest.variants {
    let library=try device.makeLibrary(source:String(contentsOfFile:v.source,encoding:.utf8),options:options)
    let function:MTLFunction
    if v.zeros {
        let values=MTLFunctionConstantValues();var enabled=true
        values.setConstantValue(&enabled,type:.bool,index:0)
        function=try library.makeFunction(name:"prototypeComputeBackground",constantValues:values)
    } else {
        guard let f=library.makeFunction(name:"prototypeComputeBackground") else {throw Failure.unavailable}
        function=f
    }
    let pipeline=try device.makeComputePipelineState(function:function)
    guard v.width*v.height<=pipeline.maxTotalThreadsPerThreadgroup else {throw Failure.invalid("Unsupported group: \(v.name)")}
    pipelines.append(pipeline)
}
func prepare(_ frame:Frame)throws->Prepared {
    let history=frame.history.isEmpty ? [Float(0)]:frame.history
    guard let u=device.makeBuffer(bytes:frame.uniforms,length:frame.uniforms.count*4,options:.storageModeShared),
          let h=device.makeBuffer(bytes:history,length:history.count*4,options:.storageModeShared) else {throw Failure.unavailable}
    return Prepared(frame:frame,u:u,h:h)
}
func texture(scale:Int,storage:MTLStorageMode = .shared)throws->MTLTexture {
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:390*scale,height:844*scale,mipmapped:false)
    descriptor.usage=[.shaderRead,.shaderWrite];descriptor.storageMode=storage
    guard let t=device.makeTexture(descriptor:descriptor) else {throw Failure.unavailable}
    return t
}
func render(_ index:Int,_ input:Prepared,_ texture:MTLTexture,scale:Float,repeats:Int=1)throws->Double {
    guard let command=queue.makeCommandBuffer() else {throw Failure.unavailable}
    let v=manifest.variants[index]
    for _ in 0..<repeats {
        guard let encoder=command.makeComputeCommandEncoder() else {throw Failure.unavailable}
        var factor=scale
        encoder.setComputePipelineState(pipelines[index]);encoder.setTexture(texture,index:0)
        encoder.setBuffer(input.u,offset:0,index:0);encoder.setBuffer(input.h,offset:0,index:1)
        encoder.setBytes(&factor,length:4,index:2)
        let threads=MTLSize(width:v.width,height:v.height,depth:1)
        let groups=MTLSize(width:(texture.width+v.width-1)/v.width,height:(texture.height+v.height-1)/v.height,depth:1)
        encoder.dispatchThreadgroups(groups,threadsPerThreadgroup:threads);encoder.endEncoding()
    }
    command.commit();command.waitUntilCompleted() // Test host only, never SDK code.
    guard command.status == .completed else {throw Failure.command(String(describing:command.error))}
    guard command.gpuEndTime>command.gpuStartTime else {throw Failure.invalid("Unavailable GPU timestamps")}
    return (command.gpuEndTime-command.gpuStartTime)*1000/Double(repeats)
}
func digest(_ texture:MTLTexture,readback:MTLTexture?=nil)throws->String {
    let readable:MTLTexture
    if texture.storageMode == .private {
        guard let readback,let command=queue.makeCommandBuffer(),let blit=command.makeBlitCommandEncoder() else {throw Failure.unavailable}
        blit.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
                  sourceSize:MTLSize(width:texture.width,height:texture.height,depth:1),
                  to:readback,destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0))
        blit.endEncoding();command.commit();command.waitUntilCompleted()
        guard command.status == .completed else {throw Failure.command(String(describing:command.error))}
        readable=readback
    } else {readable=texture}
    var bytes=[UInt8](repeating:0,count:texture.width*texture.height*8)
    readable.getBytes(&bytes,bytesPerRow:texture.width*8,from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0)
    return SHA256.hash(data:Data(bytes)).map{String(format:"%02x",$0)}.joined()
}
let small=try texture(scale:1),full=try texture(scale:3,storage:.private),fullReadback=try texture(scale:3)
let prepared=try approved.map(prepare)
var exact:[String:[String:Any]]=[:]
var baseline:[String:String]=[:]
for (index,v) in manifest.variants.enumerated() {
    var changed:[String]=[]
    for input in prepared {
        _=try render(index,input,small,scale:1)
        if try digest(small) != oracle[input.frame.name+".rgba16f"] {changed.append(input.frame.name)}
    }
    exact[v.name]=["goldens":prepared.count,"changed":changed]
    print("Goldens \(v.name): \(prepared.count-changed.count)/\(prepared.count)")
}
// Full native iPhone pixel dimensions, plus cycle seams and zero/complete progress.
var extra=approved
for dark in [true,false] {
    let template=approved.first {$0.name.hasPrefix(dark ? "yellow-dark":"yellow-light") && $0.uniforms[25]==1}!
    for p:Float in [0,0.3,0.6,0.8,1] {
        for t:Float in [0.001,1.2,1.65,2.1,2.999,3.001] {
            var u=template.uniforms;u[2]=p;u[10]=p*10+t;u[25]=1;u[26]=t;u[27]=0
            extra.append(Frame(name:"\(dark ? "dark":"light")-p\(p)-t\(t)",uniforms:u,history:[]))
        }
    }
}
let extended=try extra.map(prepare)
for (index,v) in manifest.variants.enumerated() {
    var changed:[String]=[]
    for input in extended {
        _=try render(index,input,full,scale:3)
        let hash=try digest(full,readback:fullReadback)
        if index==0 {baseline[input.frame.name]=hash}
        else if baseline[input.frame.name] != hash {changed.append(input.frame.name)}
    }
    exact[v.name]?["nativeSizeCompared"]=extended.count
    exact[v.name]?["nativeSizeChanged"]=changed
    print("Native-size exact \(v.name): \(extended.count-changed.count)/\(extended.count)")
}
let bench=prepared.filter {$0.frame.uniforms[25]==1}
let benchTexture=full // Same private storage mode as the SDK background target; no readback during timing.
// Fixed paired workloads, alternating variant order to limit clock/order bias.
for index in pipelines.indices {for input in bench.prefix(3) {_=try render(index,input,benchTexture,scale:3,repeats:4)}}
var samples:[[String:Any]]=[]
let benchStart=ProcessInfo.processInfo.systemUptime
for round in 0..<manifest.rounds {
    for (caseIndex,input) in bench.enumerated() {
        for offset in pipelines.indices {
            let index=(offset+round+caseIndex)%pipelines.count
            let ms=try render(index,input,benchTexture,scale:3,repeats:4)
            samples.append(["variant":manifest.variants[index].name,"case":input.frame.name,
                            "theme":input.frame.name.hasPrefix("yellow-dark") ? "dark":"light","round":round,"gpuMS":ms])
        }
    }
}
let pipelineInfo=zip(manifest.variants,pipelines).map {v,p in ["variant":v.name,"threadExecutionWidth":p.threadExecutionWidth,"maxThreads":p.maxTotalThreadsPerThreadgroup] as [String:Any]}
let result:[String:Any]=["device":device.name,"resolution":[full.width,full.height],"scale":3,
    "thermalState":ProcessInfo.processInfo.thermalState.rawValue,"rounds":manifest.rounds,
    "benchmarkSeconds":ProcessInfo.processInfo.systemUptime-benchStart,"dispatchesPerSample":4,"benchmarkStorage":"private",
    "pipelines":pipelineInfo,"exact":exact,"samples":samples]
try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:manifest.output))
print("Saved \(manifest.output)")
