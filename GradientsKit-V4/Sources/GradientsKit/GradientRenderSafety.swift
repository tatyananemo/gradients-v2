import Foundation
import Metal

/// A terminal failure stops this controller; resumeRendering never clears it.
/// GPU completions and the three mask workers may report concurrently.
final class GradientRenderSafety {
    private let lock=NSLock()
    private var failure:NSError?
    var firstError:NSError? {lock.lock();defer {lock.unlock()};return failure}
    var isStopped:Bool {firstError != nil}
    func fail(_ stage:String,error:Error?=nil) {
        lock.lock();defer {lock.unlock()}
        guard failure == nil else{return}
        var info:[String:Any]=[NSLocalizedDescriptionKey:stage]
        if let error {info[NSUnderlyingErrorKey]=error}
        failure=NSError(domain:"GradientsKit.RenderingStopped",code:1,userInfo:info)
    }
    func completed(_ command:MTLCommandBuffer,stage:String) {
        if command.status == .error {fail(stage,error:command.error)}
    }
    // Used only at didEnterBackground, never in the frame loop. All tracked
    // buffers have been committed; scheduled/completed/error are terminal here.
    static func waitUntilScheduled(_ command:MTLCommandBuffer?) {
        if let command,command.status == .committed {command.waitUntilScheduled()}
    }
}
