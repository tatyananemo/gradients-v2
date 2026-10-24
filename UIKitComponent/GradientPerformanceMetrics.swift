import Foundation

/// Opt-in bounded measurements. No timers, disk I/O or allocations in normal SDK use.
final class GradientPerformanceMetrics {
    private let lock=NSLock()
    private var samples:[String:[Double]]=[:]
    private var presentations:[Double]=[]
    private var envelopes:[Int:(Int,Double,Double,Double)]=[:]
    private var latestInput=0.0
    private var consumedInput=0.0
    private let limit=6000
    #if targetEnvironment(simulator)
    private let cadence="completion"
    #else
    private let cadence="presentation"
    #endif
    func input(at time:Double) {lock.lock();latestInput=time;lock.unlock()}
    func consumeInput()->Double {
        lock.lock();defer{lock.unlock()}
        guard latestInput>consumedInput else{return 0}
        consumedInput=latestInput;return latestInput
    }
    func add(_ name:String,_ value:Double) {
        guard value.isFinite,value>=0 else{return}
        lock.lock();defer{lock.unlock()}
        if samples[name,default:[]].count<limit {samples[name,default:[]].append(value)}
    }
    func gpu(frame:Int,expected:Int,kind:String,start:Double,end:Double) {
        guard start>0,end>=start else{return}
        add(kind,(end-start)*1000)
        lock.lock();defer{lock.unlock()}
        let old=envelopes[frame] ?? (0,start,end,0)
        let value=(old.0+1,min(start,old.1),max(end,old.2),old.3+(end-start)*1000)
        if value.0==expected {
            if samples["gpuEnvelopeMS",default:[]].count<limit {
                samples["gpuEnvelopeMS",default:[]].append((value.2-value.1)*1000)
                samples["gpuWorkMS",default:[]].append(value.3)
            }
            envelopes.removeValue(forKey:frame)
        } else if envelopes.count<120 {envelopes[frame]=value}
    }
    func presented(at time:Double,input:Double) {
        guard time>0 else{return}
        lock.lock();defer{lock.unlock()}
        if presentations.count<limit {presentations.append(time)}
        if input>0,time>=input,samples["inputTo\(cadence.capitalized)MS",default:[]].count<limit {
            samples["inputTo\(cadence.capitalized)MS",default:[]].append((time-input)*1000)
        }
    }
    func report()->[String:Any] {
        lock.lock();let values=samples,shown=presentations.sorted();lock.unlock()
        func summary(_ values:[Double])->[String:Double] {
            let s=values.sorted();guard !s.isEmpty else{return ["count":0]}
            func percentile(_ p:Double)->Double{s[min(s.count-1,Int(ceil(Double(s.count)*p))-1)]}
            return ["count":Double(s.count),"mean":s.reduce(0,+)/Double(s.count),"p95":percentile(0.95),"p99":percentile(0.99),"max":s.last!]
        }
        var result:[String:Any]=values.mapValues{summary($0)}
        let intervals=zip(shown.dropFirst(),shown).map{($0-$1)*1000}
        result["\(cadence)IntervalMS"]=summary(intervals)
        result["\(cadence)Frames"]=shown.count
        if let first=shown.first,let last=shown.last,last>first {
            result["\(cadence)FPS"]=Double(shown.count-1)/(last-first)
            result["durationSeconds"]=last-first
        }
        result["timingBasis"]=cadence=="completion" ? "Simulator completion callback; not physical presentation":"MTLDrawable.presentedTime"
        result["missedVSyncsEstimate"]=intervals.reduce(0){$0+max(0,Int(($1/(1000/60)).rounded())-1)}
        return result
    }
}
