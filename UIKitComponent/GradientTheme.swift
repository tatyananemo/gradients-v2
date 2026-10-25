import Foundation
import UIKit

public enum GradientTheme:String,CaseIterable,Sendable {
    case yellowDark,yellowLight
    public var isDark:Bool {self == .yellowDark}
    public var isYellow:Bool {true}
}

extension GradientViewController {
    public var theme:GradientTheme {
        get {dark ? .yellowDark:.yellowLight}
        set {dark=newValue.isDark}
    }
    public convenience init(theme:GradientTheme = .yellowDark,initialProgress:CGFloat=0) throws {
        try self.init(session:GradientSession(at:Date().timeIntervalSinceReferenceDate,initialProgress:initialProgress),dark:theme.isDark)
    }
}
