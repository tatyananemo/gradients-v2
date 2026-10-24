import Foundation
import CoreGraphics
import Metal

final class SessionCaptionProbe {
 private(set) var activation:Double=0
 private(set) var key:String=""
 private let device:MTLDevice?
 private var queue:MTLCommandQueue?,pipeline:MTLComputePipelineState?
 private var uniformsBuffer:MTLBuffer?,historyBuffer:MTLBuffer?,resultBuffer:MTLBuffer?
 private var busy=false,needed=false,filteredRisk:Double=0,previousWave:Double=0
 private var lastTime:TimeInterval=0
 init(gpu:GradientGPU){
  device=gpu.device;pipeline=gpu.caption;queue=gpu.device.makeCommandQueue()
  uniformsBuffer=gpu.device.makeBuffer(length:32*4,options:.storageModeShared)
  historyBuffer=gpu.device.makeBuffer(length:512*4,options:.storageModeShared)
  resultBuffer=gpu.device.makeBuffer(length:360*16,options:.storageModeShared)
 }
 func sample(uniforms:[Float],history:[Float],frame:CGRect,key sampleKey:String,dark:Bool,yellow:Bool){
  guard !busy,uniforms.count==28,history.count<=240,
   let queue,let pipeline,let uniformsBuffer,let historyBuffer,let resultBuffer else{return}
  let currentTime=ProcessInfo.processInfo.systemUptime
  let dt=lastTime==0 ? 1.0/60:min(max(currentTime-lastTime,1.0/240),0.1)
  lastTime=currentTime
  if key != sampleKey {key=sampleKey;activation=0;filteredRisk=0;previousWave=0;needed=false}
  let w=CGFloat(uniforms[0]),h=CGFloat(uniforms[1])
  let box=frame.height>0 ? frame:CGRect(x:0,y:h*0.82,width:w,height:h*0.085)
  let x0=max(0,box.minX+34),x1=min(w,box.maxX-34)
  let y0=max(0,box.minY),y1=min(h,box.maxY)
  let u=uniforms+[Float(x0),Float(y0),Float(x1),Float(y1)]
  u.withUnsafeBytes{memcpy(uniformsBuffer.contents(),$0.baseAddress!,$0.count)}
  u.withUnsafeBytes{memcpy(historyBuffer.contents().advanced(by:256*4),$0.baseAddress!,$0.count)}
  if !history.isEmpty{history.withUnsafeBytes{memcpy(historyBuffer.contents(),$0.baseAddress!,$0.count)}}
  guard let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else{return}
  busy=true
  encoder.setComputePipelineState(pipeline);encoder.setBuffer(uniformsBuffer,offset:0,index:0)
  encoder.setBuffer(historyBuffer,offset:0,index:1);encoder.setBuffer(resultBuffer,offset:0,index:2)
  encoder.dispatchThreads(MTLSize(width:360,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:32,height:1,depth:1));encoder.endEncoding()
  command.addCompletedHandler { [weak self] command in
   let samples=Array(UnsafeBufferPointer(start:resultBuffer.contents().assumingMemoryBound(to:SIMD4<Float>.self),count:360))
   DispatchQueue.main.async {
    guard let self else{return};self.busy=false
    guard command.status == .completed,self.key==sampleKey else{return}
    let l=samples.map{Double($0.x)}.sorted(),wave=samples.map{Double($0.y)}.sorted(),delta=samples.map{Double($0.z)}.sorted()
    let low=l[36],high=l[324],W=wave[324],D=delta[324],sat=samples.reduce(0){$0+Double($1.w)}/360
    func ease(_ v:Double,_ a:Double,_ b:Double)->Double {let t=min(max((v-a)/(b-a),0),1);return t*t*(3-2*t)}
    let textLight=pow((0.20+0.055)/1.055,2.4),contrast=(low+0.05)/(textLight+0.05)
    var risk:Double
    var attack=0.05,release=0.08
    if dark {
     // Keep the temporal-blend fix: ignore the tiny W tail (.015), and
     // never release/replace a caption ellipse. Only the real gradient fades.
     let presence=max(ease(W,0.015,0.15),ease(D,0.02,0.12))
     risk=presence*ease(high,0.22,0.50)
     attack=0.065;release=0.16
    }else if yellow {
     // Exact transition-caption condition and temporal constants.
     risk=max(1-ease(contrast,4.8,5.8),ease(high,0.58,0.74)*ease(sat,0.20,0.35))
     attack=0.075;release=0.25
    }else{
     risk=ease(W,0.025,0.10)*max(1-ease(contrast,4.8,5.8),ease(high,0.38,0.60))
     if W+0.0005<self.previousWave && W<0.12 {risk=0}
    }
    self.previousWave=W
    self.filteredRisk+=(risk-self.filteredRisk)*(1-exp(-dt/0.025))
    if self.filteredRisk>0.42 {self.needed=true} else if self.filteredRisk<0.22 {self.needed=false}
    let target=self.needed ? 1.0:0.0,tau=self.needed ? attack:release
    var next=self.activation+(target-self.activation)*(1-exp(-dt/tau))
    if !self.needed && next<0.001 {next=0};if self.needed && next>0.999 {next=1}
    self.activation=min(max(next,0),1)
   }
  }
  command.commit()
 }
}
