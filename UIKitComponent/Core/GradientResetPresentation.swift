import Foundation
import CoreGraphics

/// Presentation-only interpolation. It never writes to GradientSession or GPU
/// background parameters. Shader/progress/release clocks keep their V2 behavior.
struct GradientResetPresentation {
    let started:TimeInterval
    let counter:CGFloat
    let mask:CGFloat
    static let duration:TimeInterval=0.35
    func values(at time:TimeInterval)->(counter:CGFloat,mask:CGFloat,finished:Bool) {
        let t=min(max((time-started)/Self.duration,0),1)
        // CSS/Core Animation easeInOut: solve the time coordinate, then evaluate Y.
        var lo=0.0,hi=1.0
        for _ in 0..<32 {
            let s=(lo+hi)/2
            let x=3*(1-s)*(1-s)*s*0.42+3*(1-s)*s*s*0.58+s*s*s
            if x<t {lo=s}else{hi=s}
        }
        let s=(lo+hi)/2,ease=CGFloat(3*(1-s)*s*s+s*s*s)
        let remaining=t<=0 ? CGFloat(1):t>=1 ? 0:1-ease
        return (counter*remaining,mask*remaining,t>=1)
    }
}
