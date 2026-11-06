import Foundation

/// Opt-in bounded measurements. No timers, disk I/O or allocations in normal SDK use.
final class GradientPerformanceMetrics {
    private let lock=NSLock()
    private var samples:[String:[Double]]=[:]
    private var presentations:[Double]=[]
    private var displayLinks:[Double]=[]
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
    func displayLink(at time:Double) {
        lock.lock();defer{lock.unlock()}
        if displayLinks.count<limit {displayLinks.append(time)}
    }
    func report()->[String:Any] {
        lock.lock();let values=samples,shown=presentations.sorted(),ticks=displayLinks.sorted();lock.unlock()
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
        if let first=shown.first,let last=shown.last {
            let deficit=max(0,Int(((last-first)*60).rounded())-intervals.count)
            result[cadence=="completion" ? "completionDeficitAt60Hz":"missedVSyncsEstimate"]=deficit
        }
        // Completion callbacks are not vsync timestamps in Simulator. A stream
        // of 20 ms callbacks loses capacity at 60 Hz even with no >25 ms gaps.
        result["longCompletionGapsOver25MS"]=intervals.filter{$0>25}.count
        let tickIntervals=zip(ticks.dropFirst(),ticks).map{($0-$1)*1000}
        result["displayLinkIntervalMS"]=summary(tickIntervals)
        if let first=ticks.first,let last=ticks.last,last>first {
            result["displayLinkFPS"]=Double(ticks.count-1)/(last-first)
            result["missedDisplayLinkTicks"]=max(0,Int(((last-first)*60).rounded())-tickIntervals.count)
        }
        return result
    }
}
