import Foundation
import Metal

/// GPU failures are terminal. Resource unavailability permits one explicit retry.
/// GPU completions and the three mask workers may report concurrently.
final class GradientRenderSafety {
    private let lock=NSLock()
    private var failure:NSError?
    private var resourceFailure:NSError?
    var firstError:NSError? {lock.lock();defer {lock.unlock()};return failure ?? resourceFailure}
    var isStopped:Bool {firstError != nil}
    func resourcesUnavailable(_ stage:String) {
        lock.lock();defer {lock.unlock()}
        if resourceFailure == nil {resourceFailure=NSError(domain:"GradientsKit.ResourceUnavailable",code:1,userInfo:[NSLocalizedDescriptionKey:stage])}
    }
    /// Called only by resumeRendering. A subsequent failed attempt pauses again;
    /// display-link ticks and foreground notifications cannot clear either latch.
    func retryResources()->Bool {
        lock.lock();defer {lock.unlock()}
        guard failure == nil,resourceFailure != nil else{return false}
        resourceFailure=nil;return true
    }
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
