import UIKit
import CoreText

/// UIKit counterpart of numericText in the original transaction: ordinary input
/// is unanimated, reset rolls changed digits with easeInOut for exactly 0.35 s.
final class GradientPercentageLabel:UILabel {
    private var transition:UIViewPropertyAnimator?
    private var columns:[UIView]=[]
    private var hidesBaseText=false
    override var textColor:UIColor! { didSet {
        for column in columns {for case let label as UILabel in column.subviews {label.textColor=textColor}}
    }}

    func setPercentage(_ value:Int, animated:Bool=false) {
        let target="\(value)%"
        guard text != target else{return}
        let previous=text ?? target
        cancelTransition()
        text=target
        accessibilityLabel=target
        guard animated,previous != target,window != nil else{return}
        let old=Array(previous),new=Array(target)
        let oldFrames=frames(for:previous),newFrames=frames(for:target)
        hidesBaseText=true;setNeedsDisplay()
        let animator=UIViewPropertyAnimator(duration:0.35,curve:.easeInOut)
        let count=max(old.count,new.count)
        for offset in 0..<count {
            let i=old.count-1-offset,j=new.count-1-offset
            let oldCharacter=i>=0 ? old[i]:nil,newCharacter=j>=0 ? new[j]:nil
            let from=i>=0 ? oldFrames[i]:newFrames[j]
            let to=j>=0 ? newFrames[j]:CGRect(x:from.midX,y:from.minY,width:0,height:from.height)
            let container=UIView(frame:from);container.clipsToBounds=true;container.isAccessibilityElement=false
            addSubview(container);columns.append(container)
            func glyph(_ character:Character)->UILabel {
                let label=UILabel(frame:CGRect(origin:.zero,size:from.size))
                label.font=font;label.textColor=textColor;label.textAlignment = .center
                label.text=String(character);label.isAccessibilityElement=false
                container.addSubview(label);return label
            }
            if oldCharacter==newCharacter,let character=newCharacter {
                let label=glyph(character)
                animator.addAnimations {container.frame=to;label.frame=CGRect(origin:.zero,size:to.size)}
            } else {
                let outgoing=oldCharacter.map(glyph),incoming=newCharacter.map(glyph)
                incoming?.transform=CGAffineTransform(translationX:0,y:font.lineHeight)
                incoming?.alpha=0
                animator.addAnimations {
                    container.frame=to
                    outgoing?.transform=CGAffineTransform(translationX:0,y:-self.font.lineHeight)
                    outgoing?.alpha=0
                    incoming?.frame=CGRect(origin:.zero,size:to.size)
                    incoming?.transform = .identity;incoming?.alpha=1
                }
            }
        }
        animator.addCompletion { [weak self,weak animator] _ in
            guard let self,self.transition === animator else{return}
            self.cancelTransition()
        }
        transition=animator;animator.startAnimation()
    }
    private func frames(for string:String)->[CGRect] {
        let line=CTLineCreateWithAttributedString(NSAttributedString(string:string,attributes:[.font:font!]))
        let width=CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil))
        return Array(string).indices.map {i in
            let x=CTLineGetOffsetForStringIndex(line,i,nil)
            let next=CTLineGetOffsetForStringIndex(line,i+1,nil)
            return CGRect(x:(bounds.width-width)/2+x,y:0,width:next-x,height:bounds.height)
        }
    }
    private func cancelTransition() {
        transition?.stopAnimation(true);transition=nil
        columns.forEach {$0.removeFromSuperview()};columns.removeAll(keepingCapacity:true)
        hidesBaseText=false;setNeedsDisplay()
    }
    override func drawText(in rect:CGRect) {if !hidesBaseText {super.drawText(in:rect)}}
}

