import Metal

/// Experimental only: each in-flight slot owns one tracked, GPU-private cache.
/// The command buffer retains bound buffers through completion, including resize.
struct GradientPrecalculationBuffers {
    let width:Int,height:Int
    let slots:[MTLBuffer]
    static let slotCount=3
    static let historyCapacity=240
    static let headerFloats=286
    static let xStride=10,yStride=8

    static func byteCount(width:Int,height:Int)->Int? {
        guard width>0,height>0,width<=Int(UInt32.max),height<=Int(UInt32.max) else{return nil}
        let (x,overflowX)=width.multipliedReportingOverflow(by:xStride)
        let (y,overflowY)=height.multipliedReportingOverflow(by:yStride)
        let (axes,overflowAxes)=x.addingReportingOverflow(y)
        let (count,overflowHeader)=axes.addingReportingOverflow(headerFloats)
        let (bytes,overflowBytes)=count.multipliedReportingOverflow(by:MemoryLayout<Float>.stride)
        guard !overflowX,!overflowY,!overflowAxes,!overflowHeader,!overflowBytes else{return nil}
        return bytes
    }
    init?(device:MTLDevice,width:Int,height:Int) {
        guard let bytes=Self.byteCount(width:width,height:height),bytes<=device.maxBufferLength else{return nil}
        var created:[MTLBuffer]=[]
        for index in 0..<Self.slotCount {
            guard let buffer=device.makeBuffer(length:bytes,options:[.storageModePrivate,.hazardTrackingModeTracked]) else{return nil}
            buffer.label="V4/precalculation/slot-\(index)/\(width)x\(height)"
            created.append(buffer)
        }
        self.width=width;self.height=height;slots=created
    }
    func buffer(slot:Int,width:Int,height:Int)->MTLBuffer? {
        guard self.width==width,self.height==height,slots.indices.contains(slot) else{return nil}
        return slots[slot]
    }
    func encode(command:MTLCommandBuffer,pipeline:MTLComputePipelineState,
                uniformBuffer:MTLBuffer,historyBuffer:MTLBuffer,historyCount:Int,
                scale:Float,slot:Int)->MTLBuffer? {
        guard historyCount>=0,historyCount<=Self.historyCapacity,scale.isFinite,scale>0,
              historyBuffer.length>=historyCount*MemoryLayout<Float>.stride,
              uniformBuffer.length>=28*MemoryLayout<Float>.stride,
              let cache=buffer(slot:slot,width:width,height:height),
              pipeline.maxTotalThreadsPerThreadgroup>=64,
              let encoder=command.makeComputeCommandEncoder() else{return nil}
        var extent=SIMD4<UInt32>(UInt32(width),UInt32(height),scale.bitPattern,UInt32(historyCount))
        encoder.label="V4/precalculation/slot-\(slot)"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(uniformBuffer,offset:0,index:0)
        encoder.setBuffer(historyBuffer,offset:0,index:1)
        encoder.setBuffer(cache,offset:0,index:2)
        encoder.setBytes(&extent,length:MemoryLayout<SIMD4<UInt32>>.stride,index:3)
        let count=max(width,height,historyCount)
        encoder.dispatchThreadgroups(MTLSize(width:(count+63)/64,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:64,height:1,depth:1))
        encoder.endEncoding()
        return cache
    }
}
