import Foundation
import UIKit

public enum GradientTheme:String,CaseIterable,Sendable {
    case blueDark,blueLight,yellowDark,yellowLight
    public var isDark:Bool {self == .blueDark || self == .yellowDark}
    public var isYellow:Bool {self == .yellowDark || self == .yellowLight}
}

extension GradientViewController {
    public var theme:GradientTheme {
        get {yellow ? (dark ? .yellowDark:.yellowLight):(dark ? .blueDark:.blueLight)}
        set {dark=newValue.isDark;yellow=newValue.isYellow}
    }
    public convenience init(theme:GradientTheme = .blueLight,initialProgress:CGFloat=0) throws {
        try self.init(session:GradientSession(at:Date().timeIntervalSinceReferenceDate,initialProgress:initialProgress),dark:theme.isDark,yellow:theme.isYellow)
    }
}
