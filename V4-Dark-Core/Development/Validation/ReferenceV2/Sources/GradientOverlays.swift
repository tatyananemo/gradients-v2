import SwiftUI

struct PercentCenterMask: View {
    let isDarkTheme: Bool
    let gradientColor: GradientColorPreset
    let centerMaskFlow: CGFloat
    let centerMaskBreath: CGFloat
    let counterProgress: CGFloat
    let renderedProgress: CGFloat
    let elapsed: TimeInterval

    var body: some View {
        if isDarkTheme {
            ZStack {
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.black.opacity(0.86),
                                Color.black.opacity(0.72 + centerMaskFlow * 0.10),
                                gradientColor.darkMaskTint.opacity(0.34 + renderedProgress * 0.12),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 12,
                            endRadius: 136
                        )
                    )
                    .frame(
                        width: 252 + counterProgress * 20,
                        height: 118 + counterProgress * 8
                    )
                    .scaleEffect(x: darkBlobScaleX, y: darkBlobScaleY)
                    .offset(x: darkBlobDriftX, y: darkBlobDriftY)
                    .blur(radius: 38)
                    .modifier(V2CounterExclusion(enabled: gradientColor == .yellow))

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                gradientColor.darkMaskTint.opacity(0.46),
                                Color.black.opacity(0.46),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 106
                        )
                    )
                    .frame(
                        width: 204 + counterProgress * 14,
                        height: 92 + counterProgress * 6
                    )
                    .scaleEffect(x: darkInnerBlobScaleX, y: darkInnerBlobScaleY)
                    .offset(x: -darkBlobDriftX * 0.62, y: darkBlobDriftY * 0.48)
                    .blur(radius: 30)
                    .modifier(V2CounterExclusion(enabled: gradientColor == .yellow))
                    .blendMode(.multiply)

                Ellipse()
                    .fill(gradientColor.darkMaskTint.opacity(0.22))
                    .frame(
                        width: 226 + counterProgress * 18,
                        height: 78 + counterProgress * 5
                    )
                    .scaleEffect(x: darkRibbonScaleX, y: darkRibbonScaleY)
                    .offset(x: darkBlobDriftX * 0.34, y: -4 + darkBlobDriftY * 0.34)
                    .blur(radius: 42)
                    .modifier(V2CounterExclusion(enabled: gradientColor == .yellow))
                    .blendMode(.screen)
            }
            .scaleEffect(centerMaskBreath)
            .offset(y: -18)
            .allowsHitTesting(false)
        }
    }

    private var darkBlobDriftX: CGFloat {
        CGFloat(sin(elapsed * 0.34 + 0.7)) * 10
    }

    private var darkBlobDriftY: CGFloat {
        CGFloat(cos(elapsed * 0.27 + 1.3)) * 5
    }

    private var darkBlobScaleX: CGFloat {
        1.04 + CGFloat(sin(elapsed * 0.22)) * 0.055
    }

    private var darkBlobScaleY: CGFloat {
        0.94 + CGFloat(cos(elapsed * 0.19 + 0.8)) * 0.045
    }

    private var darkInnerBlobScaleX: CGFloat {
        0.98 + CGFloat(cos(elapsed * 0.25 + 2.2)) * 0.050
    }

    private var darkInnerBlobScaleY: CGFloat {
        1.02 + CGFloat(sin(elapsed * 0.21 + 1.8)) * 0.050
    }

    private var darkRibbonScaleX: CGFloat {
        1.06 + CGFloat(cos(elapsed * 0.18 + 0.4)) * 0.060
    }

    private var darkRibbonScaleY: CGFloat {
        0.82 + CGFloat(sin(elapsed * 0.24 + 2.7)) * 0.040
    }

}

private struct OptionalDistortionModifier: ViewModifier {
    let isActive: Bool
    let shader: Shader
    let maxSampleOffset: CGSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content
                .distortionEffect(shader, maxSampleOffset: maxSampleOffset)
        } else {
            content
        }
    }
}

extension View {
    func optionalDistortion(_ isActive: Bool, _ shader: Shader, maxSampleOffset: CGSize) -> some View {
        modifier(
            OptionalDistortionModifier(
                isActive: isActive,
                shader: shader,
                maxSampleOffset: maxSampleOffset
            )
        )
    }
}

private struct V2MaskUniformsKey: EnvironmentKey { static let defaultValue:[Float]=[] }
extension EnvironmentValues {
 var v2MaskUniforms:[Float] {get{self[V2MaskUniformsKey.self]} set{self[V2MaskUniformsKey.self]=newValue}}
}
struct V2CaptionFrameKey:PreferenceKey {
 static var defaultValue:CGRect = .zero
 static func reduce(value:inout CGRect,nextValue:()->CGRect){value=nextValue()}
}
private struct V2CounterExclusion:ViewModifier {
 let enabled:Bool
 @Environment(\.v2MaskUniforms) private var uniforms
 @ViewBuilder func body(content:Content)->some View {
  if enabled && uniforms.count>=28 {
   content.mask { GeometryReader { proxy in
    let rect=proxy.frame(in:.global)
    let sx=max(rect.width/max(proxy.size.width,1),0.001)
    let sy=max(rect.height/max(proxy.size.height,1),0.001)
    Rectangle().fill(.white)
     .frame(width:CGFloat(uniforms[0])/sx,height:CGFloat(uniforms[1])/sy)
     .colorEffect(ShaderLibrary.v2ReadabilityMask(.float2(0,0),.float2(sx,sy),.floatArray(uniforms)))
     .offset(x:-rect.minX/sx,y:-rect.minY/sy)
   }}
  }else{content}
 }
}
