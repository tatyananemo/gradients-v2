#include <metal_stdlib>
using namespace metal;

// Exact team RGBA palette, shared by both Yellow themes and their interaction light.
constant float4 yellowDeepColor = float4(1.0, 0.4, 0.0, 1.0);
constant float4 yellowMidColor = float4(1.0, 0.55, 0.0, 1.0);
constant float4 yellowHotColor = float4(1.0, 0.7, 0.0, 1.0);
constant float3 yellowLightAccent = float3(1.0, 221.0 / 255.0, 45.0 / 255.0); // #FFDD2D

// Approximate display luminance, used only to balance Yellow Dark's light
// against the established blue. A scalar gain preserves the warm hue.
float3 balanceYellowDarkLight(float3 warm, float3 reference) {
    const float3 luminanceWeights = float3(0.2126, 0.7152, 0.0722);
    float warmLuminance = dot(pow(warm, float3(2.2)), luminanceWeights);
    float referenceLuminance = dot(pow(reference, float3(2.2)), luminanceWeights);
    float gain = pow(min(referenceLuminance / max(warmLuminance, 0.0001), 1.0), 1.0 / 2.2);
    return warm * gain;
}

struct LayerState {
    float2 pos;
    float2 dim;
    float opacity;
    float blur;
};

// MARK: - Utils

float hashLiquid(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

float smootherLiquid(float x) {
    x = clamp(x, 0.0, 1.0);
    return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

float segmentEase(float value, float start, float end) {
    return smootherLiquid((value - start) / max(end - start, 0.0001));
}

// Shared tangents keep the travelling band moving through its key positions.
float bandMotion(float from, float to, float fromSlope, float toSlope, float t, float span) {
    float t2 = t * t;
    float t3 = t2 * t;
    return (2.0 * t3 - 3.0 * t2 + 1.0) * from +
        (t3 - 2.0 * t2 + t) * span * fromSlope +
        (-2.0 * t3 + 3.0 * t2) * to +
        (t3 - t2) * span * toSlope;
}

float3 yellowHeatColor(float energy) {
    float3 warm = mix(yellowDeepColor.rgb, yellowMidColor.rgb, smoothstep(0.04, 0.55, energy));
    return mix(warm, yellowHotColor.rgb, smoothstep(0.22, 1.10, energy));
}

float interactionLightField(float2 uv, float aspect, device const float *segments, int count) {
    float field = 0.0;
    float2 p = uv * float2(aspect, 1.0);
    for (int i = 0; i + 5 < count; i += 6) {
        float age = segments[i + 4];
        float life = 1.0 - smootherLiquid(age / 1.8);
        float lift = age * 0.055;
        float2 a = float2(segments[i] * aspect, segments[i + 1] - lift);
        float2 b = float2(segments[i + 2] * aspect, segments[i + 3] - lift);
        float2 radii = float2(0.057 + age * 0.007, 0.065 + age * 0.016);
        // Reject distant pixels before evaluating the soft swept field.
        if (any(p < min(a, b) - radii * 3.0) || any(p > max(a, b) + radii * 3.0)) continue;
        float2 path = b - a;
        float projection = clamp(dot(p - a, path) / max(dot(path, path), 0.000001), 0.0, 1.0);
        float2 delta = (p - mix(a, b, projection)) / radii;
        float softArea = exp(-dot(delta, delta));
        field += softArea * life * segments[i + 5] * 0.54;
    }
    return field;
}

float interp4(float a, float b, float c, float d, float p) {
    p = clamp(p, 0.0, 1.0);

    if (p <= 0.35) {
        return mix(a, b, smootherLiquid(p / 0.35));
    }

    if (p <= 0.75) {
        return mix(b, c, smootherLiquid((p - 0.35) / 0.40));
    }

    return mix(c, d, smootherLiquid((p - 0.75) / 0.25));
}

float interpKeys(float k0, float k1, float k2, float k3, float progress) {
    if (progress <= 0.30) {
        return mix(k0, k1, smootherLiquid((progress - 0.10) / 0.24));
    }

    if (progress <= 0.60) {
        return mix(k1, k2, smootherLiquid((progress - 0.24) / 0.42));
    }

    return mix(k2, k3, smootherLiquid((progress - 0.52) / 0.36));
}

float2 interp4v(float2 a, float2 b, float2 c, float2 d, float p) {
    return float2(
        interp4(a.x, b.x, c.x, d.x, p),
        interp4(a.y, b.y, c.y, d.y, p)
    );
}

LayerState makeState(
    float2 p0, float2 p1, float2 p2, float2 p3,
    float2 d0, float2 d1, float2 d2, float2 d3,
    float o0, float o1, float o2, float o3,
    float b0, float b1, float b2, float b3,
    float progress
) {
    LayerState s;

    s.pos = interp4v(p0, p1, p2, p3, progress);
    s.dim = interp4v(d0, d1, d2, d3, progress);
    s.opacity = interp4(o0, o1, o2, o3, progress);
    s.blur = interp4(b0, b1, b2, b3, progress);

    return s;
}

float localY(float2 p, LayerState s) {
    return clamp((p.y - s.pos.y) / max(s.dim.y, 1.0), 0.0, 1.0);
}

// MARK: - SDF shapes

float trapezoidSDF(
    float2 p,
    LayerState s,
    float leftTop,
    float rightTop,
    float leftBottom,
    float rightBottom
) {
    float2 safeDim = float2(max(s.dim.x, 1.0), max(s.dim.y, 1.0));
    float2 q = (p - s.pos) / safeDim;

    float l = mix(leftTop, leftBottom, q.y);
    float r = mix(rightTop, rightBottom, q.y);

    float left = (q.x - l) * s.dim.x;
    float right = (r - q.x) * s.dim.x;
    float top = q.y * s.dim.y;
    float bottom = (1.0 - q.y) * s.dim.y;

    return min(min(left, right), min(top, bottom));
}

float rectSDF(float2 p, LayerState s) {
    float2 safeDim = float2(max(s.dim.x, 1.0), max(s.dim.y, 1.0));
    float2 q = (p - s.pos) / safeDim;

    float left = q.x * s.dim.x;
    float right = (1.0 - q.x) * s.dim.x;
    float top = q.y * s.dim.y;
    float bottom = (1.0 - q.y) * s.dim.y;

    return min(min(left, right), min(top, bottom));
}

float svgGradientAlpha(
    float2 p,
    LayerState s,
    float blueY,
    float transparentY
) {
    float y = localY(p, s);

    if (blueY > transparentY) {
        return smoothstep(transparentY, blueY, y);
    } else {
        return 1.0 - smoothstep(blueY, transparentY, y);
    }
}

float softLayerAlpha(float sdf, float blur) {
    // Более мягкие края liquid-слоёв.
    float softness = max(24.0, blur * 0.70);
    return smoothstep(-softness, softness, sdf);
}

// MARK: - Layer fields

float blueTrapField(
    float2 p,
    LayerState s,
    float leftTop,
    float rightTop,
    float leftBottom,
    float rightBottom,
    float blueY,
    float transparentY,
    float strength
) {
    float sdf = trapezoidSDF(
        p,
        s,
        leftTop,
        rightTop,
        leftBottom,
        rightBottom
    );

    float shape = softLayerAlpha(sdf, s.blur);
    float grad = svgGradientAlpha(p, s, blueY, transparentY);

    return shape * grad * s.opacity * strength;
}

float whiteTrapField(
    float2 p,
    LayerState s,
    float leftTop,
    float rightTop,
    float leftBottom,
    float rightBottom,
    float strength
) {
    float sdf = trapezoidSDF(
        p,
        s,
        leftTop,
        rightTop,
        leftBottom,
        rightBottom
    );

    return softLayerAlpha(sdf, s.blur) * s.opacity * strength;
}

float whiteRectField(float2 p, LayerState s, float strength) {
    return softLayerAlpha(rectSDF(p, s), s.blur) * s.opacity * strength;
}

// MARK: - Blend approximations

float3 plusDarkerApprox(float3 backdrop, float3 source, float alpha) {
    alpha = clamp(alpha, 0.0, 1.0);
    float3 blended = max(float3(0.0), backdrop + source - float3(1.0));
    return mix(backdrop, blended, alpha);
}

float3 plusLighterApprox(float3 backdrop, float3 source, float alpha) {
    alpha = clamp(alpha, 0.0, 1.0);
    float3 blended = min(float3(1.0), backdrop + source);
    return mix(backdrop, blended, alpha);
}

// MARK: - Main shader

// REGRESSION LOCK: CURRENT Blue Dark is the immutable visual reference.
// - Theme-specific Light/Yellow fixes must leave its output pixel-identical.
// - Dark Blue output and both Dark contact paths remain frozen.
// - Yellow Dark main/contact mapping is restored from the accepted checkpoint.
// - Light reuses Dark's two-band field and contact partition; palette response
//   changes alone. No added halo, offset contours or optical/RGB double application.
// - Zero wave restores the original Light main palette exactly.
float3 yellowDarkDensityPalette(float density) {
    // ONE continuous palette for main, free wave and their density union.
    // Low/middle density stays orange/brown; yellow is never progress-gated.
    float brightness = 1.0 - exp(-3.0 * density);
    float hue = 1.0 - exp(-6.0 * density * density);
    return mix(yellowDeepColor.rgb, yellowLightAccent, hue) * brightness;
}

// Dark's additive field union and overlap, before any theme color response.
// Alpha is the existing idle density; no theme participates in this calculation.
struct IdleContact {
    float main;
    float idle;
    float coverage;
    float intersection;
    float frontReaction;
    float reactedMain;
    float freeIdle;
    float reactedDensity;
};

IdleContact sharedIdleContact(float mainDensity, float idleDensity) {
    IdleContact contact;
    contact.main = mainDensity;
    contact.idle = idleDensity;
    contact.coverage = clamp(mainDensity, 0.0, 1.0);
    contact.intersection = contact.coverage * idleDensity;
    // Partition Dark's existing additive union at the MAIN front. A filled
    // interior has no boundary left to move; only its wave pigment changes.
    // Both densities retain the same union, M+W, without a second idle layer.
    contact.frontReaction = contact.intersection * (1.0 - contact.coverage);
    contact.reactedMain = mainDensity + contact.frontReaction;
    contact.freeIdle = idleDensity - contact.frontReaction;
    contact.reactedDensity = mainDensity + idleDensity;
    return contact;
}

float lightIdleWaveDensity(float2 position, float2 size, float activity, float time, float waveStrength);
float idleWaveDensity(float2 position, float2 size, float activity, float time, float waveStrength);
half4 idleWaveColor(float density, float themeStrength, float gradientColorIndex);
half4 acceptedYellowDarkWave(float density);
half4 qaHistoricalYellowDarkWave(float density);
half4 qaHistoricalYellowDarkContact(half4 color, half4 wave, float gradientColorIndex, float coverage);
half4 restoredYellowDarkContact(half4 color, half4 wave, float gradientColorIndex, float coverage);
half4 blendDarkIdle(half4 color, half4 wave, IdleContact contact, float gradientColorIndex);
half4 blendLightIdle(half4 color, half4 wave, IdleContact contact, float gradientColorIndex, float3 transmission);
float3 correctedLightPigment(float density, float gradientColorIndex, float3 transmission) {
    // Accepted Light absorption curve: white at zero density, continuously
    // approaching the existing saturated pigment without a coverage threshold.
    return pow(max(transmission, float3(0.0001)), float3(density));
}
half4 correctedLightIdle(half4 color, half4 wave, IdleContact contact, float gradientColorIndex, float3 transmission);

// Collision support uses the two existing wave ridges. Their diffuse halo is
// light in the background, not a surface that can push the liquid boundary.
__attribute__((noinline))
float lightContactRidgeDensity(float2 position, float2 size, float activity, float time, float waveStrength) {
    float2 p = position / max(size, float2(1.0)) * float2(375.0, 812.0);
    float raw = fract(time / 3.0);
    float cycle = smootherLiquid(raw);
    float visibility = smoothstep(0.02, 0.11, raw) *
        (1.0 - smoothstep(0.88, 1.0, raw)) * smootherLiquid(clamp(activity, 0.0, 1.0));
    float width = mix(72.0, 420.0, cycle);
    float thickness = mix(19.0, 42.0, cycle);
    float dx = p.x - 187.5;
    float d = p.y - mix(-110.0, 925.0, cycle) - dx * dx / max(width * 1.72, 1.0);
    float primary = exp(-pow(d / thickness, 2.0)) * exp(-pow(dx / width, 2.0));
    float secondary = exp(-pow((d + 72.0) / (thickness * 1.35), 2.0)) *
        exp(-pow(dx / (width * 1.18), 2.0)) * 0.32;
    return clamp(clamp(primary + secondary, 0.0, 1.0) * visibility *
        clamp(waveStrength, 0.3, 2.0) * 0.84, 0.0, 0.86);
}

__attribute__((noinline))
float lightFrontContactReaction(float mainDensity, float ridgeDensity) {
    IdleContact collision = sharedIdleContact(mainDensity, ridgeDensity);
    // Compact support on the visible MAIN shoulder, not its filled interior
    // or Gaussian background. Values are sampled BEFORE any displacement.
    float boundary = smoothstep(0.10, 0.22, collision.coverage) *
        (1.0 - smoothstep(0.38, 0.60, collision.coverage));
    // Gaussian tails below visible ridge coverage cannot initiate a collision.
    float touching = smoothstep(0.025, 0.08, ridgeDensity);
    return 4.0 * collision.frontReaction * boundary * touching;
}


__attribute__((noinline))
half4 correctedThemesBackground(
    float2 position,
    half4 color,
    float2 size,
    float progress,
    float tapPulse,
    float2 tapPoint,
    float2 previousTouchPoint,
    float swipePulse,
    float swipeStrength,
    float time,
    float progressSpeed,
    float fillGain,
    float waveStrength,
    float waveSpread,
    float topBloom,
    float whiteCore,
    float blueDepth,
    float dragWave,
    float shockStrength,
    float shockInteraction,
    float shockTrail,
    float waveCount,
    float themeStrength,
    float gradientColorIndex,
    float idleActivity,
    float idleTime,
    device const float *interactionSegments,
    int interactionFloatCount
) {
    progress = clamp(progress, 0.0, 1.0);
    progressSpeed = clamp(progressSpeed, 0.0, 10.0);
    fillGain = clamp(fillGain, 0.0, 10.0);
    waveStrength = clamp(waveStrength, 0.0, 10.0);
    waveSpread = clamp(waveSpread, 0.0, 10.0);
    topBloom = clamp(topBloom, 0.0, 10.0);
    whiteCore = clamp(whiteCore, 0.0, 10.0);
    blueDepth = clamp(blueDepth, 0.0, 10.0);
    dragWave = clamp(dragWave, 0.0, 1.0);
    swipePulse = smootherLiquid(clamp(swipePulse, 0.0, 1.0));
    swipeStrength = clamp(swipeStrength, 0.0, 1.0);
    shockStrength = clamp(shockStrength, 0.0, 10.0);
    shockInteraction = clamp(shockInteraction, 0.0, 10.0);
    shockTrail = clamp(shockTrail, 0.0, 10.0);
    waveCount = clamp(round(waveCount), 0.0, 10.0);
    themeStrength = clamp(themeStrength, 0.0, 1.0);
    gradientColorIndex = clamp(round(gradientColorIndex), 0.0, 4.0);
    float isBluePreset = 1.0 - step(0.5, abs(gradientColorIndex));
    float isYellowPreset = 1.0 - step(0.5, abs(gradientColorIndex - 3.0));

    float2 design = float2(375.0, 812.0);
    float2 safeSize = float2(max(size.x, 1.0), max(size.y, 1.0));

    float2 p = float2(
        position.x / safeSize.x * design.x,
        position.y / safeSize.y * design.y
    );

    float2 uv = position / safeSize;

    float3 white = float3(1.0);

    // Blue gradient shares the light idle-wave palette: #1A8CFF.
    float3 cyan = float3(0.10, 0.55, 1.0);
    float3 aqua = float3(0.10, 0.55, 1.0);
    float3 blue = float3(0.10, 0.55, 1.0);
    float3 deepBlue = float3(0.10, 0.55, 1.0);
    float3 electric = float3(0.10, 0.55, 1.0);
    float3 targetBlue = float3(0.10, 0.55, 1.0);

    if (gradientColorIndex < 2.5 && gradientColorIndex > 1.5) {
        cyan = float3(0.62, 0.46, 1.0);
        aqua = float3(0.43, 0.28, 0.94);
        blue = float3(0.22, 0.12, 0.72);
        deepBlue = float3(0.09, 0.05, 0.34);
        electric = float3(0.82, 0.58, 1.0);
        targetBlue = float3(0.56, 0.42, 1.0);
    } else if (gradientColorIndex < 3.5 && gradientColorIndex > 2.5) {
        cyan = mix(yellowHotColor.rgb, white, 0.32);
        aqua = yellowHotColor.rgb;
        blue = yellowMidColor.rgb;
        deepBlue = yellowDeepColor.rgb;
        electric = yellowHotColor.rgb;
        targetBlue = yellowMidColor.rgb;
    } else if (gradientColorIndex > 3.5) {
        cyan = float3(1.0, 0.46, 0.68);
        aqua = float3(0.94, 0.26, 0.58);
        blue = float3(0.60, 0.14, 0.52);
        deepBlue = float3(0.26, 0.05, 0.20);
        electric = float3(1.0, 0.68, 0.88);
        targetBlue = float3(1.0, 0.42, 0.66);
    }

    float3 waveMid = mix(targetBlue, aqua, 0.24);
    float3 waveDeep = mix(deepBlue, targetBlue, 0.18);
    float3 waveGlass = mix(cyan, white, 0.68);
    float3 waveEdge = mix(electric, cyan, 0.36);

    // --------------------------------------------------
    // Idle shockwave
    // --------------------------------------------------

    float idleWaveActivity = smootherLiquid(swipeStrength);
    float idleWaveFade = mix(0.92, 0.78, smoothstep(0.92, 1.0, progress)) * idleWaveActivity;

    float idlePeriod = 3.0;
    float idleCycleRaw = fract(time / idlePeriod);
    float idleCycle = smootherLiquid(idleCycleRaw);

    float idleWaveVisibility =
        smoothstep(0.02, 0.11, idleCycleRaw) *
        (1.0 - smoothstep(0.88, 1.0, idleCycleRaw)) *
        idleWaveFade;

    float idleWaveY = mix(-110.0, 925.0, idleCycle);

    float idleWidth = mix(72.0, 420.0, idleCycle);
    float idleThickness = mix(19.0, 42.0, idleCycle);

    float idleDx = p.x - 187.5;

    float idleArcY =
        idleWaveY +
        (idleDx * idleDx) / max(idleWidth * 1.72, 1.0);

    float idleWaveDist = p.y - idleArcY;

    float idleMainWave =
        exp(-pow(idleWaveDist / idleThickness, 2.0)) *
        exp(-pow(idleDx / idleWidth, 2.0));

    float idleSecondWave =
        exp(-pow((idleWaveDist + 72.0) / (idleThickness * 1.35), 2.0)) *
        exp(-pow(idleDx / (idleWidth * 1.18), 2.0)) *
        0.42;

    float idleThirdWave =
        exp(-pow((idleWaveDist + 132.0) / (idleThickness * 1.75), 2.0)) *
        exp(-pow(idleDx / (idleWidth * 1.32), 2.0)) *
        0.20;

    float idleConeGlow =
        exp(-pow((p.y - idleWaveY) / 180.0, 2.0)) *
        exp(-pow(idleDx / max(idleWidth * 1.18, 1.0), 2.0)) *
        0.18;

    float idleWaveEnergy =
        clamp(
            idleMainWave +
            idleSecondWave +
            idleThirdWave +
            idleConeGlow,
            0.0,
            1.0
        ) *
        idleWaveVisibility *
        waveStrength;

    // --------------------------------------------------
    // Continuous upward motion
    // --------------------------------------------------

    // Use the original gradient motion curve for every palette and theme.
    float baseRise = progress * (0.42 + 0.58 * progress);
    float smoothRise = smootherLiquid(progress);
    float rise = mix(baseRise, smoothRise, 0.34);
    float finalLiftBoost = segmentEase(progress, 0.74, 1.00);
    float lateLiftBoost = segmentEase(progress, 0.88, 1.00);

    float circleGrowth = smootherLiquid(progress);

    float2 center = float2(187.5, 406.0);
    float circleAppear = smoothstep(0.025, 0.12, progress * (0.70 + progressSpeed * 3.0));
    float circleRadius = mix(74.0, 178.0, circleGrowth) * mix(0.92, 1.08, waveSpread - 0.5);

    float bottomCleanProgress = segmentEase(progress, 0.42, 1.00);
    float topCapProgress = segmentEase(progress, 0.82, 1.00);
    float topReservoirProgress = segmentEase(progress, 0.58, 1.00);

    float completionBloom = segmentEase(progress, 0.96, 1.00);
    float completed = smoothstep(0.995, 1.0, progress);

    float globalLift =
        mix(0.0, 1380.0, rise) +
        260.0 * finalLiftBoost +
        540.0 * lateLiftBoost;

    float initialDrop = 350.0 * (1.0 - rise);

    float finalBlur = segmentEase(progress, 0.70, 1.00);
    float completionMistProgress = segmentEase(progress, 0.84, 1.00);

    float completionFlash = 0.0;

    // Позже начинаем растворять градиент.
    float lateTransparency = segmentEase(progress, 0.90, 1.00);

    float mainFinalFade = mix(1.0, 0.62, lateTransparency);
    float rimFinalFade = mix(1.0, 0.44, lateTransparency);
    float finalFade = mainFinalFade;

    // Делаем градиент более вытянутым в первой половине
    // и чуть компактнее к финалу, но мягче, чем раньше.
    float shrinkAfterHalf = segmentEase(progress, 0.64, 1.00);

    float stretchFactor = mix(
        0.30,
        0.64,
        shrinkAfterHalf
    );

    float2 pStretched = float2(
        p.x,
        406.0 + (p.y - 406.0) * stretchFactor
    );

    // --------------------------------------------------
    // Bottom clearing mask
    // --------------------------------------------------

    float clearEdgeY = mix(1060.0, 225.0, bottomCleanProgress);
    float clearFeather = mix(205.0, 360.0, bottomCleanProgress);

    float clearWave =
        24.0 * sin(p.x * 0.018 + time * 0.50 + rise * 2.0) +
        15.0 * sin(p.x * 0.041 - time * 0.36 + rise * 4.0) +
        8.0  * sin((p.x + p.y) * 0.020 + time * 0.22);

    float bottomClear = smoothstep(
        clearEdgeY - clearFeather,
        clearEdgeY + clearFeather,
        p.y + clearWave
    );

    float bottomOnly = smoothstep(0.38, 1.0, uv.y);
    bottomClear *= bottomOnly;

    // --------------------------------------------------
    // Organic liquid reveal edge
    // --------------------------------------------------

    float revealEdgeY = mix(910.0, -1450.0, rise);

    // Граница сверху и снизу мягче.
    float revealFeather = mix(
        140.0,
        360.0 + 340.0 * finalBlur,
        rise
    );

    float revealWaveA =
        34.0 * sin(p.x * 0.013 + time * 0.42 + rise * 2.1);

    float revealWaveB =
        18.0 * sin(p.x * 0.031 - time * 0.56 + rise * 3.4);

    float revealWaveC =
        9.0 * sin(p.x * 0.071 + time * 0.33 - rise * 1.6);

    float domainWarp =
        13.0 * sin((p.x + p.y) * 0.018 + time * 0.28) +
        7.0  * sin((p.x - p.y) * 0.026 - time * 0.31);

    float blob1 =
        42.0 *
        exp(-pow((p.x - 86.0) / 72.0, 2.0)) *
        sin(time * 0.37 + rise * 2.4);

    float blob2 =
        36.0 *
        exp(-pow((p.x - 206.0) / 88.0, 2.0)) *
        sin(time * 0.29 + 1.7 + rise * 2.9);

    float blob3 =
        30.0 *
        exp(-pow((p.x - 318.0) / 76.0, 2.0)) *
        sin(time * 0.34 + 3.1 + rise * 2.2);

    float revealWave =
        revealWaveA +
        revealWaveB +
        revealWaveC +
        domainWarp +
        blob1 +
        blob2 +
        blob3;

    float edgeChaos = mix(
        0.72,
        1.0,
        smoothstep(0.12, 0.65, progress)
    );

    float liquidEdgeY = revealEdgeY - revealWave * edgeChaos;

    float bottomReveal = smoothstep(
        liquidEdgeY - revealFeather,
        liquidEdgeY + revealFeather,
        p.y
    );

    float revealEdgeDist = abs(p.y - liquidEdgeY);

    float revealEdgeGlow =
        exp(-revealEdgeDist / 38.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.22 *
        finalFade;

    float tensionCore =
        exp(-revealEdgeDist / 15.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.18 *
        finalFade;

    float tensionShadow =
        exp(-abs((p.y - liquidEdgeY) - 26.0) / 28.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.10 *
        finalFade;

    float liquidRimLine =
        exp(-revealEdgeDist / 8.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        finalFade;

    // --------------------------------------------------
    // Idle / completion breathing
    // --------------------------------------------------

    float idleEnergy = 1.0 - smoothstep(0.02, 0.22, progress);

    float idleVertical =
        idleEnergy *
        (
            18.0 * sin(time * 0.46) +
            9.0  * sin(time * 0.83)
        );

    float horizontalDrift = 0.0;

    float baseShiftY = globalLift - initialDrop + idleVertical;

    float2 pGlobal = pStretched + float2(horizontalDrift, baseShiftY);

    // --------------------------------------------------
    // Refraction + tap push + flow pull
    // --------------------------------------------------

    float lensDist = distance(p, center);

    float refractionZone =
        exp(-pow((lensDist - circleRadius) / 42.0, 2.0)) *
        circleAppear;

    float2 refractDir = normalize(p - center + float2(0.001, 0.001));
    float2 refractionWarp = refractDir * refractionZone * 10.0;

    float2 tapPxDesign = float2(
        tapPoint.x * design.x,
        tapPoint.y * design.y
    );

    float2 touchDeltaDesign = p - tapPxDesign;
    float tapDistDesign = length(touchDeltaDesign);
    float shockActive = smoothstep(0.04, 1.0, dragWave) * waveStrength * shockStrength;
    float shockAge = clamp((1.0 - tapPulse) / max(shockTrail, 0.30), 0.0, 1.0);
    float shockSide = touchDeltaDesign.x >= 0.0 ? 1.0 : -1.0;
    float travelingPhase = time * (3.8 + 1.4 * shockInteraction);

    float rippleAmplitude = 38.0 * shockStrength;
    float rippleEnvelope = smoothstep(0.01, 0.46, dragWave);
    float waveProgress = clamp(1.0 - tapPulse, 0.0, 1.0);
    float safeWaveSpread = max(waveSpread, 0.001);
    float safeShockTrail = max(shockTrail, 0.001);
    float waveFrontRadius = 24.0 + waveProgress * 250.0 * shockTrail;
    float ringSpacing = 46.0 * waveSpread;
    float ringWidth = max(25.0 * waveSpread, 1.0);
    float finiteRipple = 0.0;

    // Fixed upper bound keeps this predictable on the GPU while allowing 0...10 waves.
    for (int waveIndex = 0; waveIndex < 10; waveIndex++) {
        float index = float(waveIndex);
        float ringRadius = waveFrontRadius - ringSpacing * index;
        float ringEnabled = step(index + 0.5, waveCount) * smoothstep(2.0, 16.0, ringRadius);
        float ring =
            exp(-pow((tapDistDesign - ringRadius) / ringWidth, 2.0)) -
            0.34 * exp(-pow((tapDistDesign - ringRadius + ringWidth * 0.72) / (ringWidth * 1.28), 2.0));
        finiteRipple += ring * ringEnabled * (1.0 - index * 0.075);
    }
    float rippleFade = exp(-waveProgress * 1.35 / max(shockTrail, 0.30));
    float rippleAmount =
        rippleAmplitude *
        finiteRipple *
        rippleEnvelope *
        rippleFade;
    float2 rippleDir = normalize(touchDeltaDesign + float2(0.001, 0.001));
    float2 shadertoyRippleWarp = rippleAmount * rippleDir;
    float shadertoyRippleLight = rippleAmount / max(rippleAmplitude, 1.0);

    // A continuous, soft water response that remains visible while the finger moves.
    float localWaterPressure =
        exp(-pow(tapDistDesign / max(92.0 * waveSpread, 1.0), 2.0)) *
        rippleEnvelope;
    float localWaterWave =
        finiteRipple *
        rippleEnvelope *
        rippleFade;
    float2 localWaterWarp =
        rippleDir *
        (
            localWaterWave * (5.2 + 2.0 * shockStrength) +
            localWaterPressure * 2.8
        );

    float frontNoise =
        12.0 * sin(p.y * 0.018 + time * 2.1) +
        7.0 * sin(p.y * 0.034 - time * 1.4);

    float frontDist = abs(p.x - tapPxDesign.x + frontNoise);
    float primaryFront =
        exp(-pow(frontDist / max(mix(46.0, 82.0, waveSpread), 1.0), 2.0)) *
        shockActive;

    float secondaryFront =
        exp(-pow((frontDist - mix(42.0, 128.0 * shockTrail, shockAge)) / max(mix(104.0, 162.0, waveSpread), 1.0), 2.0)) *
        shockActive *
        (0.72 - 0.26 * shockAge);

    float screenRing =
        exp(-pow((tapDistDesign - mix(42.0, 310.0 * shockTrail, shockAge)) / max(172.0 * safeWaveSpread, 1.0), 2.0)) *
        shockActive *
        (0.38 + 0.62 * tapPulse);

    float diagonalAxis =
        dot(touchDeltaDesign, normalize(float2(0.58 * shockSide, 0.82))) +
        18.0 * sin(p.y * 0.020 + time * 1.9);

    float diagonalWake =
        exp(-pow(diagonalAxis / max(150.0 * safeWaveSpread, 1.0), 2.0)) *
        exp(-pow(touchDeltaDesign.x / max(420.0 * safeShockTrail, 1.0), 2.0)) *
        shockActive *
        (0.46 + 0.36 * tapPulse);

    float causticPulse =
        (0.5 + 0.5 * sin(tapDistDesign * 0.050 - travelingPhase * 1.7 + shockAge * 8.2)) *
        screenRing *
        shockActive *
        (0.64 + 0.36 * shockInteraction);

    float crossingFront =
        primaryFront * secondaryFront +
        screenRing * diagonalWake;

    float interferenceField =
        (0.5 + 0.5 * sin(tapDistDesign * 0.042 - travelingPhase * 1.35)) *
        (0.5 + 0.5 * sin((touchDeltaDesign.x * shockSide + touchDeltaDesign.y * 0.54) * 0.034 + travelingPhase)) *
        shockActive *
        shockInteraction;

    float selfCoupling =
        clamp(crossingFront * (0.72 + 0.46 * shockInteraction) + interferenceField * 0.44, 0.0, 1.8);

    float compositeShock =
        primaryFront * 0.54 +
        secondaryFront * 0.38 +
        screenRing * 0.34 +
        diagonalWake * 0.28 +
        causticPulse * 0.16 +
        selfCoupling * 0.30;

    float touchPush =
        exp(-pow(tapDistDesign * 0.0052, 2.0)) *
        tapPulse *
        shockActive;

    float2 tapDir = normalize(p - tapPxDesign + float2(0.001, 0.001));
    float2 frontDir = normalize(float2(shockSide, 0.16 * sin(p.y * 0.021 + time * 1.7)));
    float2 diagonalDir = normalize(float2(0.46 * shockSide, 0.72));
    float2 tapWarp =
        shadertoyRippleWarp * (0.58 + 0.16 * waveStrength) +
        localWaterWarp +
        tapDir * touchPush * 6.0 +
        frontDir * compositeShock * 7.0 +
        diagonalDir * (diagonalWake + selfCoupling * 0.38) * 3.5 +
        float2(0.0, -1.0) * (causticPulse + interferenceField * 0.24) * 2.0;

    float centerPull =
        exp(-pow((p.x - 187.5) / 140.0, 2.0));

    float verticalFlowPull =
        centerPull *
        segmentEase(progress, 0.18, 0.92) *
        34.0 *
        waveStrength;

    float2 flowWarp = refractionWarp + tapWarp;
    float2 liquidFlowWarp = float2(0.0, flowWarp.y);

    pGlobal += liquidFlowWarp * 0.82;
    pGlobal.y += verticalFlowPull;

    float backSpeed = mix(0.70, 0.78, completed);
    float mainSpeed = mix(1.00, 0.92, completed);
    float rimSpeed = mix(1.30, 1.10, completed);

    float2 pShape1Back = pStretched + float2(horizontalDrift * 0.30, baseShiftY * backSpeed * 0.82);
    float2 pShape2Back = pStretched + float2(horizontalDrift * 0.40, baseShiftY * backSpeed * 0.96);
    float2 pWave1Back  = pStretched + float2(horizontalDrift * 0.48, baseShiftY * backSpeed * 0.92);
    float2 pWave2Back  = pStretched + float2(horizontalDrift * 0.50, baseShiftY * backSpeed * 1.04);

    float2 pShape1 = pStretched + float2(horizontalDrift * 0.55, baseShiftY * mainSpeed * 0.95);
    float2 pShape2 = pStretched + float2(horizontalDrift * 0.80, baseShiftY * mainSpeed * 1.12);
    float2 pBgUp   = pStretched + float2(horizontalDrift * 0.30, baseShiftY * mainSpeed * 0.34);
    float2 pWave1  = pStretched + float2(horizontalDrift * 1.05, baseShiftY * mainSpeed * 1.00);
    float2 pWave2  = pStretched + float2(horizontalDrift * 0.95, baseShiftY * mainSpeed * 1.16);

    float2 pRim1 = pStretched + float2(horizontalDrift * 1.28, baseShiftY * rimSpeed * 1.22);
    float2 pRim2 = pStretched + float2(horizontalDrift * 1.10, baseShiftY * rimSpeed * 1.30);

    pShape1Back += liquidFlowWarp * 0.18;
    pShape2Back += liquidFlowWarp * 0.24;
    pWave1Back += liquidFlowWarp * 0.28;
    pWave2Back += liquidFlowWarp * 0.30;

    pShape1 += liquidFlowWarp * 0.50;
    pShape2 += liquidFlowWarp * 0.58;
    pWave1 += liquidFlowWarp * 0.72;
    pWave2 += liquidFlowWarp * 0.68;

    pRim1 += liquidFlowWarp * 0.95;
    pRim2 += liquidFlowWarp * 0.88;

    float2 deepWarp = float2(
        0.0,
        cos(p.x * 0.010 + time * 0.32) * 8.0
    );

    pShape1Back += deepWarp * 0.22;
    pShape2Back += deepWarp * 0.28;
    pWave1Back += deepWarp * 0.34;
    pWave2Back += deepWarp * 0.36;

    pShape1 += deepWarp * 0.52;
    pShape2 += deepWarp * 0.60;
    pWave1 += deepWarp * 0.78;
    pWave2 += deepWarp * 0.72;

    pRim1 += deepWarp * 1.05;
    pRim2 += deepWarp * 0.96;

    // --------------------------------------------------
    // States from specs
    // --------------------------------------------------

    LayerState anim_wave_1 = makeState(
        float2(-38.0, 647.0),
        float2(-238.0, 476.0),
        float2(-121.0, 411.0),
        float2(-117.0, 151.0),

        float2(454.0, 300.0),
        float2(851.0, 562.0),
        float2(619.0, 409.0),
        float2(611.0, 405.0),

        1.00, 0.70, 1.00, 1.00,
        64.0, 64.0, 120.0, 160.0,
        progress
    );

    LayerState anim_wave_2 = makeState(
        float2(-99.0, 364.0),
        float2(-99.0, 442.0),
        float2(-218.0, 197.0),
        float2(-106.0, -107.0),

        float2(556.0, 298.0),
        float2(573.0, 307.0),
        float2(875.0, 466.0),
        float2(589.0, 316.0),

        1.00, 1.00, 1.00, 1.00,
        128.0, 160.0, 120.0, 88.0,
        progress
    );

    LayerState bg_up_02 = makeState(
        float2(-50.0, 37.0),
        float2(-32.0, 37.0),
        float2(-50.0, 37.0),
        float2(-50.0, 37.0),

        float2(475.0, 787.0),
        float2(440.0, 787.0),
        float2(475.0, 787.0),
        float2(475.0, 787.0),

        0.10, 1.00, 1.00, 1.00,
        64.0, 120.0, 64.0, 64.0,
        progress
    );

    LayerState shape_2 = makeState(
        float2(0.0, 705.0),
        float2(-44.0, 856.0),
        float2(-67.0, 663.0),
        float2(-50.0, 702.0),

        float2(375.0, 251.0),
        float2(463.0, 309.0),
        float2(509.0, 340.0),
        float2(475.0, 317.0),

        0.60, 0.70, 0.20, 1.00,
        88.0, 88.0, 88.0, 88.0,
        progress
    );

    LayerState shape_1 = makeState(
        float2(-50.0, 308.0),
        float2(-24.0, 351.0),
        float2(11.0, 78.0),
        float2(-50.0, 308.0),

        float2(475.0, 787.0),
        float2(423.0, 701.0),
        float2(353.0, 585.0),
        float2(475.0, 787.0),

        1.00, 1.00, 0.40, 1.00,
        64.0, 64.0, 146.0, 65.0,
        progress
    );

    // --------------------------------------------------
    // Back liquid layer
    // --------------------------------------------------

    float backShape1 = blueTrapField(
        pShape1Back,
        shape_1,
        87.3259 / 475.0,
        379.735 / 475.0,
        0.0,
        1.0,
        709.291 / 787.0,
        17.4917 / 787.0,
        0.72 * blueDepth
    );

    float backShape2 = blueTrapField(
        pShape2Back,
        shape_2,
        68.9415 / 375.0,
        299.791 / 375.0,
        0.0,
        1.0,
        226.216 / 251.0,
        5.57866 / 251.0,
        0.62 * blueDepth
    );

    float backWave1 = blueTrapField(
        pWave1Back,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        0.72 * blueDepth
    );

    float backWave2 = blueTrapField(
        pWave2Back,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        0.78 * blueDepth
    );

    float backMass = backShape1 + backShape2 + backWave1 + backWave2;
    float backAlpha = 1.0 - exp(-backMass * 0.86);
    backAlpha = clamp(backAlpha * bottomReveal * finalFade, 0.0, 1.0);

    // --------------------------------------------------
    // Main liquid layer
    // --------------------------------------------------

    float shape1Field = blueTrapField(
        pShape1,
        shape_1,
        87.3259 / 475.0,
        379.735 / 475.0,
        0.0,
        1.0,
        709.291 / 787.0,
        17.4917 / 787.0,
        1.08 * blueDepth
    );

    float shape2Field = blueTrapField(
        pShape2,
        shape_2,
        68.9415 / 375.0,
        299.791 / 375.0,
        0.0,
        1.0,
        226.216 / 251.0,
        5.57866 / 251.0,
        0.96 * blueDepth
    );

    float bgUpField = blueTrapField(
        pBgUp,
        bg_up_02,
        0.0,
        1.0,
        87.3259 / 475.0,
        379.735 / 475.0,
        77.709 / 787.0,
        769.508 / 787.0,
        1.03 * blueDepth
    );

    float wave2Field = blueTrapField(
        pWave2,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        1.25 * blueDepth
    );

    float wave1Field = blueTrapField(
        pWave1,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        1.18 * blueDepth
    );

    float svgBlueMass =
        shape1Field +
        shape2Field +
        bgUpField +
        wave1Field +
        wave2Field;

    float mainAlpha = 1.0 - exp(-svgBlueMass * 1.28);
    mainAlpha = clamp(mainAlpha * bottomReveal * finalFade, 0.0, 1.0);

    // --------------------------------------------------
    // Front rim liquid layer
    // --------------------------------------------------

    float rimWave1 = blueTrapField(
        pRim1,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        1.05
    );

    float rimWave2 = blueTrapField(
        pRim2,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        0.98
    );

    float rimAlpha = clamp((rimWave1 + rimWave2) * bottomReveal * rimFinalFade, 0.0, 1.0);
    rimAlpha = smoothstep(0.22, 0.88, rimAlpha);

    float massBreath =
        1.0 +
        0.025 * sin(time * 0.72) +
        0.014 * sin(time * 1.13);

    mainAlpha = clamp(mainAlpha * massBreath, 0.0, 1.0);
    backAlpha = clamp(backAlpha * (1.0 + 0.018 * sin(time * 0.55 + 1.2)), 0.0, 1.0);
    rimAlpha = clamp(rimAlpha * (1.0 + 0.016 * sin(time * 0.80 + 2.1)), 0.0, 1.0);

    float lateAlphaFade = lateTransparency;

    mainAlpha *= mix(1.0, 0.54, lateAlphaFade);
    backAlpha *= mix(1.0, 0.48, lateAlphaFade);
    rimAlpha *= mix(1.0, 0.36, lateAlphaFade);

    // --------------------------------------------------
    // Liquid color model
    // --------------------------------------------------

    float flow =
        0.023 * sin(pGlobal.x * 0.030 + time * 0.75 + rise * 2.2) +
        0.016 * sin(pGlobal.x * 0.070 - time * 0.55 + rise * 3.7) +
        0.011 * sin((pGlobal.x + pGlobal.y) * 0.035 + time * 0.45);

    float liquidY = clamp(
        uv.y * 0.74 + 0.14 + flow - rise * 0.14,
        0.0,
        1.0
    );

    // --------------------------------------------------
    // Delayed blue color ramp
    // --------------------------------------------------

    float blueEmergence = segmentEase(progress, 0.40, 0.56);
    float deepBlueEmergence = segmentEase(progress, 0.54, 0.78);
    float earlySoftness = 1.0 - blueEmergence;

    float targetBluePhase =
        segmentEase(progress, 0.50, 0.62) *
        (1.0 - segmentEase(progress, 0.80, 0.94));

    float3 softAqua = mix(
        cyan,
        aqua,
        0.62
    );

    float3 softBlue = mix(
        aqua,
        targetBlue,
        0.46
    );

    float3 backColor = mix(
        softAqua,
        softBlue,
        smoothstep(0.16, 0.88, liquidY) * blueEmergence
    );

    backColor = mix(
        backColor,
        targetBlue,
        targetBluePhase * 0.72
    );

    backColor = mix(
        backColor,
        mix(targetBlue, deepBlue, 0.26),
        smoothstep(0.78, 1.0, liquidY) * deepBlueEmergence * 0.38
    );

    float3 mainColor = mix(
        cyan,
        aqua,
        smoothstep(0.02, 0.48, liquidY)
    );

    mainColor = mix(
        mainColor,
        softBlue,
        smoothstep(0.34, 0.78, liquidY) * blueEmergence
    );

    mainColor = mix(
        mainColor,
        targetBlue,
        smoothstep(0.44, 0.88, liquidY) * blueEmergence * 0.78
    );

    mainColor = mix(
        mainColor,
        targetBlue,
        targetBluePhase * 0.86
    );

    mainColor = mix(
        mainColor,
        mix(targetBlue, deepBlue, 0.22),
        smoothstep(0.78, 1.0, liquidY) * deepBlueEmergence * 0.42
    );

    mainColor = mix(
        mainColor,
        mix(cyan, aqua, 0.54),
        earlySoftness * 0.38
    );

    backColor = mix(
        backColor,
        mix(cyan, aqua, 0.46),
        earlySoftness * 0.32
    );

    float3 rimColor = mix(
        electric,
        cyan,
        smoothstep(0.0, 1.0, liquidY)
    );

    rimColor = mix(
        rimColor,
        mix(cyan, aqua, 0.52),
        earlySoftness * 0.28
    );

    rimColor = mix(
        rimColor,
        mix(targetBlue, cyan, 0.22),
        targetBluePhase * 0.56
    );

    float3 result = white;

    result = plusDarkerApprox(
        result,
        backColor,
        backAlpha * 0.72
    );

    result = plusDarkerApprox(
        result,
        mainColor,
        mainAlpha
    );

    result += rimColor * rimAlpha * 0.035;

    // --------------------------------------------------
    // Idle wave render
    // --------------------------------------------------

    float idleLuminanceBefore = dot(result, float3(0.299, 0.587, 0.114));

    float idleBlueOnWhite =
        idleWaveEnergy *
        smoothstep(0.56, 1.0, idleLuminanceBefore);

    float idleWhiteOnBlue =
        idleWaveEnergy *
        (1.0 - smoothstep(0.35, 0.88, idleLuminanceBefore));

    result = mix(
        result,
        min(result, waveMid),
        idleBlueOnWhite * 0.22
    );

    result += idleBlueOnWhite * waveDeep * 0.08;
    result += idleWhiteOnBlue * waveGlass * 0.14;
    result += idleWaveEnergy * waveEdge * 0.10;

    // --------------------------------------------------
    // Organic reveal edge glow + surface tension
    // --------------------------------------------------

    result += revealEdgeGlow * float3(0.25, 0.82, 1.0);
    result += revealEdgeGlow * float3(0.75, 1.00, 1.0) * 0.32;

    result += tensionCore * float3(0.56, 1.00, 1.0) * 0.34;

    result += liquidRimLine * float3(0.75, 1.0, 1.0) * 0.18;
    result += liquidRimLine * float3(0.10, 0.55, 1.0) * 0.08;

    result = plusDarkerApprox(
        result,
        deepBlue,
        tensionShadow * 0.18
    );

    // --------------------------------------------------
    // Surface glow
    // --------------------------------------------------

    float liquidAlpha = clamp(mainAlpha + backAlpha * 0.52, 0.0, 1.0);
    float surfaceEnergy = liquidAlpha * (1.0 - liquidAlpha);

    float surfaceGlow = smoothstep(0.08, 0.25, surfaceEnergy);

    result += surfaceGlow * float3(0.10, 0.56, 1.0) * 0.10 * finalFade;
    result += surfaceGlow * float3(0.56, 1.00, 1.0) * 0.045 * finalFade;

    // --------------------------------------------------
    // Bottom clearing
    // --------------------------------------------------

    float bottomClearPower = mix(
        0.38,
        0.68,
        bottomCleanProgress
    );

    result = plusLighterApprox(
        result,
        white,
        min(bottomClear * bottomClearPower, 0.68)
    );

    liquidAlpha *= (1.0 - bottomClear * 0.82);

    // --------------------------------------------------
    // Central white glass lens
    // --------------------------------------------------

    float circleSoftness = mix(
        38.0,
        92.0,
        circleGrowth
    );

    float angle = atan2(
        p.y - center.y,
        p.x - center.x
    );

    float circleNoiseFade = 1.0 - segmentEase(progress, 0.88, 1.00);

    float circleNoise =
        (
            4.2 * sin(angle * 3.0 + time * 0.50) +
            2.6 * sin(angle * 7.0 - time * 0.38)
        ) * circleNoiseFade;

    float circleDist =
        distance(p, center) -
        circleRadius +
        circleNoise;

    float circleFill = 1.0 - smoothstep(
        -circleSoftness * 0.52,
        circleSoftness,
        circleDist
    );

    float circleVisibility = mix(
        0.68,
        0.98,
        smoothstep(0.0, 0.75, progress)
    );

    float visibleCircleFill = circleFill * circleAppear;

    result += visibleCircleFill * circleVisibility * float3(0.12, 0.74, 1.0) * 0.030;

    float circleEdge = exp(-abs(circleDist) / 30.0);
    float tightCircleRim = exp(-abs(circleDist) / 10.0);

    float innerRim = circleEdge * visibleCircleFill * 0.20;

    result += innerRim * float3(0.35, 0.88, 1.0);

    float lensLowerShadow =
        visibleCircleFill *
        smoothstep(center.y - circleRadius * 0.10, center.y + circleRadius * 0.72, p.y) *
        0.055;

    result = mix(
        result,
        result * float3(0.965, 0.985, 1.0),
        lensLowerShadow
    );

    float contactGlow =
        circleEdge *
        liquidAlpha *
        circleAppear *
        (1.0 - circleFill * 0.38);

    float contactTightRim =
        tightCircleRim *
        liquidAlpha *
        circleAppear *
        (1.0 - circleFill * 0.22);

    float magneticPull = segmentEase(progress, 0.35, 0.85);

    float chromaticEdge =
        tightCircleRim *
        liquidAlpha *
        circleAppear *
        (0.35 + 0.65 * magneticPull);

    // Лёгкая хроматическая аберрация при столкновении с центральной маской.
    float2 dirFromCenter = normalize(p - center + float2(0.0001, 0.0001));
    float2 chromaAxis = normalize(float2(0.86, -0.34));

    float chromaDot = dot(dirFromCenter, chromaAxis);
    float redSide = smoothstep(-0.15, 1.0, chromaDot);
    float cyanSide = smoothstep(-0.15, 1.0, -chromaDot);

    result.r += chromaticEdge * redSide * 0.010 * finalFade;
    result.g += chromaticEdge * cyanSide * 0.010 * finalFade;
    result.b += chromaticEdge * cyanSide * 0.022 * finalFade;

    result += contactGlow * float3(0.12, 0.68, 1.0) * (0.76 + magneticPull * 0.18) * finalFade;
    result += contactGlow * float3(0.68, 1.00, 1.0) * (0.30 + magneticPull * 0.12) * finalFade;
    result += contactTightRim * float3(0.72, 1.00, 1.0) * (0.22 + magneticPull * 0.10) * finalFade;

    float innerHalo = exp(
        -max(distance(p, center) - circleRadius * 0.54, 0.0) / 78.0
    );

    result = mix(
        result,
        white,
        innerHalo * 0.11 * circleVisibility * circleAppear
    );

    // --------------------------------------------------
    // Tap blob / residual trail
    // --------------------------------------------------

    float2 tapPx = tapPoint * size;
    float tapDist = distance(position, tapPx);

    float tapTrail =
        exp(-pow(tapDist * 0.010, 2.0)) *
        tapPulse *
        mainAlpha *
        0.10;

    float tapBlobNoise =
        sin(position.x * 0.035 + time * 1.8) *
        sin(position.y * 0.026 - time * 1.3);

    tapTrail *= smoothstep(-0.15, 0.75, tapBlobNoise);

    result += tapTrail * white * finalFade;

    float screenTrailNoise =
        20.0 * sin(uv.y * 13.0 + time * 1.85) +
        12.0 * sin(uv.y * 27.0 - time * 1.10);

    float2 touchDeltaPx = position - tapPx;
    float touchSide = touchDeltaPx.x >= 0.0 ? 1.0 : -1.0;
    float visualShock = dragWave * shockStrength;
    float screenTrailDist = abs(touchDeltaPx.x + screenTrailNoise);
    float screenTrail =
        exp(-pow(screenTrailDist / max(62.0 * waveSpread * shockTrail, 1.0), 2.0)) *
        visualShock *
        mainAlpha *
        finalFade *
        0.22;

    float secondaryTrail =
        exp(-pow((screenTrailDist - mix(70.0, 178.0 * shockTrail, 1.0 - tapPulse)) / max(104.0 * waveSpread, 1.0), 2.0)) *
        visualShock *
        (0.64 + 0.36 * tapPulse) *
        mainAlpha *
        finalFade *
        0.20;

    float diagonalTrailAxis =
        dot(touchDeltaPx, normalize(float2(0.55 * touchSide, 0.83))) +
        22.0 * sin(uv.y * 16.0 + time * 1.6);

    float diagonalTrail =
        exp(-pow(diagonalTrailAxis / max(170.0 * waveSpread, 1.0), 2.0)) *
        exp(-pow(touchDeltaPx.x / max(size.x * 0.82 * shockTrail, 1.0), 2.0)) *
        visualShock *
        mainAlpha *
        finalFade *
        0.18;

    float screenRipple =
        exp(-pow((tapDist - mix(96.0, max(size.x, size.y) * 0.76 * shockTrail, 1.0 - tapPulse)) / max(124.0 * waveSpread, 1.0), 2.0)) *
        visualShock *
        (0.35 + 0.65 * tapPulse) *
        mainAlpha *
        finalFade;

    float causticLines =
        (0.5 + 0.5 * sin(tapDist * 0.062 - time * (6.2 + 1.8 * shockInteraction) + (1.0 - tapPulse) * 7.8)) *
        screenRipple *
        visualShock *
        (0.62 + 0.38 * shockInteraction);

    float wakeCrossing =
        (screenTrail * secondaryTrail + diagonalTrail * screenRipple) *
        (0.76 + 0.44 * shockInteraction);

    float wakeInterference =
        (0.5 + 0.5 * sin(tapDist * 0.040 - time * 5.1)) *
        (0.5 + 0.5 * sin((touchDeltaPx.x * touchSide + touchDeltaPx.y * 0.42) * 0.032 + time * 4.2)) *
        visualShock *
        shockInteraction *
        mainAlpha *
        finalFade;

    float compositeWake =
        screenTrail * 0.48 +
        secondaryTrail * 0.36 +
        diagonalTrail * 0.30 +
        screenRipple * 0.28 +
        causticLines * 0.18 +
        wakeCrossing * 0.42 +
        wakeInterference * 0.16;

    result += screenTrail * white * 0.040;
    result += secondaryTrail * white * 0.032;
    result += diagonalTrail * white * 0.034;
    result += screenRipple * white * 0.044;
    result += causticLines * white * 0.026;
    result += wakeCrossing * white * 0.035;
    result += wakeInterference * white * 0.024;

    // --------------------------------------------------
    // Top reservoir + cinematic finish
    // --------------------------------------------------

    float3 stableFinishColor = mix(
        targetBlue,
        cyan,
        0.18
    );

    float3 initialBottomLikeColor = stableFinishColor;

    float topBreath =
        1.0 +
        completed *
        (
            0.08 * sin(time * 1.55) +
            0.035 * sin(time * 2.25)
        );

    float finalCoreSoft = 1.0 - 0.50 * finalBlur;
    float finalMistBoost = 1.0 + 1.25 * finalBlur;

    float topReservoir =
        exp(-uv.y * 3.20) *
        topReservoirProgress *
        0.38 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topReservoirCore =
        exp(-uv.y * 7.00) *
        topReservoirProgress *
        0.30 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topReservoirGlow =
        exp(-pow((uv.y - 0.125) / 0.26, 2.0)) *
        topReservoirProgress *
        0.13 *
        topBreath *
        finalFade *
        finalMistBoost;

    result = plusDarkerApprox(
        result,
        initialBottomLikeColor,
        topReservoir
    );

    result = plusDarkerApprox(
        result,
        mix(targetBlue, deepBlue, 0.18),
        topReservoirCore
    );

    result += topReservoirGlow * float3(0.22, 0.80, 1.0);

    float finish = topCapProgress;

    float topCapAlpha =
        exp(-uv.y * 4.8) *
        finish *
        0.34 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topCapMist =
        exp(-uv.y * 1.22) *
        finish *
        0.13 *
        topBreath *
        finalFade *
        finalMistBoost;

    result = plusDarkerApprox(
        result,
        initialBottomLikeColor,
        topCapAlpha
    );

    result = plusDarkerApprox(
        result,
        mix(targetBlue, deepBlue, 0.14),
        topCapMist
    );

    result += topCapAlpha * float3(0.10, 0.46, 1.0) * 0.10;
    result += topCapMist * float3(0.42, 0.95, 1.0) * 0.045;

    float3 completionMistColor = mix(
        targetBlue,
        cyan,
        0.22
    );

    float completionMist =
        exp(-uv.y * 1.05) *
        completionMistProgress *
        0.12 *
        finalFade *
        finalMistBoost;

    float trailingGlow =
        exp(-pow((uv.y - 0.18) / 0.22, 2.0)) *
        finalBlur *
        0.10 *
        finalFade;

    result += completionMist * completionMistColor;
    result += trailingGlow * float3(0.30, 0.92, 1.0);

    result += completionFlash * float3(0.45, 0.95, 1.0) * 0.08;

    float completionPulse =
        completionBloom *
        (1.0 - 0.35 * sin(time * 2.4));

    float completionTopGlow =
        exp(-uv.y * 4.2) *
        completionPulse *
        0.06 *
        finalFade;

    result += completionTopGlow * float3(0.30, 0.82, 1.0);
    result = mix(result, white, completionBloom * bottomClear * 0.025);

    // --------------------------------------------------
    // Adaptive tap shockwave
    // --------------------------------------------------

    float rippleRadius = (1.0 - tapPulse) * mix(92.0, 310.0, dragWave);

    float rippleRing =
        exp(-pow((tapDist - rippleRadius) * 0.0064, 2.0)) *
        dragWave *
        (0.28 + 0.72 * tapPulse) *
        mix(0.7, 1.15, waveStrength);

    float rippleCore =
        exp(-pow(tapDist * 0.010, 2.0)) *
        dragWave *
        0.10 *
        waveStrength;

    float luminance = dot(result, float3(0.299, 0.587, 0.114));

    float blueRingStrength = rippleRing * smoothstep(0.60, 1.0, luminance);
    float whiteRingStrength = rippleRing * (1.0 - smoothstep(0.40, 0.90, luminance));

    float frontBand =
        localWaterPressure * 0.34 +
        abs(localWaterWave) * 0.30 +
        compositeWake * 0.24;

    float glassSheen =
        smoothstep(0.42, 1.0, compositeWake + frontBand) *
        (0.5 + 0.5 * sin(position.y * 0.030 - time * 4.5 + tapDist * 0.015)) *
        visualShock;

    result = mix(
        result,
        white,
        blueRingStrength * 0.08 + frontBand * 0.035
    );

    result += blueRingStrength * white * 0.035;

    result += whiteRingStrength * white * 0.10;
    result += rippleCore * white * 0.08;
    result += frontBand * white * 0.045;
    result += glassSheen * white * 0.026;
    result += max(localWaterWave, 0.0) * white * 0.16;
    result = mix(
        result,
        white,
        max(-localWaterWave, 0.0) * 0.030
    );

    // --------------------------------------------------
    // Keyframe-matched hero wash
    // --------------------------------------------------

    float keyProgress = clamp(progress, 0.0, 0.82);
    float keyPresence = smoothstep(0.02, 0.18, keyProgress) * fillGain;

    float keyedEdgeY = interpKeys(
        0.86,
        0.62,
        0.38,
        -0.10,
        keyProgress
    );

    float keyedFeather = interpKeys(
        0.16,
        0.22,
        0.31,
        0.27,
        keyProgress
    );

    float keyDx = uv.x - 0.5;

    float keyedSag =
        keyDx * keyDx *
        interpKeys(0.26, 0.32, 0.24, -0.30, keyProgress);

    float keyedEdgeNoise =
        0.012 * sin(uv.x * 9.0 + time * 0.24 + keyProgress * 4.0) +
        0.007 * sin(uv.x * 21.0 - time * 0.16 + keyProgress * 7.0) +
        dragWave * 0.018 * sin(uv.x * 13.0 + time * 0.36);

    float keyedLowerMass = smoothstep(
        keyedEdgeY - keyedFeather,
        keyedEdgeY + keyedFeather,
        uv.y + keyedSag + keyedEdgeNoise
    );

    float lowerFade = 1.0 - segmentEase(keyProgress, 0.62, 0.90);
    keyedLowerMass *= keyPresence * lowerFade;

    float keyedBottomWeight = smoothstep(0.28, 0.96, uv.y);
    float keyedLowerCore = keyedLowerMass * keyedBottomWeight * 0.88;

    float keyedCyanBand =
        exp(-pow((uv.y - keyedEdgeY) / max(keyedFeather * 1.18, 0.01), 2.0)) *
        exp(-pow(keyDx / 0.62, 2.0)) *
        keyPresence *
        lowerFade;

    float3 keyedBlueColor = mix(
        targetBlue,
        blue,
        0.10 + 0.18 * smoothstep(0.20, 0.46, keyProgress)
    );

    keyedBlueColor = mix(
        keyedBlueColor,
        mix(targetBlue, deepBlue, 0.12),
        smoothstep(0.50, 0.74, keyProgress) * smoothstep(0.58, 1.0, uv.y)
    );

    float3 keyedLowerColor = mix(
        mix(cyan, aqua, 0.50),
        keyedBlueColor,
        smoothstep(0.48, 1.0, uv.y)
    );

    result = plusDarkerApprox(
        result,
        keyedLowerColor,
        keyedLowerCore * 0.42 * fillGain
    );

    result += keyedCyanBand * float3(0.38, 0.88, 1.0) * 0.045 * waveStrength;

    float lensY = interpKeys(
        0.74,
        0.56,
        0.59,
        0.31,
        keyProgress
    );

    float lensRX = interpKeys(
        0.55,
        0.62,
        0.60,
        0.57,
        keyProgress
    );

    float lensRY = interpKeys(
        0.21,
        0.19,
        0.20,
        0.19,
        keyProgress
    );

    float lensTopFade =
        smoothstep(0.08, 0.24, keyProgress) *
        (1.0 - segmentEase(keyProgress, 0.88, 1.0));

    float lensD =
        pow((uv.x - 0.5) / max(lensRX, 0.01), 2.0) +
        pow((uv.y - lensY) / max(lensRY, 0.01), 2.0);

    float keyedWhiteLens =
        (1.0 - smoothstep(0.56, 1.48, lensD)) *
        lensTopFade;

    float keyedLensHalo =
        exp(-pow((sqrt(max(lensD, 0.0)) - 0.88) / 0.46, 2.0)) *
        lensTopFade;

    result += keyedWhiteLens * float3(0.18, 0.74, 1.0) * 0.030 * whiteCore;
    result += keyedLensHalo * float3(0.44, 0.92, 1.0) * 0.055 * whiteCore;

    float topPhase =
        segmentEase(keyProgress, 0.58, 0.84) *
        (1.0 - segmentEase(keyProgress, 0.94, 1.0));

    float topCurve =
        0.24 +
        keyDx * keyDx * 0.62 +
        0.011 * sin(uv.x * 8.0 + time * 0.20);

    float topCap =
        (1.0 - smoothstep(topCurve - 0.16, topCurve + 0.24, uv.y)) *
        topPhase;

    float topCore =
        exp(-uv.y * 3.1) *
        topPhase;

    float topMistBand =
        exp(-pow((uv.y - topCurve) / 0.26, 2.0)) *
        exp(-pow(keyDx / 0.78, 2.0)) *
        topPhase;

    float3 topKeyColor = mix(
        targetBlue,
        blue,
        0.16 * topBloom
    );

    result = plusDarkerApprox(
        result,
        topKeyColor,
        clamp(topCap * 0.46 + topCore * 0.12, 0.0, 1.0)
    );

    result += topMistBand * float3(0.56, 1.0, 1.0) * 0.13 * topBloom;

    float topWhiteBowl =
        (1.0 - smoothstep(0.62, 1.30, lensD)) *
        topPhase *
        0.70 * whiteCore;

    result += topWhiteBowl * float3(0.14, 0.62, 1.0) * 0.025;

    float2 swipeNow = float2((tapPoint.x - 0.5) * (safeSize.x / safeSize.y) + 0.5, tapPoint.y);
    float2 swipePrevious = float2((previousTouchPoint.x - 0.5) * (safeSize.x / safeSize.y) + 0.5, previousTouchPoint.y);
    float2 swipeUv = float2((uv.x - 0.5) * (safeSize.x / safeSize.y) + 0.5, uv.y);
    float2 swipePath = swipeNow - swipePrevious;
    float swipePathLength = length(swipePath);
    float swipeMovement = smootherLiquid(smoothstep(0.002, 0.030, swipePathLength));
    float swipeEnergy = swipePulse * swipeMovement * smoothstep(0.010, 0.16, swipeStrength);
    float2 swipeDir = swipePath / max(swipePathLength, 0.0001);
    float2 swipeNormal = float2(-swipeDir.y, swipeDir.x);
    float2 swipeCenter = mix(swipePrevious, swipeNow, 0.54);
    float2 swipeDelta = swipeUv - swipeCenter;
    float swipeAlong = dot(swipeDelta, swipeDir);
    float swipeLateral = dot(swipeDelta, swipeNormal);
    float swipeLength = mix(0.26, 0.48, smoothstep(0.004, 0.070, swipePathLength));
    float swipeWidth = mix(0.105, 0.172, smoothstep(0.012, 0.30, swipeStrength));
    float swipeBody =
        (1.0 - smoothstep(swipeLength * 0.42, swipeLength * 0.64, abs(swipeAlong))) *
        exp(-pow(swipeLateral / max(swipeWidth, 0.001), 2.0));
    float swipeCore =
        (1.0 - smoothstep(swipeLength * 0.18, swipeLength * 0.46, abs(swipeAlong))) *
        exp(-pow(swipeLateral / max(swipeWidth * 0.52, 0.001), 2.0));
    float swipeTail =
        smoothstep(-swipeLength * 0.62, -swipeLength * 0.08, swipeAlong) *
        (1.0 - smoothstep(swipeLength * 0.08, swipeLength * 0.60, swipeAlong)) *
        exp(-pow(swipeLateral / max(swipeWidth * 1.28, 0.001), 2.0));
    float swipeRipple =
        0.5 + 0.5 * sin(swipeAlong * 34.0 - swipeLateral * 13.0 + time * 1.8);
    float swipeSmear = clamp((swipeBody * 0.72 + swipeCore * 0.34 + swipeTail * 0.42) * swipeEnergy, 0.0, 1.0);
    float swipeGlassEdge =
        exp(-pow((abs(swipeLateral) - swipeWidth * 0.72) / max(swipeWidth * 0.36, 0.001), 2.0)) *
        (1.0 - smoothstep(swipeLength * 0.38, swipeLength * 0.66, abs(swipeAlong))) *
        swipeEnergy;
    float swipeAura =
        exp(-pow(swipeLateral / max(swipeWidth * 1.72, 0.001), 2.0)) *
        (1.0 - smoothstep(swipeLength * 0.48, swipeLength * 0.82, abs(swipeAlong))) *
        swipeEnergy;
    float swipeFlow =
        (0.5 + 0.5 * sin(swipeAlong * 13.0 - time * 2.2)) *
        exp(-pow(swipeLateral / max(swipeWidth * 1.08, 0.001), 2.0)) *
        swipeEnergy;

    result = mix(
        result,
        white,
        clamp(swipeSmear * (0.66 + swipeCore * 0.28), 0.0, 0.82)
    );
    result = plusDarkerApprox(
        result,
        white,
        clamp(swipeAura * 0.18 + swipeFlow * 0.08, 0.0, 0.24)
    );
    result += swipeSmear * white * 0.050;
    result += swipeGlassEdge * white * (0.044 + swipeRipple * 0.024);

    float grainMask = clamp(
        liquidAlpha +
        backAlpha * 0.55 +
        mainAlpha * 0.35 +
        topReservoirProgress * 0.30 +
        idleWaveEnergy * 0.30,
        0.0,
        1.0
    );

    float grain = (hashLiquid(position + float2(time * 0.37)) - 0.5);

    result += grain * mix(0.0012, 0.0052, grainMask) * finalFade;

    float rippleShade = clamp(shadertoyRippleLight, -1.0, 1.0) * rippleEnvelope;
    result += rippleShade * white * 0.14;
    result = mix(
        result,
        white,
        max(-rippleShade, 0.0) * 0.035
    );

    float3 lightResult = clamp(result, 0.0, 1.0);

    float3 preThemeMotionResult = lightResult;
    float3 darkSourceLightResult = lightResult;

    float motionColorRestore = clamp(
        tapTrail * 2.10 +
        screenTrail * 2.40 +
        secondaryTrail * 2.00 +
        diagonalTrail * 1.85 +
        screenRipple * 1.65 +
        compositeWake * 1.45 +
        frontBand * 1.55 +
        swipeSmear * 1.95 +
        swipeAura * 1.35 +
        swipeGlassEdge * 1.70 +
        abs(rippleShade) * 1.40,
        0.0,
        1.0
    );
    motionColorRestore = smootherLiquid(motionColorRestore);

    float yellowColoredPresence =
        smoothstep(0.018, 0.27, distance(lightResult, white)) *
        (1.0 - motionColorRestore * 0.98);
    float yellowProgressPresence = smoothstep(0.025, 0.16, progress);
    float yellowWarmDepth = smoothstep(0.46, 1.0, uv.y);
    float yellowTopGlow = 1.0 - smoothstep(0.16, 0.58, uv.y);
    float yellowBottomGlow = smoothstep(0.55, 1.0, uv.y);

    float3 yellowLemon = float3(1.0, 0.975, 0.035);
    float3 yellowSoft = float3(1.0, 0.955, 0.24);
    float3 yellowAmber = float3(1.0, 0.635, 0.060);
    float3 yellowTarget = mix(yellowLemon, yellowAmber, smootherLiquid(yellowWarmDepth));
    yellowTarget = mix(yellowTarget, yellowSoft, yellowTopGlow * 0.24);
    yellowTarget = mix(yellowTarget, yellowAmber, yellowBottomGlow * 0.20);

    float yellowWhiteCenterY =
        0.515 +
        0.020 * sin(time * 0.18 + progress * 4.2);

    float yellowWhiteCenterD =
        pow((uv.x - 0.50) / 0.73, 2.0) +
        pow((uv.y - yellowWhiteCenterY) / 0.205, 2.0);

    float yellowWhiteCenter =
        (1.0 - smoothstep(0.58, 1.34, yellowWhiteCenterD)) *
        yellowProgressPresence *
        (1.0 - segmentEase(progress, 0.94, 1.0) * 0.16);

    float yellowTopWash =
        exp(-pow((uv.y - 0.145) / 0.34, 2.0)) *
        yellowColoredPresence *
        0.18;

    float yellowBottomWash =
        exp(-pow((uv.y - 0.955) / 0.30, 2.0)) *
        yellowColoredPresence *
        0.26;

    lightResult = mix(
        lightResult,
        yellowTarget,
        isYellowPreset * clamp(yellowColoredPresence * 0.92, 0.0, 0.92)
    );

    lightResult = mix(
        lightResult,
        white,
        isYellowPreset * clamp(yellowWhiteCenter * 0.84, 0.0, 0.86)
    );

    lightResult += isYellowPreset * yellowTopWash * float3(1.0, 0.96, 0.08);
    lightResult += isYellowPreset * yellowBottomWash * float3(1.0, 0.53, 0.03);
    lightResult = clamp(lightResult, 0.0, 1.0);
    lightResult = mix(
        lightResult,
        preThemeMotionResult,
        isYellowPreset * motionColorRestore
    );

    // Shared travelling-band timing; each light preset applies its own palette below.
    float referenceBandCenter;
    float referenceBandWidth;
    if (progress <= 0.50) {
        float phase = smootherLiquid(progress / 0.50);
        referenceBandCenter = bandMotion(1.105, 0.855, 0.0, -0.838028, progress / 0.50, 0.50);
        referenceBandWidth = mix(0.205, 0.315, phase);
    } else if (progress <= 0.70) {
        float phase = smootherLiquid((progress - 0.50) / 0.20);
        referenceBandCenter = bandMotion(0.855, 0.515, -0.838028, -1.676693, (progress - 0.50) / 0.20, 0.20);
        referenceBandWidth = mix(0.315, 0.285, phase);
    } else {
        float phase = smootherLiquid((progress - 0.70) / 0.30);
        referenceBandCenter = bandMotion(0.515, 0.020, -1.676693, 0.0, (progress - 0.70) / 0.30, 0.30);
        referenceBandWidth = mix(0.285, 0.235, phase);
    }

    // Yellow follows the established Blue entry; Blue geometry stays unchanged.
    referenceBandCenter -= clamp(isBluePreset + isYellowPreset, 0.0, 1.0) * 0.065 * smoothstep(0.0, 0.05, progress) *
        (1.0 - segmentEase(progress, 0.26, 0.45));
    // Continue the shared mass upward after 90%, without changing the clock.
    referenceBandCenter -= 0.075 * segmentEase(progress, 0.90, 1.0);

    float referenceWarp =
        sin(uv.x * 5.7 + time * 0.11) * 0.018 +
        sin(uv.x * 10.4 - time * 0.08 + 1.2) * 0.008;
    float referenceDistance = uv.y + referenceWarp - referenceBandCenter;

    float referenceOuter = exp(-pow(referenceDistance / referenceBandWidth, 2.0));
    float referenceBody = exp(-pow(referenceDistance / (referenceBandWidth * 0.70), 2.0));
    float referenceCore = exp(-pow(referenceDistance / (referenceBandWidth * 0.34), 2.0));
    float referenceEntry = smoothstep(0.002, 0.020, progress);
    referenceOuter *= referenceEntry;
    referenceBody *= referenceEntry;
    referenceCore *= referenceEntry;


    float3 referenceCyan = float3(0.380, 0.910, 1.000);
    float3 referenceBlue = float3(0.259, 0.545, 0.976); // #428BF9
    float3 referenceBlueAccent = float3(0.000, 0.424, 1.000); // #006CFF
    // One broad pigment profile avoids the narrow accent stripe produced by
    // compositing several differently sized blue cores over one another.
    float blueLightDensity = exp(-pow(referenceDistance / (referenceBandWidth * 0.82), 2.0)) * referenceEntry;
    float3 blueLightPigment = mix(referenceCyan, mix(referenceBlue, referenceBlueAccent, 0.36),
        blueLightDensity * blueLightDensity * 0.85);
    float3 referenceBlueResult = mix(white, blueLightPigment,
        referenceOuter * (0.82 + 0.16 * blueLightDensity));

    // Match Blue Light's monotonic depth profile: orange in the dense body,
    // #FFDD2D in the shoulder, then yellow coverage dissolving into white.
    float yellowOrangeWeight = pow(blueLightDensity, 4.0) * 0.60;
    float3 yellowLightOrange = mix(yellowMidColor.rgb, yellowHotColor.rgb, 0.25);
    float3 yellowLightPigment = mix(yellowLightAccent, yellowLightOrange, yellowOrangeWeight);
    float3 referenceYellowResult = mix(white, yellowLightPigment,
        referenceOuter * (0.82 + 0.16 * blueLightDensity));

    lightResult = mix(lightResult, referenceBlueResult, isBluePreset);
    lightResult = mix(lightResult, referenceYellowResult, isYellowPreset);

    float liquidPresence = clamp(distance(darkSourceLightResult, white) * 1.38, 0.0, 1.0);
    float glowPresence = clamp(
        liquidPresence +
        rimAlpha * 0.32 +
        revealEdgeGlow * 0.50 +
        surfaceGlow * 0.22,
        0.0,
        1.0
    );
    float finishLift = segmentEase(progress, 0.76, 1.00);
    float bottomWeightDark = smoothstep(0.32, 1.0, uv.y);
    float topWeightDark = 1.0 - smoothstep(0.10, 0.46, uv.y);
    float finishTopPush =
        finishLift *
        (1.0 - smoothstep(0.11, 0.48, uv.y)) *
        (0.78 + 0.22 * exp(-pow((uv.y - 0.08) / 0.17, 2.0)));
    float sideGlowDark =
        exp(-pow(uv.x / 0.13, 2.0)) +
        exp(-pow((1.0 - uv.x) / 0.13, 2.0));

    float darkLowerField = clamp(
        glowPresence * (0.56 + bottomWeightDark * 0.42) +
        keyedLowerCore * 0.92 +
        keyedCyanBand * 0.44 +
        liquidAlpha * bottomWeightDark * 0.54 +
        surfaceGlow * 0.22,
        0.0,
        1.0
    );
    darkLowerField *= mix(1.0, 0.015, finishLift);

    float darkTopField = clamp(
        topPhase * (topCap * 0.80 + topCore * 0.34 + topMistBand * 0.72) +
        topReservoir * 0.72 +
        topReservoirCore * 0.54 +
        topReservoirGlow * 0.80 +
        completionMist * 0.82 +
        trailingGlow * 0.70 +
        completionTopGlow * 0.80 +
        finishLift * topWeightDark * 1.04 +
        finishTopPush * 0.42,
        0.0,
        1.0
    );

    // The dark palette always starts on a true black canvas. The selected color is
    // revealed only by the progressing field, never inherited from the light result.
    float darkColorReveal = smoothstep(0.015, 0.24, progress);
    darkLowerField *= darkColorReveal;
    darkTopField *= darkColorReveal;

    float cyanWashDark = clamp(
        keyedCyanBand * 0.70 +
        keyedLensHalo * 0.30 +
        revealEdgeGlow * 0.72 +
        rimAlpha * 0.24,
        0.0,
        1.0
    ) * darkColorReveal;

    // One soft, asymmetric reduction of light behind the digits; no ring or
    // constant-radius plateau. Coordinates match the existing counter region.
    float counterDrift = sin(time * 0.16) * 0.006;
    float2 counterDelta = float2(
        (uv.x - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.29,
        (uv.y - 0.475 + sin(uv.x * 8.0 + 0.8) * 0.016 + counterDrift) / 0.090
    );
    float2 counterLobe = float2((uv.x - 0.57) / 0.23, (uv.y - 0.45 + counterDrift) / 0.105);
    float counterProtection = 0.76 * exp(-dot(counterDelta, counterDelta)) +
        0.24 * exp(-dot(counterLobe, counterLobe));
    // A diffuse light pocket restores the clean light-theme counter area
    // without the former circular stroke or stacked glass-lens masks.
    lightResult = mix(lightResult, white, counterProtection * 0.32);

    float centerVoidD =
        pow((uv.x - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.354, 2.0) +
        pow((uv.y - 0.475 + sin(uv.x * 8.0 + 0.8) * 0.014) / 0.150, 2.0);
    float centerVoid = (1.0 - smoothstep(0.36, 1.68, centerVoidD)) *
        mix(0.56, 0.82, smoothstep(0.02, 0.58, progress));
    float centerVoidSoft = (1.0 - smoothstep(0.58, 2.55, centerVoidD)) *
        mix(0.18, 0.32, smoothstep(0.10, 0.72, progress));
    float centerReduction = clamp(centerVoid * 0.58 + centerVoidSoft * 0.18, 0.0, 0.70);

    float topBlackShelf =
        (1.0 - smoothstep(0.20, 0.52, uv.y)) *
        (1.0 - smoothstep(0.0, 0.18, progress)) *
        0.38;

    float3 darkBase = float3(0.0, 0.0, 0.0);
    float3 darkNavy = float3(0.004, 0.010, 0.024);
    float3 darkBlueGlow = mix(
        float3(0.045, 0.230, 0.780),
        float3(0.820, 0.405, 0.018),
        isYellowPreset
    );
    float3 darkElectric = mix(
        float3(0.100, 0.430, 1.000),
        float3(1.000, 0.720, 0.030),
        isYellowPreset
    );
    float3 darkCyan = mix(
        float3(0.520, 0.960, 1.000),
        float3(1.000, 0.925, 0.210),
        isYellowPreset
    );
    float3 darkMintCyan = mix(
        float3(0.650, 1.000, 0.900),
        float3(1.000, 0.970, 0.560),
        isYellowPreset
    );

    float lowerIntensity = smootherLiquid(darkLowerField);
    float topIntensity = smootherLiquid(darkTopField);
    float edgeIntensity = clamp(sideGlowDark * (darkLowerField * 0.30 + darkTopField * 0.34), 0.0, 1.0);

    float3 darkResult = darkBase;
    darkResult = mix(darkResult, darkNavy, clamp(darkLowerField * 0.52 + darkTopField * 0.38, 0.0, 1.0));
    darkResult += mix(darkBlueGlow, darkElectric, smoothstep(0.22, 0.92, lowerIntensity)) * lowerIntensity * 0.82;
    darkResult += darkCyan * cyanWashDark * 0.24;
    darkResult += darkMintCyan * keyedWhiteLens * 0.10 * darkColorReveal;
    darkResult += mix(darkBlueGlow, darkElectric, 0.52) * topIntensity * 0.86;
    darkResult += darkCyan * topMistBand * 0.22 * darkColorReveal;
    darkResult += darkElectric * edgeIntensity * 0.42;
    darkResult += mix(darkBlueGlow, darkElectric, 0.72) * finishTopPush * 0.34;

    darkResult = mix(darkResult, darkBase, clamp(centerVoidSoft, 0.0, 0.34));
    darkResult = mix(darkResult, darkBase, clamp(centerVoid, 0.0, 0.86));
    darkResult = mix(darkResult, darkBase, finishLift * smoothstep(0.30, 0.72, uv.y) * 0.64);
    darkResult = mix(darkResult, darkBase, topBlackShelf);
    float blueIdleAccent = isBluePreset * idleWaveEnergy * (1.0 - motionColorRestore * 0.85);
    darkResult += float3(0.000, 0.423529, 1.000) * blueIdleAccent * 0.74;
    darkResult += float3(0.540, 0.900, 1.000) * blueIdleAccent * 0.24;
    float yellowIdleAccent = isYellowPreset * idleWaveEnergy * (1.0 - motionColorRestore * 0.85);
    darkResult += float3(1.000, 0.780, 0.075) * yellowIdleAccent * 0.62;
    darkResult += float3(1.000, 0.956, 0.365) * yellowIdleAccent * 0.24;

    // Dark mode uses the same travelling band as the light reference. Only the
    // canvas changes to black; no accumulated color remains below the band.
    float3 darkBandOuterColor = mix(targetBlue, cyan, 0.30);
    float3 darkBandBodyColor = mix(targetBlue, electric, 0.34);
    float3 darkBandCoreColor = mix(targetBlue, electric, 0.72);
    if (isYellowPreset > 0.5) {
        // Carry Blue Dark's dominant-channel light field through the shared
        // masks first. Apply Yellow's palette after them, not before dimming.
        darkBandOuterColor = darkBandBodyColor = darkBandCoreColor = float3(1.0);
    }
    float darkBandEntry = smoothstep(0.002, 0.020, progress);
    float darkBandOuter = referenceOuter * darkBandEntry;
    float darkBandBody = referenceBody * darkBandEntry;
    float darkBandCore = referenceCore * darkBandEntry;
    float3 travellingDarkResult = darkBase;
    travellingDarkResult += darkBandOuterColor * darkBandOuter * 0.20;
    travellingDarkResult += darkBandBodyColor * darkBandBody * 0.58;
    travellingDarkResult += darkBandCoreColor * darkBandCore * 0.54;
    travellingDarkResult = mix(
        travellingDarkResult,
        darkBase,
        centerReduction
    );
    darkResult = travellingDarkResult;
    // Clear behind the moving mass, not through its bright core at 70–85%.
    // Rejoin the original completion fade before the explicit endpoint gate.
    float completionBlackout =
        segmentEase(progress, 0.58, 0.98) *
        smoothstep(0.06, 0.38, uv.y) *
        mix(smoothstep(0.04, 0.32, referenceDistance),
            1.0, segmentEase(progress, 0.85, 0.98));
    darkResult = mix(darkResult, darkBase, completionBlackout);
    // Hard safety gate: no color is allowed to leak into a dark-theme canvas at 0%.
    // This is intentionally applied after every dark effect contribution.
    float darkCanvasReveal = smoothstep(0.0, 0.10, progress);
    darkResult = mix(darkBase, darkResult, darkCanvasReveal);

    // Same MAIN completion field as the frozen Dark Blue source. Yellow
    // changes its palette only after this shared coverage is resolved.
    float finishSync = segmentEase(progress, 0.94, 1.0);
    float endpointCoverage = referenceOuter * (0.82 + 0.16 * blueLightDensity) *
        (1.0 - counterProtection * 0.32);
    float3 endpointColor = isYellowPreset > 0.5 ? float3(1.0) : darkBandCoreColor;
    darkResult = mix(darkResult, endpointColor * endpointCoverage, finishSync);
    // Blue Dark's unbounded density is the only spatial input to palette
    // mapping. A second, narrower body mask made the other palettes read as
    // stripes even though their outer coverage matched Blue.
    float sharedLightField = max(darkResult.r, max(darkResult.g, darkResult.b));
    // Keep the frozen Dark density/contact field separate from Yellow main color.
    float idleDensity = idleActivity > 0.0
        ? idleWaveDensity(position, size, idleActivity, idleTime, waveStrength) : 0.0;
    if (themeStrength < 0.5 && (isBluePreset + isYellowPreset) > 0.5) {
        idleDensity = lightIdleWaveDensity(position, size, idleActivity, idleTime, waveStrength);
    }
    IdleContact contact = sharedIdleContact(sharedLightField, float(half(idleDensity)));
    if (themeStrength < 0.5 && (isBluePreset + isYellowPreset) > 0.5) {
        // Keep the accepted M0 stationary; contact changes pigment, not coordinates.
        float distance = uv.y + referenceWarp - referenceBandCenter;
        float outer = exp(-pow(distance / referenceBandWidth, 2.0)) * referenceEntry;
        float body = exp(-pow(distance / (referenceBandWidth * 0.70), 2.0)) * referenceEntry;
        float core = exp(-pow(distance / (referenceBandWidth * 0.34), 2.0)) * referenceEntry;
        float3 mainField = darkBase;
        mainField += darkBandOuterColor * outer * darkBandEntry * 0.20;
        mainField += darkBandBodyColor * body * darkBandEntry * 0.58;
        mainField += darkBandCoreColor * core * darkBandEntry * 0.54;
        mainField = mix(mainField, darkBase, centerReduction);
        float blackout = segmentEase(progress, 0.58, 0.98) *
            smoothstep(0.06, 0.38, uv.y) *
            mix(smoothstep(0.04, 0.32, distance), 1.0, segmentEase(progress, 0.85, 0.98));
        mainField = mix(mainField, darkBase, blackout);
        mainField = mix(darkBase, mainField, darkCanvasReveal);
        float density = exp(-pow(distance / (referenceBandWidth * 0.82), 2.0)) * referenceEntry;
        float coverage = outer * (0.82 + 0.16 * density) * (1.0 - counterProtection * 0.32);
        mainField = mix(mainField, endpointColor * coverage, finishSync);
        sharedLightField = max(mainField.r, max(mainField.g, mainField.b));
        idleDensity = idleActivity > 0.0
            ? idleWaveDensity(position, size, idleActivity, idleTime, waveStrength) : 0.0;
        contact = sharedIdleContact(sharedLightField, float(half(idleDensity)));
        // V2 support: I=clamp(M0,0,1)*W, including the dense MAIN interior.
    }
    float3 blueDarkReference = darkResult;
    if (isYellowPreset > 0.5) {
        blueDarkReference = float3(0.10, 0.55, 1.0) * sharedLightField;
        // Restore only the explicitly accepted Yellow Dark palette; Light remains separate.
        if (themeStrength > 0.5) {
            // Keep Blue's luminance response, including its unbounded density.
            // Clamping density before the hue ramp flattened Yellow's bright body
            // while its falloff continued changing color, revealing a separate band.
            float warmth = clamp(sharedLightField / (0.20 + 0.58 + 0.54), 0.0, 1.0);
            float3 warmColor = mix(yellowDeepColor.rgb, yellowHotColor.rgb, warmth);
            float3 endpointWarmColor = mix(yellowDeepColor.rgb, yellowLightAccent,
                pow(clamp(sharedLightField, 0.0, 1.0), 2.0));
            warmColor = mix(warmColor, endpointWarmColor, finishSync);
            float3 luminanceWeights = float3(0.2126, 0.7152, 0.0722);
            float referenceLuminance = dot(pow(clamp(blueDarkReference, 0.0, 1.0),
                float3(2.2)), luminanceWeights);
            float warmLuminance = dot(pow(warmColor, float3(2.2)), luminanceWeights);
            // Endpoint color remains warmer/brighter without moving its field.
            float paletteExposure = mix(1.12, 2.80, finishSync);
            darkResult = warmColor * pow(referenceLuminance * paletteExposure /
                max(warmLuminance, 0.00001), 1.0 / 2.2);
        } else {
            darkResult = yellowDarkDensityPalette(sharedLightField);
        }
    }
    darkResult += grain * mix(0.0010, 0.0035, grainMask) *
        (1.0 - completionBlackout) * darkCanvasReveal;
    blueDarkReference = clamp(blueDarkReference + grain * mix(0.0010, 0.0035, grainMask) *
        (1.0 - completionBlackout) * darkCanvasReveal, 0.0, 1.0);
    float3 finishedDark = clamp(darkResult, 0.0, 1.0);
    // White transmits the same density field. Channel-wise absorption gives
    // blue -> cyan -> white / orange -> yellow -> white continuously, rather
    // than painting a saturated band with separate hue and opacity masks.
    float3 blueTransmission = mix(referenceBlue, referenceBlueAccent, 0.65);
    float3 yellowTransmission = float3(yellowLightOrange.r,
        mix(yellowMidColor.g, yellowHotColor.g, 0.75),
        pow(yellowLightAccent.b, 2.5));
    float3 transmission = mix(blueTransmission, yellowTransmission, isYellowPreset);
    float3 matchingLight = pow(max(transmission, float3(0.0001)), float3(sharedLightField));
    if (themeStrength < 0.5 && (isBluePreset + isYellowPreset) > 0.5) {
        matchingLight = correctedLightPigment(sharedLightField, gradientColorIndex, transmission);
    }
    lightResult = mix(lightResult, matchingLight, clamp(isBluePreset + isYellowPreset, 0.0, 1.0));
    result = mix(lightResult, finishedDark, themeStrength);

    // Explicit boundary states for the dark theme. These sit after all palette
    // effects, so a selected color can never replace the black canvas at rest.
    float darkTheme = step(0.5, themeStrength);
    float darkAtRest = 1.0 - smoothstep(0.001, 0.035, progress);
    result = mix(result, darkBase, darkTheme * darkAtRest);
    blueDarkReference = mix(blueDarkReference, darkBase, darkTheme * darkAtRest);

    // Purely visual history; no clock or field value feeds the progress mechanic.
    if (interactionFloatCount > 0) {
        float trail = interactionLightField(uv, safeSize.x / safeSize.y, interactionSegments, interactionFloatCount);
        float readability = 1.0 - 0.88 * counterProtection;
        // Exposure depends on local interaction accumulation, so a first pass
        // cannot start white merely because it crosses a bright progress band.
        float heat = trail;
        float brighter = 1.0 - exp(-max(heat - 0.35, 0.0) * 0.95);
        float excessHeat = max(heat - 1.45, 0.0);
        float exposure = 1.0 - exp(-excessHeat * excessHeat / 3.0);
        float3 trailColor;
        if (isYellowPreset > 0.5) {
            // Channel-wise exponential exposure used to push R and G towards
            // equality, leaving olive on black. Keep warm hue while light grows.
            float3 warm = darkTheme > 0.5
                ? mix(yellowDeepColor.rgb, min(yellowHotColor.rgb * 1.18, 1.0), brighter)
                : mix(yellowHotColor.rgb, yellowLightAccent, 0.48 + brighter * 0.52);
            float cream = smoothstep(0.70, 3.0, heat) * 0.75;
            if (darkTheme < 0.5) {
                // A broad orange interval separates yellow pigment from light,
                // making the trail readable even over a saturated yellow base.
                float orange = exp(-pow((heat - 0.85) / 0.90, 2.0)) *
                    (1.0 - exp(-heat * 2.0)) * 0.75;
                warm = mix(yellowLightAccent, yellowLightOrange, orange);
                cream = smoothstep(1.55, 3.50, heat) * 0.75;
                float accumulatedHeat = max(heat - 2.0, 0.0);
                exposure = 1.0 - exp(-accumulatedHeat * accumulatedHeat / 2.8);
            }
            warm = mix(warm, mix(yellowHotColor.rgb, white, 0.82), cream);
            trailColor = mix(warm, mix(yellowHotColor.rgb, white, 0.94), exposure);
        } else {
            // Reuse the cyan produced by the existing additive idle overlap.
            float3 overlapCyan = clamp(targetBlue + float3(0.14, 0.48, 1.0), 0.0, 1.0);
            float3 lightBlue = mix(targetBlue, mix(referenceCyan, overlapCyan, darkTheme), brighter);
            trailColor = mix(lightBlue, float3(0.91, 0.98, 1.0), exposure);
        }
        // Protect text through coverage, not heat: the mask must not turn a
        // hot white/cyan/cream trail into a different, muddy color at its edge.
        float opacity = (0.78 + 0.22 * exposure) * (1.0 - exp(-trail * 0.95)) * readability;
        if (darkTheme > 0.5) {
            float3 backdrop = result;
            result = 1.0 - (1.0 - result) * (1.0 - trailColor * opacity);
            if (isYellowPreset > 0.5) {
                // Same trail field, alpha and screen blending as Blue Dark;
                // only reduce color energy if the warm overlap is brighter.
                float3 blueTrail = mix(mix(float3(0.10, 0.55, 1.0),
                    float3(0.24, 1.0, 1.0), brighter), float3(0.91, 0.98, 1.0), exposure);
                float3 blueOverlap = 1.0 - (1.0 - blueDarkReference) * (1.0 - blueTrail * opacity);
                // Balance only added trail light: a history buffer must never
                // darken the untouched backdrop, even when its samples faded.
                result = backdrop + balanceYellowDarkLight(max(result - backdrop, 0.0),
                    max(blueOverlap - blueDarkReference, 0.0));
            }
        } else {
            // Keep the old Blue Light screen-pass character, driven by local
            // overlap rather than separate offset strokes. First passes stay colored.
            float pigmentOpacity = opacity * (0.76 + 0.24 * exposure);
            result = mix(result, trailColor, pigmentOpacity);
            float3 screenLight = isYellowPreset > 0.5
                ? mix(yellowLightAccent, white, 0.80)
                : float3(0.80, 0.9059, 1.0); // Original Blue Light screen color.
            result = 1.0 - (1.0 - result) * (1.0 - screenLight * exposure * opacity * 0.42);
        }
    }

    half4 output = half4(half3(clamp(result, 0.0, 1.0)), 1.0);
    if (themeStrength < 0.5 && idleActivity > 0.0) {
        output = correctedLightIdle(output, idleWaveColor(idleDensity, 0.0, gradientColorIndex),
            contact, gradientColorIndex, transmission);
    }
    if (themeStrength > 0.5 && (isBluePreset + isYellowPreset) > 0.5 && idleActivity > 0.0) {
        if (isYellowPreset > 0.5) {
            output = qaHistoricalYellowDarkContact(output, qaHistoricalYellowDarkWave(idleDensity), gradientColorIndex, contact.coverage);
        } else {
            output = blendDarkIdle(output, idleWaveColor(idleDensity, 1.0, gradientColorIndex),
                contact, gradientColorIndex);
        }
    }
    return output;
}

__attribute__((noinline))
half4 qaContactDarkReference(
    float2 position,
    half4 color,
    float2 size,
    float progress,
    float tapPulse,
    float2 tapPoint,
    float2 previousTouchPoint,
    float swipePulse,
    float swipeStrength,
    float time,
    float progressSpeed,
    float fillGain,
    float waveStrength,
    float waveSpread,
    float topBloom,
    float whiteCore,
    float blueDepth,
    float dragWave,
    float shockStrength,
    float shockInteraction,
    float shockTrail,
    float waveCount,
    float themeStrength,
    float gradientColorIndex,
    float idleActivity,
    float idleTime,
    device const float *interactionSegments,
    int interactionFloatCount
) ;

// QA GEOMETRY ONLY: one display coordinate system for Blue MAIN.
// Physical contact fields and the frozen Dark contact helper are not inputs/outputs.
struct QaCommonMainShape {
    float warp;
    float distance;
    float voidD;
    float counter;
};
QaCommonMainShape qaCommonMainShape(float2 uv, float progress, float time,
    float bandCenter, float originalWarp, float originalVoidD,
    float originalCounter, float counterDrift) {
    // Preserve the original Light curve in the lower travel. Continuously
    // remove only its odd horizontal component as MAIN rises above halfway.
    // .50 is the existing middle travel key; .76 the existing finish-lift onset.
    float balance = segmentEase(progress, 0.50, 0.76);
    float mirrorX = 1.0 - uv.x;
    float mirrorWarp = sin(mirrorX * 5.7 + time * 0.11) * 0.018 +
        sin(mirrorX * 10.4 - time * 0.08 + 1.2) * 0.008;
    float mirrorVoidD =
        pow((mirrorX - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.354, 2.0) +
        pow((uv.y - 0.475 + sin(mirrorX * 8.0 + 0.8) * 0.014) / 0.150, 2.0);
    float2 mirrorCounter = float2(
        (mirrorX - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.29,
        (uv.y - 0.475 + sin(mirrorX * 8.0 + 0.8) * 0.016 + counterDrift) / 0.090);
    float2 mirrorLobe = float2((mirrorX - 0.57) / 0.23,
        (uv.y - 0.45 + counterDrift) / 0.105);
    float mirrorProtection = 0.76 * exp(-dot(mirrorCounter, mirrorCounter)) +
        0.24 * exp(-dot(mirrorLobe, mirrorLobe));
    QaCommonMainShape shape;
    shape.warp = mix(originalWarp, (originalWarp + mirrorWarp)*0.5, balance);
    shape.distance = uv.y + shape.warp - bandCenter;
    shape.voidD = mix(originalVoidD, (originalVoidD + mirrorVoidD)*0.5, balance);
    shape.counter = mix(originalCounter, (originalCounter + mirrorProtection)*0.5, balance);
    return shape;
}

// ONE small softness adjustment to existing display MAIN Gaussians only.
// Add common variance (quarter of the existing core radius); peak amplitudes,
// original RGB readout, masks, warp, clock and contact fields remain unchanged.
float qaDisplayMainGaussian(float distance,float width,float radius) {
    const float softness=0.25*0.34;
    float softenedRadius=sqrt(radius*radius+2.0*softness*softness);
    return exp(-pow(distance/(width*softenedRadius),2.0));
}

float qaMainPoseProgress(float p);
float qaMainPoseTime(float p,float time);
float qaMainAtPose(float2 uv,float progress,float time,bool dark);

// Inset the EXISTING central area in ellipse-radius units. An additive
// radial inset translates its soft edge; it does not scale/contract feather
// width. Keep centre depth smooth and all physical/contact coordinates exact.
float qaCompactMainCentre(float q,float progress) {
    float active=segmentEase(progress,0.40,0.50)*(1.0-segmentEase(progress,0.80,0.85));
    if(active<=0.0) return q;
    float r=sqrt(max(q,0.0));
    // Inset the inner area while pinning the existing outer soft support and
    // side highlights. Feather support is preserved, not scaled smaller.
    float interior=1.0-smoothstep(0.36,1.68,q);
    float inset=0.10*active*segmentEase(r,0.0,0.60)*interior;
    return (r+inset)*(r+inset);
}

// Dark only, outgoing low-density colour toe. Same hue vector, same existing
// blue-cap knee, exact bright values. C2 join to untouched mid/high density.
// No new Gaussian, RGB layer, geometry, blur or per-column normalization.
float qaDarkLateFade(float density,float outwardDistance,float displayProgress) {
    const float knee=1.0-(0.20+0.58+0.54-1.0);
    float toe=max(1.0-density/knee,0.0);
    float late=segmentEase(displayProgress,0.78,0.86);
    float flank=segmentEase(outwardDistance,0.0,0.34);
    return density*(1.0+0.35*late*flank*toe*toe*toe);
}

float qaRestoreMainOuter(float outer,float entry,float reveal,float transmission,
    float distance,float width,float voidD,float progress) {
    // Restore only the missing part of the EXISTING .20 outer contribution.
    // Existing void + outgoing-flank coordinates; no added Gaussian/glow/mask.
    voidD=qaCompactMainCentre(voidD,progress);
    float interior=1.0-smoothstep(0.36,1.68,voidD);
    float exterior=segmentEase(distance/width,0.0,0.34)*segmentEase(progress,0.76,0.80);
    return outer*0.20*entry*reveal*(1.0-transmission)*interior*exterior;
}

// Display-only primary void: same centre and existing soft-void extent.
// Remove the flat inner plateau / short oval shoulder during the requested
// middle travel. Physical/contact fields and normalization probes stay exact.
float qaDisplayCentreProfile(float q,float progress) {
    q=qaCompactMainCentre(q,progress);
    float original=1.0-smoothstep(0.36,1.68,q);
    float soft=1.0-smootherLiquid(clamp(q/2.55,0.0,1.0));
    float active=segmentEase(progress,0.40,0.50)*(1.0-segmentEase(progress,0.80,0.85));
    return mix(original,soft,active);
}

float qaCentreMainRetention(float outer,float body,float core,float voidD,float progress,
    float outwardDistance=0.0,float displayProgress=-1.0) {
    voidD=qaCompactMainCentre(voidD,progress);
    float originalInterior=1.0-smoothstep(0.36,1.68,voidD);
    // Centre only: remove the flat oval plateau. Use the existing soft-void
    // extent, with one continuous falloff from its centre and zero edge slope.
    // Same accepted 7-second falloff, entering continuously before 2 seconds.
    // No new light/pigment profile; outer and all MAIN Gaussians stay exact.
    float radial=1.0-clamp(voidD/2.55,0.0,1.0);
    float softInterior=radial*radial;
    float local=segmentEase(progress,0.0,0.20)*(1.0-segmentEase(progress,0.80,0.85));
    float interior=mix(originalInterior,softInterior,local);
    float narrow=body*0.58+core*0.54;
    float retention=1.0-interior*narrow/max(outer*0.20+narrow,0.000001);
    // This is already a SECOND attenuation after centerReduction. Relax only
    // that duplicate depth within its existing support, preserving one pocket.
    // A geometric mean with unity spreads the retained energy continuously;
    // no new spatial mask, colour, Gaussian, ring or light layer.
    float soften=local*segmentEase(progress,0.30,0.40);
    // Late colour shoulder only: the duplicate body/core removal otherwise
    // returns abruptly to its compact attenuation as the accepted soft centre
    // hands over. Reuse its accepted sqrt readout on the OUTER shoulder only.
    // Central flat interior, MAIN peak, Gaussians, geometry and contact stay exact.
    float clock=displayProgress>=0.0 ? displayProgress : progress;
    float late=segmentEase(clock,0.76,0.80)*(1.0-segmentEase(clock,0.86,0.90));
    float shoulder=segmentEase(outwardDistance,0.0,0.34)*(1.0-originalInterior);
    soften=max(soften,late*shoulder);
    return mix(retention,sqrt(max(retention,0.0)),soften);
}

half4 qaCurrentAcceptedDarkBlue(
    float2 position,
    half4 color,
    float2 size,
    float progress,
    float tapPulse,
    float2 tapPoint,
    float2 previousTouchPoint,
    float swipePulse,
    float swipeStrength,
    float time,
    float progressSpeed,
    float fillGain,
    float waveStrength,
    float waveSpread,
    float topBloom,
    float whiteCore,
    float blueDepth,
    float dragWave,
    float shockStrength,
    float shockInteraction,
    float shockTrail,
    float waveCount,
    float themeStrength,
    float gradientColorIndex,
    float idleActivity,
    float idleTime,
    device const float *interactionSegments,
    int interactionFloatCount
) {
    // Keep the accepted Dark Blue body below untouched. Other theme changes
    // compile in a separate function and cannot rewrite its main/idle arithmetic.
    if (as_type<uint>(themeStrength) == 0u || as_type<uint>(gradientColorIndex) == 0x40400000u) {
        return correctedThemesBackground(position, color, size, progress, tapPulse, tapPoint, previousTouchPoint, swipePulse, swipeStrength, time, progressSpeed, fillGain, waveStrength, waveSpread, topBloom, whiteCore, blueDepth, dragWave, shockStrength, shockInteraction, shockTrail, waveCount, themeStrength, gradientColorIndex, idleActivity, idleTime, interactionSegments, interactionFloatCount);
    }

    progress = clamp(progress, 0.0, 1.0);
    progressSpeed = clamp(progressSpeed, 0.0, 10.0);
    fillGain = clamp(fillGain, 0.0, 10.0);
    waveStrength = clamp(waveStrength, 0.0, 10.0);
    waveSpread = clamp(waveSpread, 0.0, 10.0);
    topBloom = clamp(topBloom, 0.0, 10.0);
    whiteCore = clamp(whiteCore, 0.0, 10.0);
    blueDepth = clamp(blueDepth, 0.0, 10.0);
    dragWave = clamp(dragWave, 0.0, 1.0);
    swipePulse = smootherLiquid(clamp(swipePulse, 0.0, 1.0));
    swipeStrength = clamp(swipeStrength, 0.0, 1.0);
    shockStrength = clamp(shockStrength, 0.0, 10.0);
    shockInteraction = clamp(shockInteraction, 0.0, 10.0);
    shockTrail = clamp(shockTrail, 0.0, 10.0);
    waveCount = clamp(round(waveCount), 0.0, 10.0);
    themeStrength = clamp(themeStrength, 0.0, 1.0);
    gradientColorIndex = clamp(round(gradientColorIndex), 0.0, 4.0);
    float isBluePreset = 1.0 - step(0.5, abs(gradientColorIndex));
    float isYellowPreset = 1.0 - step(0.5, abs(gradientColorIndex - 3.0));

    float2 design = float2(375.0, 812.0);
    float2 safeSize = float2(max(size.x, 1.0), max(size.y, 1.0));

    float2 p = float2(
        position.x / safeSize.x * design.x,
        position.y / safeSize.y * design.y
    );

    float2 uv = position / safeSize;

    float3 white = float3(1.0);

    // Blue gradient shares the light idle-wave palette: #1A8CFF.
    float3 cyan = float3(0.10, 0.55, 1.0);
    float3 aqua = float3(0.10, 0.55, 1.0);
    float3 blue = float3(0.10, 0.55, 1.0);
    float3 deepBlue = float3(0.10, 0.55, 1.0);
    float3 electric = float3(0.10, 0.55, 1.0);
    float3 targetBlue = float3(0.10, 0.55, 1.0);

    if (gradientColorIndex < 2.5 && gradientColorIndex > 1.5) {
        cyan = float3(0.62, 0.46, 1.0);
        aqua = float3(0.43, 0.28, 0.94);
        blue = float3(0.22, 0.12, 0.72);
        deepBlue = float3(0.09, 0.05, 0.34);
        electric = float3(0.82, 0.58, 1.0);
        targetBlue = float3(0.56, 0.42, 1.0);
    } else if (gradientColorIndex < 3.5 && gradientColorIndex > 2.5) {
        cyan = mix(yellowHotColor.rgb, white, 0.32);
        aqua = yellowHotColor.rgb;
        blue = yellowMidColor.rgb;
        deepBlue = yellowDeepColor.rgb;
        electric = yellowHotColor.rgb;
        targetBlue = yellowMidColor.rgb;
    } else if (gradientColorIndex > 3.5) {
        cyan = float3(1.0, 0.46, 0.68);
        aqua = float3(0.94, 0.26, 0.58);
        blue = float3(0.60, 0.14, 0.52);
        deepBlue = float3(0.26, 0.05, 0.20);
        electric = float3(1.0, 0.68, 0.88);
        targetBlue = float3(1.0, 0.42, 0.66);
    }

    float3 waveMid = mix(targetBlue, aqua, 0.24);
    float3 waveDeep = mix(deepBlue, targetBlue, 0.18);
    float3 waveGlass = mix(cyan, white, 0.68);
    float3 waveEdge = mix(electric, cyan, 0.36);

    // --------------------------------------------------
    // Idle shockwave
    // --------------------------------------------------

    float idleWaveActivity = smootherLiquid(swipeStrength);
    float idleWaveFade = mix(0.92, 0.78, smoothstep(0.92, 1.0, progress)) * idleWaveActivity;

    float idlePeriod = 3.0;
    float idleCycleRaw = fract(time / idlePeriod);
    float idleCycle = smootherLiquid(idleCycleRaw);

    float idleWaveVisibility =
        smoothstep(0.02, 0.11, idleCycleRaw) *
        (1.0 - smoothstep(0.88, 1.0, idleCycleRaw)) *
        idleWaveFade;

    float idleWaveY = mix(-110.0, 925.0, idleCycle);

    float idleWidth = mix(72.0, 420.0, idleCycle);
    float idleThickness = mix(19.0, 42.0, idleCycle);

    float idleDx = p.x - 187.5;

    float idleArcY =
        idleWaveY +
        (idleDx * idleDx) / max(idleWidth * 1.72, 1.0);

    float idleWaveDist = p.y - idleArcY;

    float idleMainWave =
        exp(-pow(idleWaveDist / idleThickness, 2.0)) *
        exp(-pow(idleDx / idleWidth, 2.0));

    float idleSecondWave =
        exp(-pow((idleWaveDist + 72.0) / (idleThickness * 1.35), 2.0)) *
        exp(-pow(idleDx / (idleWidth * 1.18), 2.0)) *
        0.42;

    float idleThirdWave =
        exp(-pow((idleWaveDist + 132.0) / (idleThickness * 1.75), 2.0)) *
        exp(-pow(idleDx / (idleWidth * 1.32), 2.0)) *
        0.20;

    float idleConeGlow =
        exp(-pow((p.y - idleWaveY) / 180.0, 2.0)) *
        exp(-pow(idleDx / max(idleWidth * 1.18, 1.0), 2.0)) *
        0.18;

    float idleWaveEnergy =
        clamp(
            idleMainWave +
            idleSecondWave +
            idleThirdWave +
            idleConeGlow,
            0.0,
            1.0
        ) *
        idleWaveVisibility *
        waveStrength;

    // --------------------------------------------------
    // Continuous upward motion
    // --------------------------------------------------

    // Use the original gradient motion curve for every palette and theme.
    float baseRise = progress * (0.42 + 0.58 * progress);
    float smoothRise = smootherLiquid(progress);
    float rise = mix(baseRise, smoothRise, 0.34);
    float finalLiftBoost = segmentEase(progress, 0.74, 1.00);
    float lateLiftBoost = segmentEase(progress, 0.88, 1.00);

    float circleGrowth = smootherLiquid(progress);

    float2 center = float2(187.5, 406.0);
    float circleAppear = smoothstep(0.025, 0.12, progress * (0.70 + progressSpeed * 3.0));
    float circleRadius = mix(74.0, 178.0, circleGrowth) * mix(0.92, 1.08, waveSpread - 0.5);

    float bottomCleanProgress = segmentEase(progress, 0.42, 1.00);
    float topCapProgress = segmentEase(progress, 0.82, 1.00);
    float topReservoirProgress = segmentEase(progress, 0.58, 1.00);

    float completionBloom = segmentEase(progress, 0.96, 1.00);
    float completed = smoothstep(0.995, 1.0, progress);

    float globalLift =
        mix(0.0, 1380.0, rise) +
        260.0 * finalLiftBoost +
        540.0 * lateLiftBoost;

    float initialDrop = 350.0 * (1.0 - rise);

    float finalBlur = segmentEase(progress, 0.70, 1.00);
    float completionMistProgress = segmentEase(progress, 0.84, 1.00);

    float completionFlash = 0.0;

    // Позже начинаем растворять градиент.
    float lateTransparency = segmentEase(progress, 0.90, 1.00);

    float mainFinalFade = mix(1.0, 0.62, lateTransparency);
    float rimFinalFade = mix(1.0, 0.44, lateTransparency);
    float finalFade = mainFinalFade;

    // Делаем градиент более вытянутым в первой половине
    // и чуть компактнее к финалу, но мягче, чем раньше.
    float shrinkAfterHalf = segmentEase(progress, 0.64, 1.00);

    float stretchFactor = mix(
        0.30,
        0.64,
        shrinkAfterHalf
    );

    float2 pStretched = float2(
        p.x,
        406.0 + (p.y - 406.0) * stretchFactor
    );

    // --------------------------------------------------
    // Bottom clearing mask
    // --------------------------------------------------

    float clearEdgeY = mix(1060.0, 225.0, bottomCleanProgress);
    float clearFeather = mix(205.0, 360.0, bottomCleanProgress);

    float clearWave =
        24.0 * sin(p.x * 0.018 + time * 0.50 + rise * 2.0) +
        15.0 * sin(p.x * 0.041 - time * 0.36 + rise * 4.0) +
        8.0  * sin((p.x + p.y) * 0.020 + time * 0.22);

    float bottomClear = smoothstep(
        clearEdgeY - clearFeather,
        clearEdgeY + clearFeather,
        p.y + clearWave
    );

    float bottomOnly = smoothstep(0.38, 1.0, uv.y);
    bottomClear *= bottomOnly;

    // --------------------------------------------------
    // Organic liquid reveal edge
    // --------------------------------------------------

    float revealEdgeY = mix(910.0, -1450.0, rise);

    // Граница сверху и снизу мягче.
    float revealFeather = mix(
        140.0,
        360.0 + 340.0 * finalBlur,
        rise
    );

    float revealWaveA =
        34.0 * sin(p.x * 0.013 + time * 0.42 + rise * 2.1);

    float revealWaveB =
        18.0 * sin(p.x * 0.031 - time * 0.56 + rise * 3.4);

    float revealWaveC =
        9.0 * sin(p.x * 0.071 + time * 0.33 - rise * 1.6);

    float domainWarp =
        13.0 * sin((p.x + p.y) * 0.018 + time * 0.28) +
        7.0  * sin((p.x - p.y) * 0.026 - time * 0.31);

    float blob1 =
        42.0 *
        exp(-pow((p.x - 86.0) / 72.0, 2.0)) *
        sin(time * 0.37 + rise * 2.4);

    float blob2 =
        36.0 *
        exp(-pow((p.x - 206.0) / 88.0, 2.0)) *
        sin(time * 0.29 + 1.7 + rise * 2.9);

    float blob3 =
        30.0 *
        exp(-pow((p.x - 318.0) / 76.0, 2.0)) *
        sin(time * 0.34 + 3.1 + rise * 2.2);

    float revealWave =
        revealWaveA +
        revealWaveB +
        revealWaveC +
        domainWarp +
        blob1 +
        blob2 +
        blob3;

    float edgeChaos = mix(
        0.72,
        1.0,
        smoothstep(0.12, 0.65, progress)
    );

    float liquidEdgeY = revealEdgeY - revealWave * edgeChaos;

    float bottomReveal = smoothstep(
        liquidEdgeY - revealFeather,
        liquidEdgeY + revealFeather,
        p.y
    );

    float revealEdgeDist = abs(p.y - liquidEdgeY);

    float revealEdgeGlow =
        exp(-revealEdgeDist / 38.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.22 *
        finalFade;

    float tensionCore =
        exp(-revealEdgeDist / 15.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.18 *
        finalFade;

    float tensionShadow =
        exp(-abs((p.y - liquidEdgeY) - 26.0) / 28.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.10 *
        finalFade;

    float liquidRimLine =
        exp(-revealEdgeDist / 8.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        finalFade;

    // --------------------------------------------------
    // Idle / completion breathing
    // --------------------------------------------------

    float idleEnergy = 1.0 - smoothstep(0.02, 0.22, progress);

    float idleVertical =
        idleEnergy *
        (
            18.0 * sin(time * 0.46) +
            9.0  * sin(time * 0.83)
        );

    float horizontalDrift = 0.0;

    float baseShiftY = globalLift - initialDrop + idleVertical;

    float2 pGlobal = pStretched + float2(horizontalDrift, baseShiftY);

    // --------------------------------------------------
    // Refraction + tap push + flow pull
    // --------------------------------------------------

    float lensDist = distance(p, center);

    float refractionZone =
        exp(-pow((lensDist - circleRadius) / 42.0, 2.0)) *
        circleAppear;

    float2 refractDir = normalize(p - center + float2(0.001, 0.001));
    float2 refractionWarp = refractDir * refractionZone * 10.0;

    float2 tapPxDesign = float2(
        tapPoint.x * design.x,
        tapPoint.y * design.y
    );

    float2 touchDeltaDesign = p - tapPxDesign;
    float tapDistDesign = length(touchDeltaDesign);
    float shockActive = smoothstep(0.04, 1.0, dragWave) * waveStrength * shockStrength;
    float shockAge = clamp((1.0 - tapPulse) / max(shockTrail, 0.30), 0.0, 1.0);
    float shockSide = touchDeltaDesign.x >= 0.0 ? 1.0 : -1.0;
    float travelingPhase = time * (3.8 + 1.4 * shockInteraction);

    float rippleAmplitude = 38.0 * shockStrength;
    float rippleEnvelope = smoothstep(0.01, 0.46, dragWave);
    float waveProgress = clamp(1.0 - tapPulse, 0.0, 1.0);
    float safeWaveSpread = max(waveSpread, 0.001);
    float safeShockTrail = max(shockTrail, 0.001);
    float waveFrontRadius = 24.0 + waveProgress * 250.0 * shockTrail;
    float ringSpacing = 46.0 * waveSpread;
    float ringWidth = max(25.0 * waveSpread, 1.0);
    float finiteRipple = 0.0;

    // Fixed upper bound keeps this predictable on the GPU while allowing 0...10 waves.
    for (int waveIndex = 0; waveIndex < 10; waveIndex++) {
        float index = float(waveIndex);
        float ringRadius = waveFrontRadius - ringSpacing * index;
        float ringEnabled = step(index + 0.5, waveCount) * smoothstep(2.0, 16.0, ringRadius);
        float ring =
            exp(-pow((tapDistDesign - ringRadius) / ringWidth, 2.0)) -
            0.34 * exp(-pow((tapDistDesign - ringRadius + ringWidth * 0.72) / (ringWidth * 1.28), 2.0));
        finiteRipple += ring * ringEnabled * (1.0 - index * 0.075);
    }
    float rippleFade = exp(-waveProgress * 1.35 / max(shockTrail, 0.30));
    float rippleAmount =
        rippleAmplitude *
        finiteRipple *
        rippleEnvelope *
        rippleFade;
    float2 rippleDir = normalize(touchDeltaDesign + float2(0.001, 0.001));
    float2 shadertoyRippleWarp = rippleAmount * rippleDir;
    float shadertoyRippleLight = rippleAmount / max(rippleAmplitude, 1.0);

    // A continuous, soft water response that remains visible while the finger moves.
    float localWaterPressure =
        exp(-pow(tapDistDesign / max(92.0 * waveSpread, 1.0), 2.0)) *
        rippleEnvelope;
    float localWaterWave =
        finiteRipple *
        rippleEnvelope *
        rippleFade;
    float2 localWaterWarp =
        rippleDir *
        (
            localWaterWave * (5.2 + 2.0 * shockStrength) +
            localWaterPressure * 2.8
        );

    float frontNoise =
        12.0 * sin(p.y * 0.018 + time * 2.1) +
        7.0 * sin(p.y * 0.034 - time * 1.4);

    float frontDist = abs(p.x - tapPxDesign.x + frontNoise);
    float primaryFront =
        exp(-pow(frontDist / max(mix(46.0, 82.0, waveSpread), 1.0), 2.0)) *
        shockActive;

    float secondaryFront =
        exp(-pow((frontDist - mix(42.0, 128.0 * shockTrail, shockAge)) / max(mix(104.0, 162.0, waveSpread), 1.0), 2.0)) *
        shockActive *
        (0.72 - 0.26 * shockAge);

    float screenRing =
        exp(-pow((tapDistDesign - mix(42.0, 310.0 * shockTrail, shockAge)) / max(172.0 * safeWaveSpread, 1.0), 2.0)) *
        shockActive *
        (0.38 + 0.62 * tapPulse);

    float diagonalAxis =
        dot(touchDeltaDesign, normalize(float2(0.58 * shockSide, 0.82))) +
        18.0 * sin(p.y * 0.020 + time * 1.9);

    float diagonalWake =
        exp(-pow(diagonalAxis / max(150.0 * safeWaveSpread, 1.0), 2.0)) *
        exp(-pow(touchDeltaDesign.x / max(420.0 * safeShockTrail, 1.0), 2.0)) *
        shockActive *
        (0.46 + 0.36 * tapPulse);

    float causticPulse =
        (0.5 + 0.5 * sin(tapDistDesign * 0.050 - travelingPhase * 1.7 + shockAge * 8.2)) *
        screenRing *
        shockActive *
        (0.64 + 0.36 * shockInteraction);

    float crossingFront =
        primaryFront * secondaryFront +
        screenRing * diagonalWake;

    float interferenceField =
        (0.5 + 0.5 * sin(tapDistDesign * 0.042 - travelingPhase * 1.35)) *
        (0.5 + 0.5 * sin((touchDeltaDesign.x * shockSide + touchDeltaDesign.y * 0.54) * 0.034 + travelingPhase)) *
        shockActive *
        shockInteraction;

    float selfCoupling =
        clamp(crossingFront * (0.72 + 0.46 * shockInteraction) + interferenceField * 0.44, 0.0, 1.8);

    float compositeShock =
        primaryFront * 0.54 +
        secondaryFront * 0.38 +
        screenRing * 0.34 +
        diagonalWake * 0.28 +
        causticPulse * 0.16 +
        selfCoupling * 0.30;

    float touchPush =
        exp(-pow(tapDistDesign * 0.0052, 2.0)) *
        tapPulse *
        shockActive;

    float2 tapDir = normalize(p - tapPxDesign + float2(0.001, 0.001));
    float2 frontDir = normalize(float2(shockSide, 0.16 * sin(p.y * 0.021 + time * 1.7)));
    float2 diagonalDir = normalize(float2(0.46 * shockSide, 0.72));
    float2 tapWarp =
        shadertoyRippleWarp * (0.58 + 0.16 * waveStrength) +
        localWaterWarp +
        tapDir * touchPush * 6.0 +
        frontDir * compositeShock * 7.0 +
        diagonalDir * (diagonalWake + selfCoupling * 0.38) * 3.5 +
        float2(0.0, -1.0) * (causticPulse + interferenceField * 0.24) * 2.0;

    float centerPull =
        exp(-pow((p.x - 187.5) / 140.0, 2.0));

    float verticalFlowPull =
        centerPull *
        segmentEase(progress, 0.18, 0.92) *
        34.0 *
        waveStrength;

    float2 flowWarp = refractionWarp + tapWarp;
    float2 liquidFlowWarp = float2(0.0, flowWarp.y);

    pGlobal += liquidFlowWarp * 0.82;
    pGlobal.y += verticalFlowPull;

    float backSpeed = mix(0.70, 0.78, completed);
    float mainSpeed = mix(1.00, 0.92, completed);
    float rimSpeed = mix(1.30, 1.10, completed);

    float2 pShape1Back = pStretched + float2(horizontalDrift * 0.30, baseShiftY * backSpeed * 0.82);
    float2 pShape2Back = pStretched + float2(horizontalDrift * 0.40, baseShiftY * backSpeed * 0.96);
    float2 pWave1Back  = pStretched + float2(horizontalDrift * 0.48, baseShiftY * backSpeed * 0.92);
    float2 pWave2Back  = pStretched + float2(horizontalDrift * 0.50, baseShiftY * backSpeed * 1.04);

    float2 pShape1 = pStretched + float2(horizontalDrift * 0.55, baseShiftY * mainSpeed * 0.95);
    float2 pShape2 = pStretched + float2(horizontalDrift * 0.80, baseShiftY * mainSpeed * 1.12);
    float2 pBgUp   = pStretched + float2(horizontalDrift * 0.30, baseShiftY * mainSpeed * 0.34);
    float2 pWave1  = pStretched + float2(horizontalDrift * 1.05, baseShiftY * mainSpeed * 1.00);
    float2 pWave2  = pStretched + float2(horizontalDrift * 0.95, baseShiftY * mainSpeed * 1.16);

    float2 pRim1 = pStretched + float2(horizontalDrift * 1.28, baseShiftY * rimSpeed * 1.22);
    float2 pRim2 = pStretched + float2(horizontalDrift * 1.10, baseShiftY * rimSpeed * 1.30);

    pShape1Back += liquidFlowWarp * 0.18;
    pShape2Back += liquidFlowWarp * 0.24;
    pWave1Back += liquidFlowWarp * 0.28;
    pWave2Back += liquidFlowWarp * 0.30;

    pShape1 += liquidFlowWarp * 0.50;
    pShape2 += liquidFlowWarp * 0.58;
    pWave1 += liquidFlowWarp * 0.72;
    pWave2 += liquidFlowWarp * 0.68;

    pRim1 += liquidFlowWarp * 0.95;
    pRim2 += liquidFlowWarp * 0.88;

    float2 deepWarp = float2(
        0.0,
        cos(p.x * 0.010 + time * 0.32) * 8.0
    );

    pShape1Back += deepWarp * 0.22;
    pShape2Back += deepWarp * 0.28;
    pWave1Back += deepWarp * 0.34;
    pWave2Back += deepWarp * 0.36;

    pShape1 += deepWarp * 0.52;
    pShape2 += deepWarp * 0.60;
    pWave1 += deepWarp * 0.78;
    pWave2 += deepWarp * 0.72;

    pRim1 += deepWarp * 1.05;
    pRim2 += deepWarp * 0.96;

    // --------------------------------------------------
    // States from specs
    // --------------------------------------------------

    LayerState anim_wave_1 = makeState(
        float2(-38.0, 647.0),
        float2(-238.0, 476.0),
        float2(-121.0, 411.0),
        float2(-117.0, 151.0),

        float2(454.0, 300.0),
        float2(851.0, 562.0),
        float2(619.0, 409.0),
        float2(611.0, 405.0),

        1.00, 0.70, 1.00, 1.00,
        64.0, 64.0, 120.0, 160.0,
        progress
    );

    LayerState anim_wave_2 = makeState(
        float2(-99.0, 364.0),
        float2(-99.0, 442.0),
        float2(-218.0, 197.0),
        float2(-106.0, -107.0),

        float2(556.0, 298.0),
        float2(573.0, 307.0),
        float2(875.0, 466.0),
        float2(589.0, 316.0),

        1.00, 1.00, 1.00, 1.00,
        128.0, 160.0, 120.0, 88.0,
        progress
    );

    LayerState bg_up_02 = makeState(
        float2(-50.0, 37.0),
        float2(-32.0, 37.0),
        float2(-50.0, 37.0),
        float2(-50.0, 37.0),

        float2(475.0, 787.0),
        float2(440.0, 787.0),
        float2(475.0, 787.0),
        float2(475.0, 787.0),

        0.10, 1.00, 1.00, 1.00,
        64.0, 120.0, 64.0, 64.0,
        progress
    );

    LayerState shape_2 = makeState(
        float2(0.0, 705.0),
        float2(-44.0, 856.0),
        float2(-67.0, 663.0),
        float2(-50.0, 702.0),

        float2(375.0, 251.0),
        float2(463.0, 309.0),
        float2(509.0, 340.0),
        float2(475.0, 317.0),

        0.60, 0.70, 0.20, 1.00,
        88.0, 88.0, 88.0, 88.0,
        progress
    );

    LayerState shape_1 = makeState(
        float2(-50.0, 308.0),
        float2(-24.0, 351.0),
        float2(11.0, 78.0),
        float2(-50.0, 308.0),

        float2(475.0, 787.0),
        float2(423.0, 701.0),
        float2(353.0, 585.0),
        float2(475.0, 787.0),

        1.00, 1.00, 0.40, 1.00,
        64.0, 64.0, 146.0, 65.0,
        progress
    );

    // --------------------------------------------------
    // Back liquid layer
    // --------------------------------------------------

    float backShape1 = blueTrapField(
        pShape1Back,
        shape_1,
        87.3259 / 475.0,
        379.735 / 475.0,
        0.0,
        1.0,
        709.291 / 787.0,
        17.4917 / 787.0,
        0.72 * blueDepth
    );

    float backShape2 = blueTrapField(
        pShape2Back,
        shape_2,
        68.9415 / 375.0,
        299.791 / 375.0,
        0.0,
        1.0,
        226.216 / 251.0,
        5.57866 / 251.0,
        0.62 * blueDepth
    );

    float backWave1 = blueTrapField(
        pWave1Back,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        0.72 * blueDepth
    );

    float backWave2 = blueTrapField(
        pWave2Back,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        0.78 * blueDepth
    );

    float backMass = backShape1 + backShape2 + backWave1 + backWave2;
    float backAlpha = 1.0 - exp(-backMass * 0.86);
    backAlpha = clamp(backAlpha * bottomReveal * finalFade, 0.0, 1.0);

    // --------------------------------------------------
    // Main liquid layer
    // --------------------------------------------------

    float shape1Field = blueTrapField(
        pShape1,
        shape_1,
        87.3259 / 475.0,
        379.735 / 475.0,
        0.0,
        1.0,
        709.291 / 787.0,
        17.4917 / 787.0,
        1.08 * blueDepth
    );

    float shape2Field = blueTrapField(
        pShape2,
        shape_2,
        68.9415 / 375.0,
        299.791 / 375.0,
        0.0,
        1.0,
        226.216 / 251.0,
        5.57866 / 251.0,
        0.96 * blueDepth
    );

    float bgUpField = blueTrapField(
        pBgUp,
        bg_up_02,
        0.0,
        1.0,
        87.3259 / 475.0,
        379.735 / 475.0,
        77.709 / 787.0,
        769.508 / 787.0,
        1.03 * blueDepth
    );

    float wave2Field = blueTrapField(
        pWave2,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        1.25 * blueDepth
    );

    float wave1Field = blueTrapField(
        pWave1,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        1.18 * blueDepth
    );

    float svgBlueMass =
        shape1Field +
        shape2Field +
        bgUpField +
        wave1Field +
        wave2Field;

    float mainAlpha = 1.0 - exp(-svgBlueMass * 1.28);
    mainAlpha = clamp(mainAlpha * bottomReveal * finalFade, 0.0, 1.0);

    // --------------------------------------------------
    // Front rim liquid layer
    // --------------------------------------------------

    float rimWave1 = blueTrapField(
        pRim1,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        1.05
    );

    float rimWave2 = blueTrapField(
        pRim2,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        0.98
    );

    float rimAlpha = clamp((rimWave1 + rimWave2) * bottomReveal * rimFinalFade, 0.0, 1.0);
    rimAlpha = smoothstep(0.22, 0.88, rimAlpha);

    float massBreath =
        1.0 +
        0.025 * sin(time * 0.72) +
        0.014 * sin(time * 1.13);

    mainAlpha = clamp(mainAlpha * massBreath, 0.0, 1.0);
    backAlpha = clamp(backAlpha * (1.0 + 0.018 * sin(time * 0.55 + 1.2)), 0.0, 1.0);
    rimAlpha = clamp(rimAlpha * (1.0 + 0.016 * sin(time * 0.80 + 2.1)), 0.0, 1.0);

    float lateAlphaFade = lateTransparency;

    mainAlpha *= mix(1.0, 0.54, lateAlphaFade);
    backAlpha *= mix(1.0, 0.48, lateAlphaFade);
    rimAlpha *= mix(1.0, 0.36, lateAlphaFade);

    // --------------------------------------------------
    // Liquid color model
    // --------------------------------------------------

    float flow =
        0.023 * sin(pGlobal.x * 0.030 + time * 0.75 + rise * 2.2) +
        0.016 * sin(pGlobal.x * 0.070 - time * 0.55 + rise * 3.7) +
        0.011 * sin((pGlobal.x + pGlobal.y) * 0.035 + time * 0.45);

    float liquidY = clamp(
        uv.y * 0.74 + 0.14 + flow - rise * 0.14,
        0.0,
        1.0
    );

    // --------------------------------------------------
    // Delayed blue color ramp
    // --------------------------------------------------

    float blueEmergence = segmentEase(progress, 0.40, 0.56);
    float deepBlueEmergence = segmentEase(progress, 0.54, 0.78);
    float earlySoftness = 1.0 - blueEmergence;

    float targetBluePhase =
        segmentEase(progress, 0.50, 0.62) *
        (1.0 - segmentEase(progress, 0.80, 0.94));

    float3 softAqua = mix(
        cyan,
        aqua,
        0.62
    );

    float3 softBlue = mix(
        aqua,
        targetBlue,
        0.46
    );

    float3 backColor = mix(
        softAqua,
        softBlue,
        smoothstep(0.16, 0.88, liquidY) * blueEmergence
    );

    backColor = mix(
        backColor,
        targetBlue,
        targetBluePhase * 0.72
    );

    backColor = mix(
        backColor,
        mix(targetBlue, deepBlue, 0.26),
        smoothstep(0.78, 1.0, liquidY) * deepBlueEmergence * 0.38
    );

    float3 mainColor = mix(
        cyan,
        aqua,
        smoothstep(0.02, 0.48, liquidY)
    );

    mainColor = mix(
        mainColor,
        softBlue,
        smoothstep(0.34, 0.78, liquidY) * blueEmergence
    );

    mainColor = mix(
        mainColor,
        targetBlue,
        smoothstep(0.44, 0.88, liquidY) * blueEmergence * 0.78
    );

    mainColor = mix(
        mainColor,
        targetBlue,
        targetBluePhase * 0.86
    );

    mainColor = mix(
        mainColor,
        mix(targetBlue, deepBlue, 0.22),
        smoothstep(0.78, 1.0, liquidY) * deepBlueEmergence * 0.42
    );

    mainColor = mix(
        mainColor,
        mix(cyan, aqua, 0.54),
        earlySoftness * 0.38
    );

    backColor = mix(
        backColor,
        mix(cyan, aqua, 0.46),
        earlySoftness * 0.32
    );

    float3 rimColor = mix(
        electric,
        cyan,
        smoothstep(0.0, 1.0, liquidY)
    );

    rimColor = mix(
        rimColor,
        mix(cyan, aqua, 0.52),
        earlySoftness * 0.28
    );

    rimColor = mix(
        rimColor,
        mix(targetBlue, cyan, 0.22),
        targetBluePhase * 0.56
    );

    float3 result = white;

    result = plusDarkerApprox(
        result,
        backColor,
        backAlpha * 0.72
    );

    result = plusDarkerApprox(
        result,
        mainColor,
        mainAlpha
    );

    result += rimColor * rimAlpha * 0.035;

    // --------------------------------------------------
    // Idle wave render
    // --------------------------------------------------

    float idleLuminanceBefore = dot(result, float3(0.299, 0.587, 0.114));

    float idleBlueOnWhite =
        idleWaveEnergy *
        smoothstep(0.56, 1.0, idleLuminanceBefore);

    float idleWhiteOnBlue =
        idleWaveEnergy *
        (1.0 - smoothstep(0.35, 0.88, idleLuminanceBefore));

    result = mix(
        result,
        min(result, waveMid),
        idleBlueOnWhite * 0.22
    );

    result += idleBlueOnWhite * waveDeep * 0.08;
    result += idleWhiteOnBlue * waveGlass * 0.14;
    result += idleWaveEnergy * waveEdge * 0.10;

    // --------------------------------------------------
    // Organic reveal edge glow + surface tension
    // --------------------------------------------------

    result += revealEdgeGlow * float3(0.25, 0.82, 1.0);
    result += revealEdgeGlow * float3(0.75, 1.00, 1.0) * 0.32;

    result += tensionCore * float3(0.56, 1.00, 1.0) * 0.34;

    result += liquidRimLine * float3(0.75, 1.0, 1.0) * 0.18;
    result += liquidRimLine * float3(0.10, 0.55, 1.0) * 0.08;

    result = plusDarkerApprox(
        result,
        deepBlue,
        tensionShadow * 0.18
    );

    // --------------------------------------------------
    // Surface glow
    // --------------------------------------------------

    float liquidAlpha = clamp(mainAlpha + backAlpha * 0.52, 0.0, 1.0);
    float surfaceEnergy = liquidAlpha * (1.0 - liquidAlpha);

    float surfaceGlow = smoothstep(0.08, 0.25, surfaceEnergy);

    result += surfaceGlow * float3(0.10, 0.56, 1.0) * 0.10 * finalFade;
    result += surfaceGlow * float3(0.56, 1.00, 1.0) * 0.045 * finalFade;

    // --------------------------------------------------
    // Bottom clearing
    // --------------------------------------------------

    float bottomClearPower = mix(
        0.38,
        0.68,
        bottomCleanProgress
    );

    result = plusLighterApprox(
        result,
        white,
        min(bottomClear * bottomClearPower, 0.68)
    );

    liquidAlpha *= (1.0 - bottomClear * 0.82);

    // --------------------------------------------------
    // Central white glass lens
    // --------------------------------------------------

    float circleSoftness = mix(
        38.0,
        92.0,
        circleGrowth
    );

    float angle = atan2(
        p.y - center.y,
        p.x - center.x
    );

    float circleNoiseFade = 1.0 - segmentEase(progress, 0.88, 1.00);

    float circleNoise =
        (
            4.2 * sin(angle * 3.0 + time * 0.50) +
            2.6 * sin(angle * 7.0 - time * 0.38)
        ) * circleNoiseFade;

    float circleDist =
        distance(p, center) -
        circleRadius +
        circleNoise;

    float circleFill = 1.0 - smoothstep(
        -circleSoftness * 0.52,
        circleSoftness,
        circleDist
    );

    float circleVisibility = mix(
        0.68,
        0.98,
        smoothstep(0.0, 0.75, progress)
    );

    float visibleCircleFill = circleFill * circleAppear;

    result += visibleCircleFill * circleVisibility * float3(0.12, 0.74, 1.0) * 0.030;

    float circleEdge = exp(-abs(circleDist) / 30.0);
    float tightCircleRim = exp(-abs(circleDist) / 10.0);

    float innerRim = circleEdge * visibleCircleFill * 0.20;

    result += innerRim * float3(0.35, 0.88, 1.0);

    float lensLowerShadow =
        visibleCircleFill *
        smoothstep(center.y - circleRadius * 0.10, center.y + circleRadius * 0.72, p.y) *
        0.055;

    result = mix(
        result,
        result * float3(0.965, 0.985, 1.0),
        lensLowerShadow
    );

    float contactGlow =
        circleEdge *
        liquidAlpha *
        circleAppear *
        (1.0 - circleFill * 0.38);

    float contactTightRim =
        tightCircleRim *
        liquidAlpha *
        circleAppear *
        (1.0 - circleFill * 0.22);

    float magneticPull = segmentEase(progress, 0.35, 0.85);

    float chromaticEdge =
        tightCircleRim *
        liquidAlpha *
        circleAppear *
        (0.35 + 0.65 * magneticPull);

    // Лёгкая хроматическая аберрация при столкновении с центральной маской.
    float2 dirFromCenter = normalize(p - center + float2(0.0001, 0.0001));
    float2 chromaAxis = normalize(float2(0.86, -0.34));

    float chromaDot = dot(dirFromCenter, chromaAxis);
    float redSide = smoothstep(-0.15, 1.0, chromaDot);
    float cyanSide = smoothstep(-0.15, 1.0, -chromaDot);

    result.r += chromaticEdge * redSide * 0.010 * finalFade;
    result.g += chromaticEdge * cyanSide * 0.010 * finalFade;
    result.b += chromaticEdge * cyanSide * 0.022 * finalFade;

    result += contactGlow * float3(0.12, 0.68, 1.0) * (0.76 + magneticPull * 0.18) * finalFade;
    result += contactGlow * float3(0.68, 1.00, 1.0) * (0.30 + magneticPull * 0.12) * finalFade;
    result += contactTightRim * float3(0.72, 1.00, 1.0) * (0.22 + magneticPull * 0.10) * finalFade;

    float innerHalo = exp(
        -max(distance(p, center) - circleRadius * 0.54, 0.0) / 78.0
    );

    result = mix(
        result,
        white,
        innerHalo * 0.11 * circleVisibility * circleAppear
    );

    // --------------------------------------------------
    // Tap blob / residual trail
    // --------------------------------------------------

    float2 tapPx = tapPoint * size;
    float tapDist = distance(position, tapPx);

    float tapTrail =
        exp(-pow(tapDist * 0.010, 2.0)) *
        tapPulse *
        mainAlpha *
        0.10;

    float tapBlobNoise =
        sin(position.x * 0.035 + time * 1.8) *
        sin(position.y * 0.026 - time * 1.3);

    tapTrail *= smoothstep(-0.15, 0.75, tapBlobNoise);

    result += tapTrail * white * finalFade;

    float screenTrailNoise =
        20.0 * sin(uv.y * 13.0 + time * 1.85) +
        12.0 * sin(uv.y * 27.0 - time * 1.10);

    float2 touchDeltaPx = position - tapPx;
    float touchSide = touchDeltaPx.x >= 0.0 ? 1.0 : -1.0;
    float visualShock = dragWave * shockStrength;
    float screenTrailDist = abs(touchDeltaPx.x + screenTrailNoise);
    float screenTrail =
        exp(-pow(screenTrailDist / max(62.0 * waveSpread * shockTrail, 1.0), 2.0)) *
        visualShock *
        mainAlpha *
        finalFade *
        0.22;

    float secondaryTrail =
        exp(-pow((screenTrailDist - mix(70.0, 178.0 * shockTrail, 1.0 - tapPulse)) / max(104.0 * waveSpread, 1.0), 2.0)) *
        visualShock *
        (0.64 + 0.36 * tapPulse) *
        mainAlpha *
        finalFade *
        0.20;

    float diagonalTrailAxis =
        dot(touchDeltaPx, normalize(float2(0.55 * touchSide, 0.83))) +
        22.0 * sin(uv.y * 16.0 + time * 1.6);

    float diagonalTrail =
        exp(-pow(diagonalTrailAxis / max(170.0 * waveSpread, 1.0), 2.0)) *
        exp(-pow(touchDeltaPx.x / max(size.x * 0.82 * shockTrail, 1.0), 2.0)) *
        visualShock *
        mainAlpha *
        finalFade *
        0.18;

    float screenRipple =
        exp(-pow((tapDist - mix(96.0, max(size.x, size.y) * 0.76 * shockTrail, 1.0 - tapPulse)) / max(124.0 * waveSpread, 1.0), 2.0)) *
        visualShock *
        (0.35 + 0.65 * tapPulse) *
        mainAlpha *
        finalFade;

    float causticLines =
        (0.5 + 0.5 * sin(tapDist * 0.062 - time * (6.2 + 1.8 * shockInteraction) + (1.0 - tapPulse) * 7.8)) *
        screenRipple *
        visualShock *
        (0.62 + 0.38 * shockInteraction);

    float wakeCrossing =
        (screenTrail * secondaryTrail + diagonalTrail * screenRipple) *
        (0.76 + 0.44 * shockInteraction);

    float wakeInterference =
        (0.5 + 0.5 * sin(tapDist * 0.040 - time * 5.1)) *
        (0.5 + 0.5 * sin((touchDeltaPx.x * touchSide + touchDeltaPx.y * 0.42) * 0.032 + time * 4.2)) *
        visualShock *
        shockInteraction *
        mainAlpha *
        finalFade;

    float compositeWake =
        screenTrail * 0.48 +
        secondaryTrail * 0.36 +
        diagonalTrail * 0.30 +
        screenRipple * 0.28 +
        causticLines * 0.18 +
        wakeCrossing * 0.42 +
        wakeInterference * 0.16;

    result += screenTrail * white * 0.040;
    result += secondaryTrail * white * 0.032;
    result += diagonalTrail * white * 0.034;
    result += screenRipple * white * 0.044;
    result += causticLines * white * 0.026;
    result += wakeCrossing * white * 0.035;
    result += wakeInterference * white * 0.024;

    // --------------------------------------------------
    // Top reservoir + cinematic finish
    // --------------------------------------------------

    float3 stableFinishColor = mix(
        targetBlue,
        cyan,
        0.18
    );

    float3 initialBottomLikeColor = stableFinishColor;

    float topBreath =
        1.0 +
        completed *
        (
            0.08 * sin(time * 1.55) +
            0.035 * sin(time * 2.25)
        );

    float finalCoreSoft = 1.0 - 0.50 * finalBlur;
    float finalMistBoost = 1.0 + 1.25 * finalBlur;

    float topReservoir =
        exp(-uv.y * 3.20) *
        topReservoirProgress *
        0.38 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topReservoirCore =
        exp(-uv.y * 7.00) *
        topReservoirProgress *
        0.30 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topReservoirGlow =
        exp(-pow((uv.y - 0.125) / 0.26, 2.0)) *
        topReservoirProgress *
        0.13 *
        topBreath *
        finalFade *
        finalMistBoost;

    result = plusDarkerApprox(
        result,
        initialBottomLikeColor,
        topReservoir
    );

    result = plusDarkerApprox(
        result,
        mix(targetBlue, deepBlue, 0.18),
        topReservoirCore
    );

    result += topReservoirGlow * float3(0.22, 0.80, 1.0);

    float finish = topCapProgress;

    float topCapAlpha =
        exp(-uv.y * 4.8) *
        finish *
        0.34 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topCapMist =
        exp(-uv.y * 1.22) *
        finish *
        0.13 *
        topBreath *
        finalFade *
        finalMistBoost;

    result = plusDarkerApprox(
        result,
        initialBottomLikeColor,
        topCapAlpha
    );

    result = plusDarkerApprox(
        result,
        mix(targetBlue, deepBlue, 0.14),
        topCapMist
    );

    result += topCapAlpha * float3(0.10, 0.46, 1.0) * 0.10;
    result += topCapMist * float3(0.42, 0.95, 1.0) * 0.045;

    float3 completionMistColor = mix(
        targetBlue,
        cyan,
        0.22
    );

    float completionMist =
        exp(-uv.y * 1.05) *
        completionMistProgress *
        0.12 *
        finalFade *
        finalMistBoost;

    float trailingGlow =
        exp(-pow((uv.y - 0.18) / 0.22, 2.0)) *
        finalBlur *
        0.10 *
        finalFade;

    result += completionMist * completionMistColor;
    result += trailingGlow * float3(0.30, 0.92, 1.0);

    result += completionFlash * float3(0.45, 0.95, 1.0) * 0.08;

    float completionPulse =
        completionBloom *
        (1.0 - 0.35 * sin(time * 2.4));

    float completionTopGlow =
        exp(-uv.y * 4.2) *
        completionPulse *
        0.06 *
        finalFade;

    result += completionTopGlow * float3(0.30, 0.82, 1.0);
    result = mix(result, white, completionBloom * bottomClear * 0.025);

    // --------------------------------------------------
    // Adaptive tap shockwave
    // --------------------------------------------------

    float rippleRadius = (1.0 - tapPulse) * mix(92.0, 310.0, dragWave);

    float rippleRing =
        exp(-pow((tapDist - rippleRadius) * 0.0064, 2.0)) *
        dragWave *
        (0.28 + 0.72 * tapPulse) *
        mix(0.7, 1.15, waveStrength);

    float rippleCore =
        exp(-pow(tapDist * 0.010, 2.0)) *
        dragWave *
        0.10 *
        waveStrength;

    float luminance = dot(result, float3(0.299, 0.587, 0.114));

    float blueRingStrength = rippleRing * smoothstep(0.60, 1.0, luminance);
    float whiteRingStrength = rippleRing * (1.0 - smoothstep(0.40, 0.90, luminance));

    float frontBand =
        localWaterPressure * 0.34 +
        abs(localWaterWave) * 0.30 +
        compositeWake * 0.24;

    float glassSheen =
        smoothstep(0.42, 1.0, compositeWake + frontBand) *
        (0.5 + 0.5 * sin(position.y * 0.030 - time * 4.5 + tapDist * 0.015)) *
        visualShock;

    result = mix(
        result,
        white,
        blueRingStrength * 0.08 + frontBand * 0.035
    );

    result += blueRingStrength * white * 0.035;

    result += whiteRingStrength * white * 0.10;
    result += rippleCore * white * 0.08;
    result += frontBand * white * 0.045;
    result += glassSheen * white * 0.026;
    result += max(localWaterWave, 0.0) * white * 0.16;
    result = mix(
        result,
        white,
        max(-localWaterWave, 0.0) * 0.030
    );

    // --------------------------------------------------
    // Keyframe-matched hero wash
    // --------------------------------------------------

    float keyProgress = clamp(progress, 0.0, 0.82);
    float keyPresence = smoothstep(0.02, 0.18, keyProgress) * fillGain;

    float keyedEdgeY = interpKeys(
        0.86,
        0.62,
        0.38,
        -0.10,
        keyProgress
    );

    float keyedFeather = interpKeys(
        0.16,
        0.22,
        0.31,
        0.27,
        keyProgress
    );

    float keyDx = uv.x - 0.5;

    float keyedSag =
        keyDx * keyDx *
        interpKeys(0.26, 0.32, 0.24, -0.30, keyProgress);

    float keyedEdgeNoise =
        0.012 * sin(uv.x * 9.0 + time * 0.24 + keyProgress * 4.0) +
        0.007 * sin(uv.x * 21.0 - time * 0.16 + keyProgress * 7.0) +
        dragWave * 0.018 * sin(uv.x * 13.0 + time * 0.36);

    float keyedLowerMass = smoothstep(
        keyedEdgeY - keyedFeather,
        keyedEdgeY + keyedFeather,
        uv.y + keyedSag + keyedEdgeNoise
    );

    float lowerFade = 1.0 - segmentEase(keyProgress, 0.62, 0.90);
    keyedLowerMass *= keyPresence * lowerFade;

    float keyedBottomWeight = smoothstep(0.28, 0.96, uv.y);
    float keyedLowerCore = keyedLowerMass * keyedBottomWeight * 0.88;

    float keyedCyanBand =
        exp(-pow((uv.y - keyedEdgeY) / max(keyedFeather * 1.18, 0.01), 2.0)) *
        exp(-pow(keyDx / 0.62, 2.0)) *
        keyPresence *
        lowerFade;

    float3 keyedBlueColor = mix(
        targetBlue,
        blue,
        0.10 + 0.18 * smoothstep(0.20, 0.46, keyProgress)
    );

    keyedBlueColor = mix(
        keyedBlueColor,
        mix(targetBlue, deepBlue, 0.12),
        smoothstep(0.50, 0.74, keyProgress) * smoothstep(0.58, 1.0, uv.y)
    );

    float3 keyedLowerColor = mix(
        mix(cyan, aqua, 0.50),
        keyedBlueColor,
        smoothstep(0.48, 1.0, uv.y)
    );

    result = plusDarkerApprox(
        result,
        keyedLowerColor,
        keyedLowerCore * 0.42 * fillGain
    );

    result += keyedCyanBand * float3(0.38, 0.88, 1.0) * 0.045 * waveStrength;

    float lensY = interpKeys(
        0.74,
        0.56,
        0.59,
        0.31,
        keyProgress
    );

    float lensRX = interpKeys(
        0.55,
        0.62,
        0.60,
        0.57,
        keyProgress
    );

    float lensRY = interpKeys(
        0.21,
        0.19,
        0.20,
        0.19,
        keyProgress
    );

    float lensTopFade =
        smoothstep(0.08, 0.24, keyProgress) *
        (1.0 - segmentEase(keyProgress, 0.88, 1.0));

    float lensD =
        pow((uv.x - 0.5) / max(lensRX, 0.01), 2.0) +
        pow((uv.y - lensY) / max(lensRY, 0.01), 2.0);

    float keyedWhiteLens =
        (1.0 - smoothstep(0.56, 1.48, lensD)) *
        lensTopFade;

    float keyedLensHalo =
        exp(-pow((sqrt(max(lensD, 0.0)) - 0.88) / 0.46, 2.0)) *
        lensTopFade;

    result += keyedWhiteLens * float3(0.18, 0.74, 1.0) * 0.030 * whiteCore;
    result += keyedLensHalo * float3(0.44, 0.92, 1.0) * 0.055 * whiteCore;

    float topPhase =
        segmentEase(keyProgress, 0.58, 0.84) *
        (1.0 - segmentEase(keyProgress, 0.94, 1.0));

    float topCurve =
        0.24 +
        keyDx * keyDx * 0.62 +
        0.011 * sin(uv.x * 8.0 + time * 0.20);

    float topCap =
        (1.0 - smoothstep(topCurve - 0.16, topCurve + 0.24, uv.y)) *
        topPhase;

    float topCore =
        exp(-uv.y * 3.1) *
        topPhase;

    float topMistBand =
        exp(-pow((uv.y - topCurve) / 0.26, 2.0)) *
        exp(-pow(keyDx / 0.78, 2.0)) *
        topPhase;

    float3 topKeyColor = mix(
        targetBlue,
        blue,
        0.16 * topBloom
    );

    result = plusDarkerApprox(
        result,
        topKeyColor,
        clamp(topCap * 0.46 + topCore * 0.12, 0.0, 1.0)
    );

    result += topMistBand * float3(0.56, 1.0, 1.0) * 0.13 * topBloom;

    float topWhiteBowl =
        (1.0 - smoothstep(0.62, 1.30, lensD)) *
        topPhase *
        0.70 * whiteCore;

    result += topWhiteBowl * float3(0.14, 0.62, 1.0) * 0.025;

    float2 swipeNow = float2((tapPoint.x - 0.5) * (safeSize.x / safeSize.y) + 0.5, tapPoint.y);
    float2 swipePrevious = float2((previousTouchPoint.x - 0.5) * (safeSize.x / safeSize.y) + 0.5, previousTouchPoint.y);
    float2 swipeUv = float2((uv.x - 0.5) * (safeSize.x / safeSize.y) + 0.5, uv.y);
    float2 swipePath = swipeNow - swipePrevious;
    float swipePathLength = length(swipePath);
    float swipeMovement = smootherLiquid(smoothstep(0.002, 0.030, swipePathLength));
    float swipeEnergy = swipePulse * swipeMovement * smoothstep(0.010, 0.16, swipeStrength);
    float2 swipeDir = swipePath / max(swipePathLength, 0.0001);
    float2 swipeNormal = float2(-swipeDir.y, swipeDir.x);
    float2 swipeCenter = mix(swipePrevious, swipeNow, 0.54);
    float2 swipeDelta = swipeUv - swipeCenter;
    float swipeAlong = dot(swipeDelta, swipeDir);
    float swipeLateral = dot(swipeDelta, swipeNormal);
    float swipeLength = mix(0.26, 0.48, smoothstep(0.004, 0.070, swipePathLength));
    float swipeWidth = mix(0.105, 0.172, smoothstep(0.012, 0.30, swipeStrength));
    float swipeBody =
        (1.0 - smoothstep(swipeLength * 0.42, swipeLength * 0.64, abs(swipeAlong))) *
        exp(-pow(swipeLateral / max(swipeWidth, 0.001), 2.0));
    float swipeCore =
        (1.0 - smoothstep(swipeLength * 0.18, swipeLength * 0.46, abs(swipeAlong))) *
        exp(-pow(swipeLateral / max(swipeWidth * 0.52, 0.001), 2.0));
    float swipeTail =
        smoothstep(-swipeLength * 0.62, -swipeLength * 0.08, swipeAlong) *
        (1.0 - smoothstep(swipeLength * 0.08, swipeLength * 0.60, swipeAlong)) *
        exp(-pow(swipeLateral / max(swipeWidth * 1.28, 0.001), 2.0));
    float swipeRipple =
        0.5 + 0.5 * sin(swipeAlong * 34.0 - swipeLateral * 13.0 + time * 1.8);
    float swipeSmear = clamp((swipeBody * 0.72 + swipeCore * 0.34 + swipeTail * 0.42) * swipeEnergy, 0.0, 1.0);
    float swipeGlassEdge =
        exp(-pow((abs(swipeLateral) - swipeWidth * 0.72) / max(swipeWidth * 0.36, 0.001), 2.0)) *
        (1.0 - smoothstep(swipeLength * 0.38, swipeLength * 0.66, abs(swipeAlong))) *
        swipeEnergy;
    float swipeAura =
        exp(-pow(swipeLateral / max(swipeWidth * 1.72, 0.001), 2.0)) *
        (1.0 - smoothstep(swipeLength * 0.48, swipeLength * 0.82, abs(swipeAlong))) *
        swipeEnergy;
    float swipeFlow =
        (0.5 + 0.5 * sin(swipeAlong * 13.0 - time * 2.2)) *
        exp(-pow(swipeLateral / max(swipeWidth * 1.08, 0.001), 2.0)) *
        swipeEnergy;

    result = mix(
        result,
        white,
        clamp(swipeSmear * (0.66 + swipeCore * 0.28), 0.0, 0.82)
    );
    result = plusDarkerApprox(
        result,
        white,
        clamp(swipeAura * 0.18 + swipeFlow * 0.08, 0.0, 0.24)
    );
    result += swipeSmear * white * 0.050;
    result += swipeGlassEdge * white * (0.044 + swipeRipple * 0.024);

    float grainMask = clamp(
        liquidAlpha +
        backAlpha * 0.55 +
        mainAlpha * 0.35 +
        topReservoirProgress * 0.30 +
        idleWaveEnergy * 0.30,
        0.0,
        1.0
    );

    float grain = (hashLiquid(position + float2(time * 0.37)) - 0.5);

    result += grain * mix(0.0012, 0.0052, grainMask) * finalFade;

    float rippleShade = clamp(shadertoyRippleLight, -1.0, 1.0) * rippleEnvelope;
    result += rippleShade * white * 0.14;
    result = mix(
        result,
        white,
        max(-rippleShade, 0.0) * 0.035
    );

    float3 lightResult = clamp(result, 0.0, 1.0);

    float3 preThemeMotionResult = lightResult;
    float3 darkSourceLightResult = lightResult;

    float motionColorRestore = clamp(
        tapTrail * 2.10 +
        screenTrail * 2.40 +
        secondaryTrail * 2.00 +
        diagonalTrail * 1.85 +
        screenRipple * 1.65 +
        compositeWake * 1.45 +
        frontBand * 1.55 +
        swipeSmear * 1.95 +
        swipeAura * 1.35 +
        swipeGlassEdge * 1.70 +
        abs(rippleShade) * 1.40,
        0.0,
        1.0
    );
    motionColorRestore = smootherLiquid(motionColorRestore);

    float yellowColoredPresence =
        smoothstep(0.018, 0.27, distance(lightResult, white)) *
        (1.0 - motionColorRestore * 0.98);
    float yellowProgressPresence = smoothstep(0.025, 0.16, progress);
    float yellowWarmDepth = smoothstep(0.46, 1.0, uv.y);
    float yellowTopGlow = 1.0 - smoothstep(0.16, 0.58, uv.y);
    float yellowBottomGlow = smoothstep(0.55, 1.0, uv.y);

    float3 yellowLemon = float3(1.0, 0.975, 0.035);
    float3 yellowSoft = float3(1.0, 0.955, 0.24);
    float3 yellowAmber = float3(1.0, 0.635, 0.060);
    float3 yellowTarget = mix(yellowLemon, yellowAmber, smootherLiquid(yellowWarmDepth));
    yellowTarget = mix(yellowTarget, yellowSoft, yellowTopGlow * 0.24);
    yellowTarget = mix(yellowTarget, yellowAmber, yellowBottomGlow * 0.20);

    float yellowWhiteCenterY =
        0.515 +
        0.020 * sin(time * 0.18 + progress * 4.2);

    float yellowWhiteCenterD =
        pow((uv.x - 0.50) / 0.73, 2.0) +
        pow((uv.y - yellowWhiteCenterY) / 0.205, 2.0);

    float yellowWhiteCenter =
        (1.0 - smoothstep(0.58, 1.34, yellowWhiteCenterD)) *
        yellowProgressPresence *
        (1.0 - segmentEase(progress, 0.94, 1.0) * 0.16);

    float yellowTopWash =
        exp(-pow((uv.y - 0.145) / 0.34, 2.0)) *
        yellowColoredPresence *
        0.18;

    float yellowBottomWash =
        exp(-pow((uv.y - 0.955) / 0.30, 2.0)) *
        yellowColoredPresence *
        0.26;

    lightResult = mix(
        lightResult,
        yellowTarget,
        isYellowPreset * clamp(yellowColoredPresence * 0.92, 0.0, 0.92)
    );

    lightResult = mix(
        lightResult,
        white,
        isYellowPreset * clamp(yellowWhiteCenter * 0.84, 0.0, 0.86)
    );

    lightResult += isYellowPreset * yellowTopWash * float3(1.0, 0.96, 0.08);
    lightResult += isYellowPreset * yellowBottomWash * float3(1.0, 0.53, 0.03);
    lightResult = clamp(lightResult, 0.0, 1.0);
    lightResult = mix(
        lightResult,
        preThemeMotionResult,
        isYellowPreset * motionColorRestore
    );

    // Shared travelling-band timing; each light preset applies its own palette below.
    float referenceBandCenter;
    float referenceBandWidth;
    if (progress <= 0.50) {
        float phase = smootherLiquid(progress / 0.50);
        referenceBandCenter = bandMotion(1.105, 0.855, 0.0, -0.838028, progress / 0.50, 0.50);
        referenceBandWidth = mix(0.205, 0.315, phase);
    } else if (progress <= 0.70) {
        float phase = smootherLiquid((progress - 0.50) / 0.20);
        referenceBandCenter = bandMotion(0.855, 0.515, -0.838028, -1.676693, (progress - 0.50) / 0.20, 0.20);
        referenceBandWidth = mix(0.315, 0.285, phase);
    } else {
        float phase = smootherLiquid((progress - 0.70) / 0.30);
        referenceBandCenter = bandMotion(0.515, 0.020, -1.676693, 0.0, (progress - 0.70) / 0.30, 0.30);
        referenceBandWidth = mix(0.285, 0.235, phase);
    }

    // Yellow follows the established Blue entry; Blue geometry stays unchanged.
    referenceBandCenter -= clamp(isBluePreset + isYellowPreset, 0.0, 1.0) * 0.065 * smoothstep(0.0, 0.05, progress) *
        (1.0 - segmentEase(progress, 0.26, 0.45));
    // Continue the shared mass upward after 90%, without changing the clock.
    referenceBandCenter -= 0.075 * segmentEase(progress, 0.90, 1.0);

    float referenceWarp =
        sin(uv.x * 5.7 + time * 0.11) * 0.018 +
        sin(uv.x * 10.4 - time * 0.08 + 1.2) * 0.008;
    float referenceDistance = uv.y + referenceWarp - referenceBandCenter;
    float referenceOuter = exp(-pow(referenceDistance / referenceBandWidth, 2.0));
    float referenceBody = exp(-pow(referenceDistance / (referenceBandWidth * 0.70), 2.0));
    float referenceCore = exp(-pow(referenceDistance / (referenceBandWidth * 0.34), 2.0));
    float referenceEntry = smoothstep(0.002, 0.020, progress);
    referenceOuter *= referenceEntry;
    referenceBody *= referenceEntry;
    referenceCore *= referenceEntry;

    float3 referenceCyan = float3(0.380, 0.910, 1.000);
    float3 referenceBlue = float3(0.259, 0.545, 0.976); // #428BF9
    float3 referenceBlueAccent = float3(0.000, 0.424, 1.000); // #006CFF
    // One broad pigment profile avoids the narrow accent stripe produced by
    // compositing several differently sized blue cores over one another.
    float blueLightDensity = exp(-pow(referenceDistance / (referenceBandWidth * 0.82), 2.0)) * referenceEntry;
    float3 blueLightPigment = mix(referenceCyan, mix(referenceBlue, referenceBlueAccent, 0.36),
        blueLightDensity * blueLightDensity * 0.85);
    float3 referenceBlueResult = mix(white, blueLightPigment,
        referenceOuter * (0.82 + 0.16 * blueLightDensity));

    // Match Blue Light's monotonic depth profile: orange in the dense body,
    // #FFDD2D in the shoulder, then yellow coverage dissolving into white.
    float yellowOrangeWeight = pow(blueLightDensity, 4.0) * 0.60;
    float3 yellowLightOrange = mix(yellowMidColor.rgb, yellowHotColor.rgb, 0.25);
    float3 yellowLightPigment = mix(yellowLightAccent, yellowLightOrange, yellowOrangeWeight);
    float3 referenceYellowResult = mix(white, yellowLightPigment,
        referenceOuter * (0.82 + 0.16 * blueLightDensity));

    lightResult = mix(lightResult, referenceBlueResult, isBluePreset);
    lightResult = mix(lightResult, referenceYellowResult, isYellowPreset);

    float liquidPresence = clamp(distance(darkSourceLightResult, white) * 1.38, 0.0, 1.0);
    float glowPresence = clamp(
        liquidPresence +
        rimAlpha * 0.32 +
        revealEdgeGlow * 0.50 +
        surfaceGlow * 0.22,
        0.0,
        1.0
    );
    float finishLift = segmentEase(progress, 0.76, 1.00);
    float bottomWeightDark = smoothstep(0.32, 1.0, uv.y);
    float topWeightDark = 1.0 - smoothstep(0.10, 0.46, uv.y);
    float finishTopPush =
        finishLift *
        (1.0 - smoothstep(0.11, 0.48, uv.y)) *
        (0.78 + 0.22 * exp(-pow((uv.y - 0.08) / 0.17, 2.0)));
    float sideGlowDark =
        exp(-pow(uv.x / 0.13, 2.0)) +
        exp(-pow((1.0 - uv.x) / 0.13, 2.0));

    float darkLowerField = clamp(
        glowPresence * (0.56 + bottomWeightDark * 0.42) +
        keyedLowerCore * 0.92 +
        keyedCyanBand * 0.44 +
        liquidAlpha * bottomWeightDark * 0.54 +
        surfaceGlow * 0.22,
        0.0,
        1.0
    );
    darkLowerField *= mix(1.0, 0.015, finishLift);

    float darkTopField = clamp(
        topPhase * (topCap * 0.80 + topCore * 0.34 + topMistBand * 0.72) +
        topReservoir * 0.72 +
        topReservoirCore * 0.54 +
        topReservoirGlow * 0.80 +
        completionMist * 0.82 +
        trailingGlow * 0.70 +
        completionTopGlow * 0.80 +
        finishLift * topWeightDark * 1.04 +
        finishTopPush * 0.42,
        0.0,
        1.0
    );

    // The dark palette always starts on a true black canvas. The selected color is
    // revealed only by the progressing field, never inherited from the light result.
    float darkColorReveal = smoothstep(0.015, 0.24, progress);
    darkLowerField *= darkColorReveal;
    darkTopField *= darkColorReveal;

    float cyanWashDark = clamp(
        keyedCyanBand * 0.70 +
        keyedLensHalo * 0.30 +
        revealEdgeGlow * 0.72 +
        rimAlpha * 0.24,
        0.0,
        1.0
    ) * darkColorReveal;

    // One soft, asymmetric reduction of light behind the digits; no ring or
    // constant-radius plateau. Coordinates match the existing counter region.
    float counterDrift = sin(time * 0.16) * 0.006;
    float2 counterDelta = float2(
        (uv.x - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.29,
        (uv.y - 0.475 + sin(uv.x * 8.0 + 0.8) * 0.016 + counterDrift) / 0.090
    );
    float2 counterLobe = float2((uv.x - 0.57) / 0.23, (uv.y - 0.45 + counterDrift) / 0.105);
    float counterProtection = 0.76 * exp(-dot(counterDelta, counterDelta)) +
        0.24 * exp(-dot(counterLobe, counterLobe));
    // A diffuse light pocket restores the clean light-theme counter area
    // without the former circular stroke or stacked glass-lens masks.
    lightResult = mix(lightResult, white, counterProtection * 0.32);

    float centerVoidD =
        pow((uv.x - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.354, 2.0) +
        pow((uv.y - 0.475 + sin(uv.x * 8.0 + 0.8) * 0.014) / 0.150, 2.0);
    float centerVoid = (1.0 - smoothstep(0.36, 1.68, centerVoidD)) *
        mix(0.56, 0.82, smoothstep(0.02, 0.58, progress));
    float centerVoidSoft = (1.0 - smoothstep(0.58, 2.55, centerVoidD)) *
        mix(0.18, 0.32, smoothstep(0.10, 0.72, progress));
    float centerReduction = clamp(centerVoid * 0.58 + centerVoidSoft * 0.18, 0.0, 0.70);

    float topBlackShelf =
        (1.0 - smoothstep(0.20, 0.52, uv.y)) *
        (1.0 - smoothstep(0.0, 0.18, progress)) *
        0.38;

    float3 darkBase = float3(0.0, 0.0, 0.0);
    float3 darkNavy = float3(0.004, 0.010, 0.024);
    float3 darkBlueGlow = mix(
        float3(0.045, 0.230, 0.780),
        float3(0.820, 0.405, 0.018),
        isYellowPreset
    );
    float3 darkElectric = mix(
        float3(0.100, 0.430, 1.000),
        float3(1.000, 0.720, 0.030),
        isYellowPreset
    );
    float3 darkCyan = mix(
        float3(0.520, 0.960, 1.000),
        float3(1.000, 0.925, 0.210),
        isYellowPreset
    );
    float3 darkMintCyan = mix(
        float3(0.650, 1.000, 0.900),
        float3(1.000, 0.970, 0.560),
        isYellowPreset
    );

    float lowerIntensity = smootherLiquid(darkLowerField);
    float topIntensity = smootherLiquid(darkTopField);
    float edgeIntensity = clamp(sideGlowDark * (darkLowerField * 0.30 + darkTopField * 0.34), 0.0, 1.0);

    float3 darkResult = darkBase;
    darkResult = mix(darkResult, darkNavy, clamp(darkLowerField * 0.52 + darkTopField * 0.38, 0.0, 1.0));
    darkResult += mix(darkBlueGlow, darkElectric, smoothstep(0.22, 0.92, lowerIntensity)) * lowerIntensity * 0.82;
    darkResult += darkCyan * cyanWashDark * 0.24;
    darkResult += darkMintCyan * keyedWhiteLens * 0.10 * darkColorReveal;
    darkResult += mix(darkBlueGlow, darkElectric, 0.52) * topIntensity * 0.86;
    darkResult += darkCyan * topMistBand * 0.22 * darkColorReveal;
    darkResult += darkElectric * edgeIntensity * 0.42;
    darkResult += mix(darkBlueGlow, darkElectric, 0.72) * finishTopPush * 0.34;

    darkResult = mix(darkResult, darkBase, clamp(centerVoidSoft, 0.0, 0.34));
    darkResult = mix(darkResult, darkBase, clamp(centerVoid, 0.0, 0.86));
    darkResult = mix(darkResult, darkBase, finishLift * smoothstep(0.30, 0.72, uv.y) * 0.64);
    darkResult = mix(darkResult, darkBase, topBlackShelf);
    float blueIdleAccent = isBluePreset * idleWaveEnergy * (1.0 - motionColorRestore * 0.85);
    darkResult += float3(0.000, 0.423529, 1.000) * blueIdleAccent * 0.74;
    darkResult += float3(0.540, 0.900, 1.000) * blueIdleAccent * 0.24;
    float yellowIdleAccent = isYellowPreset * idleWaveEnergy * (1.0 - motionColorRestore * 0.85);
    darkResult += float3(1.000, 0.780, 0.075) * yellowIdleAccent * 0.62;
    darkResult += float3(1.000, 0.956, 0.365) * yellowIdleAccent * 0.24;

    // Dark mode uses the same travelling band as the light reference. Only the
    // canvas changes to black; no accumulated color remains below the band.
    float3 darkBandOuterColor = mix(targetBlue, cyan, 0.30);
    float3 darkBandBodyColor = mix(targetBlue, electric, 0.34);
    float3 darkBandCoreColor = mix(targetBlue, electric, 0.72);
    if (isYellowPreset > 0.5) {
        // Carry Blue Dark's dominant-channel light field through the shared
        // masks first. Apply Yellow's palette after them, not before dimming.
        darkBandOuterColor = darkBandBodyColor = darkBandCoreColor = float3(1.0);
    }
    float darkBandEntry = smoothstep(0.002, 0.020, progress);
    float darkBandOuter = referenceOuter * darkBandEntry;
    float darkBandBody = referenceBody * darkBandEntry;
    float darkBandCore = referenceCore * darkBandEntry;
    float3 travellingDarkResult = darkBase;
    travellingDarkResult += darkBandOuterColor * darkBandOuter * 0.20;
    travellingDarkResult += darkBandBodyColor * darkBandBody * 0.58;
    travellingDarkResult += darkBandCoreColor * darkBandCore * 0.54;
    travellingDarkResult = mix(
        travellingDarkResult,
        darkBase,
        centerReduction
    );
    darkResult = travellingDarkResult;
    // Clear behind the moving mass, not through its bright core at 70–85%.
    // Rejoin the original completion fade before the explicit endpoint gate.
    float completionBlackout =
        segmentEase(progress, 0.58, 0.98) *
        smoothstep(0.06, 0.38, uv.y) *
        mix(smoothstep(0.04, 0.32, referenceDistance),
            1.0, segmentEase(progress, 0.85, 0.98));
    darkResult = mix(darkResult, darkBase, completionBlackout);
    // Hard safety gate: no color is allowed to leak into a dark-theme canvas at 0%.
    // This is intentionally applied after every dark effect contribution.
    float darkCanvasReveal = smoothstep(0.0, 0.10, progress);
    darkResult = mix(darkBase, darkResult, darkCanvasReveal);

    float finishSync = segmentEase(progress, 0.94, 1.0);
    float endpointCoverage = referenceOuter * (0.82 + 0.16 * blueLightDensity) *
        (1.0 - counterProtection * 0.32);
    float3 endpointColor = isYellowPreset > 0.5 ? float3(1.0) : darkBandCoreColor;
    darkResult = mix(darkResult, endpointColor * endpointCoverage, finishSync);
    // Blue Dark's unbounded density is the only spatial input to palette
    // mapping. A second, narrower body mask made the other palettes read as
    // stripes even though their outer coverage matched Blue.
    float sharedLightField = max(darkResult.r, max(darkResult.g, darkResult.b));
    // REGRESSION LOCK: geometry is resolved ONCE before any of the four palettes.
    // Main/front/free-wave fields contain no theme or color coefficients.
    float idleDensity = idleActivity > 0.0
        ? idleWaveDensity(position, size, idleActivity, idleTime, waveStrength) : 0.0;
    IdleContact contact = sharedIdleContact(sharedLightField, float(half(idleDensity)));
    float3 blueDarkReference = darkResult;
    if (isYellowPreset > 0.5) {
        blueDarkReference = float3(0.10, 0.55, 1.0) * sharedLightField;
        // No endpoint hue/exposure switch, threshold or highlight layer.
        darkResult = yellowDarkDensityPalette(sharedLightField);
    }
    darkResult += grain * mix(0.0010, 0.0035, grainMask) *
        (1.0 - completionBlackout) * darkCanvasReveal;
    blueDarkReference = clamp(blueDarkReference + grain * mix(0.0010, 0.0035, grainMask) *
        (1.0 - completionBlackout) * darkCanvasReveal, 0.0, 1.0);
    float3 finishedDark = clamp(darkResult, 0.0, 1.0);
    // White transmits the same density field. Channel-wise absorption gives
    // blue -> cyan -> white / orange -> yellow -> white continuously, rather
    // than painting a saturated band with separate hue and opacity masks.
    float3 blueTransmission = mix(referenceBlue, referenceBlueAccent, 0.65);
    float3 yellowTransmission = float3(yellowLightOrange.r,
        mix(yellowMidColor.g, yellowHotColor.g, 0.75),
        pow(yellowLightAccent.b, 2.5));
    float3 transmission = mix(blueTransmission, yellowTransmission, isYellowPreset);
    float3 matchingLight = pow(max(transmission, float3(0.0001)), float3(sharedLightField));
    lightResult = mix(lightResult, matchingLight, clamp(isBluePreset + isYellowPreset, 0.0, 1.0));
    result = mix(lightResult, finishedDark, themeStrength);

    // Explicit boundary states for the dark theme. These sit after all palette
    // effects, so a selected color can never replace the black canvas at rest.
    float darkTheme = step(0.5, themeStrength);
    float darkAtRest = 1.0 - smoothstep(0.001, 0.035, progress);
    result = mix(result, darkBase, darkTheme * darkAtRest);
    blueDarkReference = mix(blueDarkReference, darkBase, darkTheme * darkAtRest);

    // Purely visual history; no clock or field value feeds the progress mechanic.
    if (interactionFloatCount > 0) {
        float trail = interactionLightField(uv, safeSize.x / safeSize.y, interactionSegments, interactionFloatCount);
        float readability = 1.0 - 0.88 * counterProtection;
        // Exposure depends on local interaction accumulation, so a first pass
        // cannot start white merely because it crosses a bright progress band.
        float heat = trail;
        float brighter = 1.0 - exp(-max(heat - 0.35, 0.0) * 0.95);
        float excessHeat = max(heat - 1.45, 0.0);
        float exposure = 1.0 - exp(-excessHeat * excessHeat / 3.0);
        float3 trailColor;
        if (isYellowPreset > 0.5) {
            // Channel-wise exponential exposure used to push R and G towards
            // equality, leaving olive on black. Keep warm hue while light grows.
            float3 warm = darkTheme > 0.5
                ? mix(yellowDeepColor.rgb, min(yellowHotColor.rgb * 1.18, 1.0), brighter)
                : mix(yellowHotColor.rgb, yellowLightAccent, 0.48 + brighter * 0.52);
            float cream = smoothstep(0.70, 3.0, heat) * 0.75;
            if (darkTheme < 0.5) {
                // A broad orange interval separates yellow pigment from light,
                // making the trail readable even over a saturated yellow base.
                float orange = exp(-pow((heat - 0.85) / 0.90, 2.0)) *
                    (1.0 - exp(-heat * 2.0)) * 0.75;
                warm = mix(yellowLightAccent, yellowLightOrange, orange);
                cream = smoothstep(1.55, 3.50, heat) * 0.75;
                float accumulatedHeat = max(heat - 2.0, 0.0);
                exposure = 1.0 - exp(-accumulatedHeat * accumulatedHeat / 2.8);
            }
            warm = mix(warm, mix(yellowHotColor.rgb, white, 0.82), cream);
            trailColor = mix(warm, mix(yellowHotColor.rgb, white, 0.94), exposure);
        } else {
            // Reuse the cyan produced by the existing additive idle overlap.
            float3 overlapCyan = clamp(targetBlue + float3(0.14, 0.48, 1.0), 0.0, 1.0);
            float3 lightBlue = mix(targetBlue, mix(referenceCyan, overlapCyan, darkTheme), brighter);
            trailColor = mix(lightBlue, float3(0.91, 0.98, 1.0), exposure);
        }
        // Protect text through coverage, not heat: the mask must not turn a
        // hot white/cyan/cream trail into a different, muddy color at its edge.
        float opacity = (0.78 + 0.22 * exposure) * (1.0 - exp(-trail * 0.95)) * readability;
        if (darkTheme > 0.5) {
            float3 backdrop = result;
            result = 1.0 - (1.0 - result) * (1.0 - trailColor * opacity);
            if (isYellowPreset > 0.5) {
                // Same trail field, alpha and screen blending as Blue Dark;
                // only reduce color energy if the warm overlap is brighter.
                float3 blueTrail = mix(mix(float3(0.10, 0.55, 1.0),
                    float3(0.24, 1.0, 1.0), brighter), float3(0.91, 0.98, 1.0), exposure);
                float3 blueOverlap = 1.0 - (1.0 - blueDarkReference) * (1.0 - blueTrail * opacity);
                // Balance only added trail light: a history buffer must never
                // darken the untouched backdrop, even when its samples faded.
                result = backdrop + balanceYellowDarkLight(max(result - backdrop, 0.0),
                    max(blueOverlap - blueDarkReference, 0.0));
            }
        } else {
            // Keep the old Blue Light screen-pass character, driven by local
            // overlap rather than separate offset strokes. First passes stay colored.
            float pigmentOpacity = opacity * (0.76 + 0.24 * exposure);
            result = mix(result, trailColor, pigmentOpacity);
            float3 screenLight = isYellowPreset > 0.5
                ? mix(yellowLightAccent, white, 0.80)
                : float3(0.80, 0.9059, 1.0); // Original Blue Light screen color.
            result = 1.0 - (1.0 - result) * (1.0 - screenLight * exposure * opacity * 0.42);
        }
    }

    half4 output = half4(half3(clamp(result, 0.0, 1.0)), 1.0);
    if (themeStrength < 0.5 && idleActivity > 0.0) {
        output = blendLightIdle(output, idleWaveColor(idleDensity, 0.0, gradientColorIndex),
            contact, gradientColorIndex, transmission);
    }
    if (themeStrength > 0.5 && (isBluePreset + isYellowPreset) > 0.5 && idleActivity > 0.0) {
        output = blendDarkIdle(output, idleWaveColor(idleDensity, 1.0, gradientColorIndex),
            contact, gradientColorIndex);
    }
    // QA DISPLAY MAIN: contact continues to use original sharedLightField.
    QaCommonMainShape qaCommon = qaCommonMainShape(uv, progress, time,
        referenceBandCenter, referenceWarp, centerVoidD, counterProtection, counterDrift);
    float qaCommonOuter = qaDisplayMainGaussian(qaCommon.distance,referenceBandWidth,1.0) * referenceEntry;
    float qaCommonBody = qaDisplayMainGaussian(qaCommon.distance,referenceBandWidth,0.70) * referenceEntry;
    float qaCommonCore = qaDisplayMainGaussian(qaCommon.distance,referenceBandWidth,0.34) * referenceEntry;
    float qaCommonVoid = qaDisplayCentreProfile(qaCommon.voidD,progress) *
        mix(0.56,0.82,smoothstep(0.02,0.58,progress));
    float qaCommonVoidSoft = (1.0-smoothstep(0.58,2.55,qaCompactMainCentre(qaCommon.voidD,progress))) *
        mix(0.18,0.32,smoothstep(0.10,0.72,progress));
    float qaCommonReduction = clamp(qaCommonVoid*0.58+qaCommonVoidSoft*0.18,0.0,0.70);
    float3 qaCommonRawRGB = (darkBandOuterColor*qaCommonOuter*0.20 +
        darkBandBodyColor*qaCommonBody*0.58 + darkBandCoreColor*qaCommonCore*0.54) * darkBandEntry;
    // Same Light fade equation, evaluated in the unified display coordinates.
    float qaCommonCompletion = segmentEase(progress,0.58,0.98) *
        smoothstep(0.06,0.38,uv.y) * mix(smoothstep(0.04,0.32,qaCommon.distance),
            1.0,segmentEase(progress,0.85,0.98));
    float3 qaCommonMainRGB = qaCommonRawRGB * (1.0-qaCommonReduction);
    qaCommonMainRGB = mix(qaCommonMainRGB,darkBase,qaCommonCompletion);
    qaCommonMainRGB = mix(darkBase,qaCommonMainRGB,darkCanvasReveal);
    float qaCommonBlueDensity = exp(-pow(qaCommon.distance / (referenceBandWidth*0.82),2.0))*referenceEntry;
    float qaCommonEndpoint = qaCommonOuter*(0.82+0.16*qaCommonBlueDensity)*(1.0-qaCommon.counter*0.32);
    qaCommonMainRGB = mix(qaCommonMainRGB,endpointColor*qaCommonEndpoint,finishSync);
    float qaCommonLightField = max(qaCommonMainRGB.r,max(qaCommonMainRGB.g,qaCommonMainRGB.b));
    qaCommonLightField*=qaCentreMainRetention(qaCommonOuter,qaCommonBody,qaCommonCore,
        qaCommon.voidD,progress,qaCommon.distance/referenceBandWidth,progress);
    qaCommonLightField+=qaRestoreMainOuter(qaCommonOuter,darkBandEntry,darkCanvasReveal,
        (1.0-qaCommonReduction)*(1.0-qaCommonCompletion),qaCommon.distance,
        referenceBandWidth,qaCommon.voidD,progress)*(1.0-qaCommonCompletion);
    // QA ONLY: Light readout from the original, pre-saturation fields.
    // W is opacity directly, rather than a difference of clipped Dark blue.
    // All three weights are nonnegative and sum to one: no RGB clipping knee.
    // The original I, both wave ridges, MAIN and accepted cyan response stay intact.
    float3 currentLightBase = correctedLightPigment(sharedLightField, 0.0, transmission);
    float3 qaWaveSource = float3(idleWaveColor(1.0, 1.0, gradientColorIndex).rgb);
    float3 qaContactSource = float3(0.24, 1.0, 1.0);
    float3 appearance = currentLightBase * (1.0 - contact.idle)
        + qaWaveSource * (contact.idle - contact.intersection)
        + qaContactSource * contact.intersection;
    // Colour-only readout of the SAME accepted Dark contact intersection.
    // A bounded continuous cyan response lifts the blue contrast dip and peak
    // together, then fades with the existing contact field; no new support/mask.
    float qaContactChroma = 1.0 - exp(-4.0 * contact.intersection);
    appearance = mix(clamp(appearance, 0.0, 1.0), float3(0.24, 1.0, 1.0), qaContactChroma);
    // QA contact-only: the existing I response localizes the EXACT Dark
    // additive contact composite. No new wave, halo, geometry or support mask.
    // Keep CURRENT Light/free-wave RGB when I=0 and its trail readout below.
    if (contact.intersection > 0.0) {
        float3 darkContactComposite = float3(qaContactDarkReference(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,1.0,0.0,idleActivity,idleTime,interactionSegments,0).rgb);
        // QA substrate-only adaptation. K and D retain the original Dark
        // clipping, so E = a*(K-D) is unchanged. Only negative T=a*(D-L)
        // is adapted towards the existing unit-density Light blue pigment.
        float3 qaLightBeforeDark = appearance;
        float3 qaDarkBase = float3(qaContactDarkReference(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,1.0,0.0,0.0,idleTime,interactionSegments,0).rgb);
        float3 qaLightPigment = correctedLightPigment(1.0, 0.0, transmission);
        float qaPeripheral = (1.0-contact.coverage)*(1.0-contact.coverage);
        float3 qaSubstrateDelta = qaContactChroma * qaPeripheral
            * max(min(qaLightBeforeDark, qaLightPigment)-qaDarkBase, 0.0);
        appearance = mix(appearance, darkContactComposite, qaContactChroma);
        appearance += qaSubstrateDelta;
    }
    // Only the MAIN summand changes. Original E=a*(K-D), substrate correction,
    // cyan/halo coefficients and their clamping above remain byte-identical.
    // Use the MAIN coefficient already present in the accepted composition.
    float qaMainField=qaCommonLightField;
    if(progress>0.85) qaMainField=qaMainAtPose(uv,progress,time,false);
    float3 qaUnifiedMainPigment = correctedLightPigment(qaMainField, 0.0, transmission);
    appearance += (qaUnifiedMainPigment-currentLightBase) *
        (1.0-contact.idle) * (1.0-qaContactChroma);
    // Preserve the accepted Light finger-history readout over the new idle RGB.
    // The history field, exposure, text protection and release clock are unchanged.
    if (interactionFloatCount > 0) {
        float trail = interactionLightField(uv, safeSize.x / safeSize.y, interactionSegments, interactionFloatCount);
        float readability = 1.0 - 0.88 * counterProtection;
        float heat = trail;
        float brighter = 1.0 - exp(-max(heat - 0.35, 0.0) * 0.95);
        float excessHeat = max(heat - 1.45, 0.0);
        float exposure = 1.0 - exp(-excessHeat * excessHeat / 3.0);
        // This function is selected only for Blue Light. Use its original
        // Light trail colour, rather than the Dark branch evaluated above.
        float3 lightBlue = mix(targetBlue, referenceCyan, brighter);
        float3 trailColor = mix(lightBlue, float3(0.91, 0.98, 1.0), exposure);
        float opacity = (0.78 + 0.22 * exposure) * (1.0 - exp(-trail * 0.95)) * readability;
        float pigmentOpacity = opacity * (0.76 + 0.24 * exposure);
        appearance = mix(appearance, trailColor, pigmentOpacity);
        float3 screenLight = float3(0.80, 0.9059, 1.0);
        appearance = 1.0 - (1.0 - appearance) * (1.0 - screenLight * exposure * opacity * 0.42);
    }
    return half4(half3(clamp(appearance, 0.0, 1.0)), output.a);

}


// QA B: smooth only Blue Dark MAIN's blue saturation readout.
// Join the existing linear and saturated branches across the available
// density headroom, (.20+.58+.54)-1. No geometry/contact field changes.
float qaNativeBlueCap(float x) {
    const float radius = 0.20 + 0.58 + 0.54 - 1.0;
    if (x <= 1.0-radius) return max(x, 0.0);
    if (x >= 1.0+radius) return 1.0;
    float t = (x-(1.0-radius))/(2.0*radius);
    return 1.0-radius+2.0*radius*(t-t*t*t+0.5*t*t*t*t);
}

// QA: query the exact ACCEPTED Light MAIN density AFTER its visual masks.
// This is a colour-free shape query: no wave/contact/trail or palette changes.
float qaAcceptedLightShapeDensityImpl(float2 uv, float progress, float time,
    float bandCenter, float bandWidth,bool correctInterior,bool cleanOuter=false,float displayProgress=-1.0) {
    float originalWarp=sin(uv.x*5.7+time*0.11)*0.018 +
        sin(uv.x*10.4-time*0.08+1.2)*0.008;
    float originalVoidD=pow((uv.x-0.5+sin(uv.y*11.0+time*0.12)*0.018)/0.354,2.0) +
        pow((uv.y-0.475+sin(uv.x*8.0+0.8)*0.014)/0.150,2.0);
    float counterDrift=sin(time*0.16)*0.006;
    float2 counterDelta=float2((uv.x-0.5+sin(uv.y*11.0+time*0.12)*0.018)/0.29,
        (uv.y-0.475+sin(uv.x*8.0+0.8)*0.016+counterDrift)/0.090);
    float2 counterLobe=float2((uv.x-0.57)/0.23,(uv.y-0.45+counterDrift)/0.105);
    float originalCounter=0.76*exp(-dot(counterDelta,counterDelta)) +
        0.24*exp(-dot(counterLobe,counterLobe));
    QaCommonMainShape shape=qaCommonMainShape(uv,progress,time,bandCenter,
        originalWarp,originalVoidD,originalCounter,counterDrift);
    float entry=smoothstep(0.002,0.020,progress);
    float outer=qaDisplayMainGaussian(shape.distance,bandWidth,1.0)*entry;
    float body=qaDisplayMainGaussian(shape.distance,bandWidth,0.70)*entry;
    float core=qaDisplayMainGaussian(shape.distance,bandWidth,0.34)*entry;
    float voidMain=(correctInterior ? qaDisplayCentreProfile(shape.voidD,progress) : 1.0-smoothstep(0.36,1.68,shape.voidD))*
        mix(0.56,0.82,smoothstep(0.02,0.58,progress));
    float voidSoft=(1.0-smoothstep(0.58,2.55,correctInterior ? qaCompactMainCentre(shape.voidD,progress) : shape.voidD))*
        mix(0.18,0.32,smoothstep(0.10,0.72,progress));
    float reduction=clamp(voidMain*0.58+voidSoft*0.18,0.0,0.70);
    float completion=segmentEase(progress,0.58,0.98)*smoothstep(0.06,0.38,uv.y)*
        mix(smoothstep(0.04,0.32,shape.distance),1.0,segmentEase(progress,0.85,0.98));
    float density=(outer*0.20+body*0.58+core*0.54)*entry*(1.0-reduction);
    if(correctInterior) density*=qaCentreMainRetention(outer,body,core,shape.voidD,
        progress,shape.distance/bandWidth,displayProgress);
    density=mix(density,0.0,completion);
    density=mix(0.0,density,smoothstep(0.0,0.10,progress));
    if(correctInterior) {
        float restoredOuter=qaRestoreMainOuter(outer,entry,smoothstep(0.0,0.10,progress),
            (1.0-reduction)*(1.0-completion),shape.distance,bandWidth,shape.voidD,progress);
        // Light readout only: do not revive an isolated pigment pocket after
        // the existing completion field has extinguished MAIN there.
        density+=restoredOuter*(cleanOuter ? (1.0-completion) : 1.0);
    }
    float blueDensity=exp(-pow(shape.distance/(bandWidth*0.82),2.0))*entry;
    float endpoint=outer*(0.82+0.16*blueDensity)*(1.0-shape.counter*0.32);
    return mix(density,endpoint,segmentEase(progress,0.94,1.0));
}
float qaAcceptedLightShapeDensity(float2 uv,float progress,float time,float bandCenter,float bandWidth) {
 return qaAcceptedLightShapeDensityImpl(uv,progress,time,bandCenter,bandWidth,true);
}

float qaAcceptedDarkShapeDensityImpl(float2 uv,float progress,float time,
    float bandCenter,float bandWidth,bool correctInterior) {
    float warp=sin(uv.x*5.7+time*.11)*.018+sin(uv.x*10.4-time*.08+1.2)*.008;
    float vd=pow((uv.x-.5+sin(uv.y*11.0+time*.12)*.018)/.354,2.0)+
        pow((uv.y-.475+sin(uv.x*8.0+.8)*.014)/.150,2.0);
    float drift=sin(time*.16)*.006;
    float2 dc=float2((uv.x-.5+sin(uv.y*11.0+time*.12)*.018)/.29,
        (uv.y-.475+sin(uv.x*8.0+.8)*.016+drift)/.090);
    float2 dl=float2((uv.x-.57)/.23,(uv.y-.45+drift)/.105);
    float cp=.76*exp(-dot(dc,dc))+.24*exp(-dot(dl,dl));
    QaCommonMainShape sh=qaCommonMainShape(uv,progress,time,bandCenter,warp,vd,cp,drift);
    float entry=smoothstep(.002,.020,progress);
    float outer=qaDisplayMainGaussian(sh.distance,bandWidth,1.0)*entry;
    float body=qaDisplayMainGaussian(sh.distance,bandWidth,0.70)*entry;
    float core=qaDisplayMainGaussian(sh.distance,bandWidth,0.34)*entry;
    float v=(correctInterior ? qaDisplayCentreProfile(sh.voidD,progress) : 1.0-smoothstep(.36,1.68,sh.voidD))*mix(.56,.82,smoothstep(.02,.58,progress));
    float vs=(1.0-smoothstep(.58,2.55,correctInterior ? qaCompactMainCentre(sh.voidD,progress) : sh.voidD))*mix(.18,.32,smoothstep(.10,.72,progress));
    float red=clamp(v*.58+vs*.18,0.0,.70)*(1.0-segmentEase((.475-bandCenter)/bandWidth,0.0,.70));
    float completion=segmentEase(progress,.58,.98)*smoothstep(.06,.38,uv.y)*
        mix(smoothstep(.04,.32,sh.distance),1.0,segmentEase(progress,.85,.98));
    const float refP=.33;
    float refC=bandMotion(1.105,.855,0.0,-.838028,refP/.50,.50);
    refC-=.065*smoothstep(0.0,.05,refP)*(1.0-segmentEase(refP,.26,.45));
    float refW=mix(.205,.315,smootherLiquid(refP/.50));
    float refY=refC-sh.warp-sh.distance/bandWidth*refW;
    float mx=1.0-uv.x;
    float rv=pow((uv.x-.5+sin(refY*11.0+time*.12)*.018)/.354,2.0)+
        pow((refY-.475+sin(uv.x*8.0+.8)*.014)/.150,2.0);
    float rmv=pow((mx-.5+sin(refY*11.0+time*.12)*.018)/.354,2.0)+
        pow((refY-.475+sin(mx*8.0+.8)*.014)/.150,2.0);
    float brv=(rv+rmv)*.5;
    float rr=clamp((1.0-smoothstep(.36,1.68,brv))*mix(.56,.82,smoothstep(.02,.58,refP))*.58+
        (1.0-smoothstep(.58,2.55,brv))*mix(.18,.32,smoothstep(.10,.72,refP))*.18,0.0,.70);
    float finish=segmentEase(progress,.94,1.0);
    float ext=segmentEase(sh.distance/bandWidth,0.0,.34)*segmentEase(progress,.70,.90);
    float trans=mix((1.0-red)*(1.0-completion),1.0-rr*(1.0-finish),ext);
    float M=(outer*.20+body*.58+core*.54)*entry*trans*smoothstep(0.0,.10,progress);
    if(correctInterior) M*=qaCentreMainRetention(outer,body,core,sh.voidD,progress);
    if(correctInterior) M+=qaRestoreMainOuter(outer,entry,smoothstep(0.0,0.10,progress),
        trans,sh.distance,bandWidth,sh.voidD,progress);
    if(finish>0.0) {
        float py=clamp(bandCenter-sh.warp,0.0,1.0),pu=(py+sh.warp-bandCenter)/bandWidth;
        float po=qaDisplayMainGaussian(pu,1.0,1.0),pb=qaDisplayMainGaussian(pu,1.0,0.70),pc=qaDisplayMainGaussian(pu,1.0,0.34);
        float2 dc1=float2((uv.x-.5+sin(py*11.0+time*.12)*.018)/.29,
            (py-.475+sin(uv.x*8.0+.8)*.016+drift)/.090);
        float2 dl1=float2((uv.x-.57)/.23,(py-.45+drift)/.105);
        float2 dc2=float2((mx-.5+sin(py*11.0+time*.12)*.018)/.29,
            (py-.475+sin(mx*8.0+.8)*.016+drift)/.090);
        float2 dl2=float2((mx-.57)/.23,(py-.45+drift)/.105);
        float protect=(.76*exp(-dot(dc1,dc1))+.24*exp(-dot(dl1,dl1))+
            .76*exp(-dot(dc2,dc2))+.24*exp(-dot(dl2,dl2)))*.5;
        float ep=po*(.82+.16*exp(-pow(pu/.82,2.0)))*(1.0-protect*.32);
        M*=mix(1.0,ep/max(po*.20+pb*.58+pc*.54,.000001),finish);
    }
    return M;
}
float qaAcceptedDarkShapeDensity(float2 uv,float progress,float time,float bandCenter,float bandWidth) {
 return qaAcceptedDarkShapeDensityImpl(uv,progress,time,bandCenter,bandWidth,true);
}

float qaAcceptedShapeSample(float2 uv,float progress,float time,float bandCenter,float bandWidth,bool dark) {
    return dark ? qaAcceptedDarkShapeDensityImpl(uv,progress,time,bandCenter,bandWidth,false)
        : qaAcceptedLightShapeDensityImpl(uv,progress,time,bandCenter,bandWidth,false);
}

float qaAcceptedMainShapeColumnPeak(float x,float progress,float time,
    float bandCenter,float bandWidth,float commonWarp,bool dark) {
    // A masked profile is not unimodal. Its maximum must cover the complete
    // visible column; adaptive Golden-section branches selected wrong lobes.
    // A maximum of fixed continuous samples is continuous in x/time/progress.
    float peak=0.0;
    for(int i=0;i<=128;i++) {
        float y=float(i)/128.0;
        peak=max(peak,qaAcceptedShapeSample(float2(x,y),progress,time,bandCenter,bandWidth,dark));
    }
    return max(peak,0.000001);
}

float qaMainPoseProgress(float p) {
    if(p<=0.85) return p;
    if(p>=0.95) return 0.90;
    float q=(p-0.85)/0.10;
    return 0.85+0.10*(q-q*q*q+0.5*q*q*q*q);
}
float qaMainPoseTime(float p,float time) {
    // MAIN's shape clock only. Free wave, contact, history/release time unchanged.
    return time+10.0*(qaMainPoseProgress(p)-p);
}
void qaMainPoseBand(float p,thread float &center,thread float &width) {
    if(p<=0.50) {
        center=bandMotion(1.105,0.855,0.0,-0.838028,p/0.50,0.50);
        width=mix(0.205,0.315,smootherLiquid(p/0.50));
    } else if(p<=0.70) {
        center=bandMotion(0.855,0.515,-0.838028,-1.676693,(p-0.50)/0.20,0.20);
        width=mix(0.315,0.285,smootherLiquid((p-0.50)/0.20));
    } else {
        center=bandMotion(0.515,0.020,-1.676693,0.0,(p-0.70)/0.30,0.30);
        width=mix(0.285,0.235,smootherLiquid((p-0.70)/0.30));
    }
    center-=0.065*smoothstep(0.0,0.05,p)*(1.0-segmentEase(p,0.26,0.45));
    center-=0.075*segmentEase(p,0.90,1.0);
}
float qaMainAtPose(float2 uv,float progress,float time,bool dark) {
    // Final DISPLAY translation only, identical for both Blue palettes.
    // Measured from the protected final GPU frame: its furthest existing peak
    // must reach the top edge to reveal only the descending colour sequence.
    // Zero through85%; continuous deceleration to rest at100%.
    // Physical/contact/gesture coordinates and their clocks remain untouched.
    uv.y+=(102.0/844.0)*segmentEase(progress,0.85,1.0);
    float p=qaMainPoseProgress(progress),t=qaMainPoseTime(progress,time);
    float center,width;qaMainPoseBand(p,center,width);
    float L=qaAcceptedLightShapeDensityImpl(uv,p,t,center,width,true,!dark,progress);
    if(!dark) return L;
    float D=qaAcceptedDarkShapeDensity(uv,p,t,center,width);
    float transfer=segmentEase(p,.70,.76)*(1.0-segmentEase(p,.94,1.0));
    if(transfer<=0.0) return D;
    // Keep the inherited shape intact: no x-only gain / vertical slab.
    float x=uv.x,mx=1.0-x;
    float w=sin(x*5.7+t*.11)*.018+sin(x*10.4-t*.08+1.2)*.008;
    float mw=sin(mx*5.7+t*.11)*.018+sin(mx*10.4-t*.08+1.2)*.008;
    w=mix(w,(w+mw)*.5,segmentEase(p,.50,.76));
    return qaDarkLateFade(mix(D,L,transfer),(uv.y+w-center)/width,progress);
}

half4 liquidSpecBackground(
    float2 position,
    half4 color,
    float2 size,
    float progress,
    float tapPulse,
    float2 tapPoint,
    float2 previousTouchPoint,
    float swipePulse,
    float swipeStrength,
    float time,
    float progressSpeed,
    float fillGain,
    float waveStrength,
    float waveSpread,
    float topBloom,
    float whiteCore,
    float blueDepth,
    float dragWave,
    float shockStrength,
    float shockInteraction,
    float shockTrail,
    float waveCount,
    float themeStrength,
    float gradientColorIndex,
    float idleActivity,
    float idleTime,
    device const float *interactionSegments,
    int interactionFloatCount
) {
    // Only temporary Light Blue uses the actual current Dark behaviour.
    if (as_type<uint>(themeStrength)==0u && as_type<uint>(gradientColorIndex)==0u) {
        return qaCurrentAcceptedDarkBlue(position, color, size, progress, tapPulse, tapPoint, previousTouchPoint, swipePulse, swipeStrength, time, progressSpeed, fillGain, waveStrength, waveSpread, topBloom, whiteCore, blueDepth, dragWave, shockStrength, shockInteraction, shockTrail, waveCount, 1.0, 0.0, idleActivity, idleTime, interactionSegments, interactionFloatCount);
    }

    // Keep the accepted Dark Blue body below untouched. Other theme changes
    // compile in a separate function and cannot rewrite its main/idle arithmetic.
    if (as_type<uint>(themeStrength) == 0u || as_type<uint>(gradientColorIndex) == 0x40400000u) {
        return correctedThemesBackground(position, color, size, progress, tapPulse, tapPoint, previousTouchPoint, swipePulse, swipeStrength, time, progressSpeed, fillGain, waveStrength, waveSpread, topBloom, whiteCore, blueDepth, dragWave, shockStrength, shockInteraction, shockTrail, waveCount, themeStrength, gradientColorIndex, idleActivity, idleTime, interactionSegments, interactionFloatCount);
    }

    progress = clamp(progress, 0.0, 1.0);
    progressSpeed = clamp(progressSpeed, 0.0, 10.0);
    fillGain = clamp(fillGain, 0.0, 10.0);
    waveStrength = clamp(waveStrength, 0.0, 10.0);
    waveSpread = clamp(waveSpread, 0.0, 10.0);
    topBloom = clamp(topBloom, 0.0, 10.0);
    whiteCore = clamp(whiteCore, 0.0, 10.0);
    blueDepth = clamp(blueDepth, 0.0, 10.0);
    dragWave = clamp(dragWave, 0.0, 1.0);
    swipePulse = smootherLiquid(clamp(swipePulse, 0.0, 1.0));
    swipeStrength = clamp(swipeStrength, 0.0, 1.0);
    shockStrength = clamp(shockStrength, 0.0, 10.0);
    shockInteraction = clamp(shockInteraction, 0.0, 10.0);
    shockTrail = clamp(shockTrail, 0.0, 10.0);
    waveCount = clamp(round(waveCount), 0.0, 10.0);
    themeStrength = clamp(themeStrength, 0.0, 1.0);
    gradientColorIndex = clamp(round(gradientColorIndex), 0.0, 4.0);
    float isBluePreset = 1.0 - step(0.5, abs(gradientColorIndex));
    float isYellowPreset = 1.0 - step(0.5, abs(gradientColorIndex - 3.0));

    float2 design = float2(375.0, 812.0);
    float2 safeSize = float2(max(size.x, 1.0), max(size.y, 1.0));

    float2 p = float2(
        position.x / safeSize.x * design.x,
        position.y / safeSize.y * design.y
    );

    float2 uv = position / safeSize;

    float3 white = float3(1.0);

    // Blue gradient shares the light idle-wave palette: #1A8CFF.
    float3 cyan = float3(0.10, 0.55, 1.0);
    float3 aqua = float3(0.10, 0.55, 1.0);
    float3 blue = float3(0.10, 0.55, 1.0);
    float3 deepBlue = float3(0.10, 0.55, 1.0);
    float3 electric = float3(0.10, 0.55, 1.0);
    float3 targetBlue = float3(0.10, 0.55, 1.0);

    if (gradientColorIndex < 2.5 && gradientColorIndex > 1.5) {
        cyan = float3(0.62, 0.46, 1.0);
        aqua = float3(0.43, 0.28, 0.94);
        blue = float3(0.22, 0.12, 0.72);
        deepBlue = float3(0.09, 0.05, 0.34);
        electric = float3(0.82, 0.58, 1.0);
        targetBlue = float3(0.56, 0.42, 1.0);
    } else if (gradientColorIndex < 3.5 && gradientColorIndex > 2.5) {
        cyan = mix(yellowHotColor.rgb, white, 0.32);
        aqua = yellowHotColor.rgb;
        blue = yellowMidColor.rgb;
        deepBlue = yellowDeepColor.rgb;
        electric = yellowHotColor.rgb;
        targetBlue = yellowMidColor.rgb;
    } else if (gradientColorIndex > 3.5) {
        cyan = float3(1.0, 0.46, 0.68);
        aqua = float3(0.94, 0.26, 0.58);
        blue = float3(0.60, 0.14, 0.52);
        deepBlue = float3(0.26, 0.05, 0.20);
        electric = float3(1.0, 0.68, 0.88);
        targetBlue = float3(1.0, 0.42, 0.66);
    }

    float3 waveMid = mix(targetBlue, aqua, 0.24);
    float3 waveDeep = mix(deepBlue, targetBlue, 0.18);
    float3 waveGlass = mix(cyan, white, 0.68);
    float3 waveEdge = mix(electric, cyan, 0.36);

    // --------------------------------------------------
    // Idle shockwave
    // --------------------------------------------------

    float idleWaveActivity = smootherLiquid(swipeStrength);
    float idleWaveFade = mix(0.92, 0.78, smoothstep(0.92, 1.0, progress)) * idleWaveActivity;

    float idlePeriod = 3.0;
    float idleCycleRaw = fract(time / idlePeriod);
    float idleCycle = smootherLiquid(idleCycleRaw);

    float idleWaveVisibility =
        smoothstep(0.02, 0.11, idleCycleRaw) *
        (1.0 - smoothstep(0.88, 1.0, idleCycleRaw)) *
        idleWaveFade;

    float idleWaveY = mix(-110.0, 925.0, idleCycle);

    float idleWidth = mix(72.0, 420.0, idleCycle);
    float idleThickness = mix(19.0, 42.0, idleCycle);

    float idleDx = p.x - 187.5;

    float idleArcY =
        idleWaveY +
        (idleDx * idleDx) / max(idleWidth * 1.72, 1.0);

    float idleWaveDist = p.y - idleArcY;

    float idleMainWave =
        exp(-pow(idleWaveDist / idleThickness, 2.0)) *
        exp(-pow(idleDx / idleWidth, 2.0));

    float idleSecondWave =
        exp(-pow((idleWaveDist + 72.0) / (idleThickness * 1.35), 2.0)) *
        exp(-pow(idleDx / (idleWidth * 1.18), 2.0)) *
        0.42;

    float idleThirdWave =
        exp(-pow((idleWaveDist + 132.0) / (idleThickness * 1.75), 2.0)) *
        exp(-pow(idleDx / (idleWidth * 1.32), 2.0)) *
        0.20;

    float idleConeGlow =
        exp(-pow((p.y - idleWaveY) / 180.0, 2.0)) *
        exp(-pow(idleDx / max(idleWidth * 1.18, 1.0), 2.0)) *
        0.18;

    float idleWaveEnergy =
        clamp(
            idleMainWave +
            idleSecondWave +
            idleThirdWave +
            idleConeGlow,
            0.0,
            1.0
        ) *
        idleWaveVisibility *
        waveStrength;

    // --------------------------------------------------
    // Continuous upward motion
    // --------------------------------------------------

    // Use the original gradient motion curve for every palette and theme.
    float baseRise = progress * (0.42 + 0.58 * progress);
    float smoothRise = smootherLiquid(progress);
    float rise = mix(baseRise, smoothRise, 0.34);
    float finalLiftBoost = segmentEase(progress, 0.74, 1.00);
    float lateLiftBoost = segmentEase(progress, 0.88, 1.00);

    float circleGrowth = smootherLiquid(progress);

    float2 center = float2(187.5, 406.0);
    float circleAppear = smoothstep(0.025, 0.12, progress * (0.70 + progressSpeed * 3.0));
    float circleRadius = mix(74.0, 178.0, circleGrowth) * mix(0.92, 1.08, waveSpread - 0.5);

    float bottomCleanProgress = segmentEase(progress, 0.42, 1.00);
    float topCapProgress = segmentEase(progress, 0.82, 1.00);
    float topReservoirProgress = segmentEase(progress, 0.58, 1.00);

    float completionBloom = segmentEase(progress, 0.96, 1.00);
    float completed = smoothstep(0.995, 1.0, progress);

    float globalLift =
        mix(0.0, 1380.0, rise) +
        260.0 * finalLiftBoost +
        540.0 * lateLiftBoost;

    float initialDrop = 350.0 * (1.0 - rise);

    float finalBlur = segmentEase(progress, 0.70, 1.00);
    float completionMistProgress = segmentEase(progress, 0.84, 1.00);

    float completionFlash = 0.0;

    // Позже начинаем растворять градиент.
    float lateTransparency = segmentEase(progress, 0.90, 1.00);

    float mainFinalFade = mix(1.0, 0.62, lateTransparency);
    float rimFinalFade = mix(1.0, 0.44, lateTransparency);
    float finalFade = mainFinalFade;

    // Делаем градиент более вытянутым в первой половине
    // и чуть компактнее к финалу, но мягче, чем раньше.
    float shrinkAfterHalf = segmentEase(progress, 0.64, 1.00);

    float stretchFactor = mix(
        0.30,
        0.64,
        shrinkAfterHalf
    );

    float2 pStretched = float2(
        p.x,
        406.0 + (p.y - 406.0) * stretchFactor
    );

    // --------------------------------------------------
    // Bottom clearing mask
    // --------------------------------------------------

    float clearEdgeY = mix(1060.0, 225.0, bottomCleanProgress);
    float clearFeather = mix(205.0, 360.0, bottomCleanProgress);

    float clearWave =
        24.0 * sin(p.x * 0.018 + time * 0.50 + rise * 2.0) +
        15.0 * sin(p.x * 0.041 - time * 0.36 + rise * 4.0) +
        8.0  * sin((p.x + p.y) * 0.020 + time * 0.22);

    float bottomClear = smoothstep(
        clearEdgeY - clearFeather,
        clearEdgeY + clearFeather,
        p.y + clearWave
    );

    float bottomOnly = smoothstep(0.38, 1.0, uv.y);
    bottomClear *= bottomOnly;

    // --------------------------------------------------
    // Organic liquid reveal edge
    // --------------------------------------------------

    float revealEdgeY = mix(910.0, -1450.0, rise);

    // Граница сверху и снизу мягче.
    float revealFeather = mix(
        140.0,
        360.0 + 340.0 * finalBlur,
        rise
    );

    float revealWaveA =
        34.0 * sin(p.x * 0.013 + time * 0.42 + rise * 2.1);

    float revealWaveB =
        18.0 * sin(p.x * 0.031 - time * 0.56 + rise * 3.4);

    float revealWaveC =
        9.0 * sin(p.x * 0.071 + time * 0.33 - rise * 1.6);

    float domainWarp =
        13.0 * sin((p.x + p.y) * 0.018 + time * 0.28) +
        7.0  * sin((p.x - p.y) * 0.026 - time * 0.31);

    float blob1 =
        42.0 *
        exp(-pow((p.x - 86.0) / 72.0, 2.0)) *
        sin(time * 0.37 + rise * 2.4);

    float blob2 =
        36.0 *
        exp(-pow((p.x - 206.0) / 88.0, 2.0)) *
        sin(time * 0.29 + 1.7 + rise * 2.9);

    float blob3 =
        30.0 *
        exp(-pow((p.x - 318.0) / 76.0, 2.0)) *
        sin(time * 0.34 + 3.1 + rise * 2.2);

    float revealWave =
        revealWaveA +
        revealWaveB +
        revealWaveC +
        domainWarp +
        blob1 +
        blob2 +
        blob3;

    float edgeChaos = mix(
        0.72,
        1.0,
        smoothstep(0.12, 0.65, progress)
    );

    float liquidEdgeY = revealEdgeY - revealWave * edgeChaos;

    float bottomReveal = smoothstep(
        liquidEdgeY - revealFeather,
        liquidEdgeY + revealFeather,
        p.y
    );

    float revealEdgeDist = abs(p.y - liquidEdgeY);

    float revealEdgeGlow =
        exp(-revealEdgeDist / 38.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.22 *
        finalFade;

    float tensionCore =
        exp(-revealEdgeDist / 15.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.18 *
        finalFade;

    float tensionShadow =
        exp(-abs((p.y - liquidEdgeY) - 26.0) / 28.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.10 *
        finalFade;

    float liquidRimLine =
        exp(-revealEdgeDist / 8.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        finalFade;

    // --------------------------------------------------
    // Idle / completion breathing
    // --------------------------------------------------

    float idleEnergy = 1.0 - smoothstep(0.02, 0.22, progress);

    float idleVertical =
        idleEnergy *
        (
            18.0 * sin(time * 0.46) +
            9.0  * sin(time * 0.83)
        );

    float horizontalDrift = 0.0;

    float baseShiftY = globalLift - initialDrop + idleVertical;

    float2 pGlobal = pStretched + float2(horizontalDrift, baseShiftY);

    // --------------------------------------------------
    // Refraction + tap push + flow pull
    // --------------------------------------------------

    float lensDist = distance(p, center);

    float refractionZone =
        exp(-pow((lensDist - circleRadius) / 42.0, 2.0)) *
        circleAppear;

    float2 refractDir = normalize(p - center + float2(0.001, 0.001));
    float2 refractionWarp = refractDir * refractionZone * 10.0;

    float2 tapPxDesign = float2(
        tapPoint.x * design.x,
        tapPoint.y * design.y
    );

    float2 touchDeltaDesign = p - tapPxDesign;
    float tapDistDesign = length(touchDeltaDesign);
    float shockActive = smoothstep(0.04, 1.0, dragWave) * waveStrength * shockStrength;
    float shockAge = clamp((1.0 - tapPulse) / max(shockTrail, 0.30), 0.0, 1.0);
    float shockSide = touchDeltaDesign.x >= 0.0 ? 1.0 : -1.0;
    float travelingPhase = time * (3.8 + 1.4 * shockInteraction);

    float rippleAmplitude = 38.0 * shockStrength;
    float rippleEnvelope = smoothstep(0.01, 0.46, dragWave);
    float waveProgress = clamp(1.0 - tapPulse, 0.0, 1.0);
    float safeWaveSpread = max(waveSpread, 0.001);
    float safeShockTrail = max(shockTrail, 0.001);
    float waveFrontRadius = 24.0 + waveProgress * 250.0 * shockTrail;
    float ringSpacing = 46.0 * waveSpread;
    float ringWidth = max(25.0 * waveSpread, 1.0);
    float finiteRipple = 0.0;

    // Fixed upper bound keeps this predictable on the GPU while allowing 0...10 waves.
    for (int waveIndex = 0; waveIndex < 10; waveIndex++) {
        float index = float(waveIndex);
        float ringRadius = waveFrontRadius - ringSpacing * index;
        float ringEnabled = step(index + 0.5, waveCount) * smoothstep(2.0, 16.0, ringRadius);
        float ring =
            exp(-pow((tapDistDesign - ringRadius) / ringWidth, 2.0)) -
            0.34 * exp(-pow((tapDistDesign - ringRadius + ringWidth * 0.72) / (ringWidth * 1.28), 2.0));
        finiteRipple += ring * ringEnabled * (1.0 - index * 0.075);
    }
    float rippleFade = exp(-waveProgress * 1.35 / max(shockTrail, 0.30));
    float rippleAmount =
        rippleAmplitude *
        finiteRipple *
        rippleEnvelope *
        rippleFade;
    float2 rippleDir = normalize(touchDeltaDesign + float2(0.001, 0.001));
    float2 shadertoyRippleWarp = rippleAmount * rippleDir;
    float shadertoyRippleLight = rippleAmount / max(rippleAmplitude, 1.0);

    // A continuous, soft water response that remains visible while the finger moves.
    float localWaterPressure =
        exp(-pow(tapDistDesign / max(92.0 * waveSpread, 1.0), 2.0)) *
        rippleEnvelope;
    float localWaterWave =
        finiteRipple *
        rippleEnvelope *
        rippleFade;
    float2 localWaterWarp =
        rippleDir *
        (
            localWaterWave * (5.2 + 2.0 * shockStrength) +
            localWaterPressure * 2.8
        );

    float frontNoise =
        12.0 * sin(p.y * 0.018 + time * 2.1) +
        7.0 * sin(p.y * 0.034 - time * 1.4);

    float frontDist = abs(p.x - tapPxDesign.x + frontNoise);
    float primaryFront =
        exp(-pow(frontDist / max(mix(46.0, 82.0, waveSpread), 1.0), 2.0)) *
        shockActive;

    float secondaryFront =
        exp(-pow((frontDist - mix(42.0, 128.0 * shockTrail, shockAge)) / max(mix(104.0, 162.0, waveSpread), 1.0), 2.0)) *
        shockActive *
        (0.72 - 0.26 * shockAge);

    float screenRing =
        exp(-pow((tapDistDesign - mix(42.0, 310.0 * shockTrail, shockAge)) / max(172.0 * safeWaveSpread, 1.0), 2.0)) *
        shockActive *
        (0.38 + 0.62 * tapPulse);

    float diagonalAxis =
        dot(touchDeltaDesign, normalize(float2(0.58 * shockSide, 0.82))) +
        18.0 * sin(p.y * 0.020 + time * 1.9);

    float diagonalWake =
        exp(-pow(diagonalAxis / max(150.0 * safeWaveSpread, 1.0), 2.0)) *
        exp(-pow(touchDeltaDesign.x / max(420.0 * safeShockTrail, 1.0), 2.0)) *
        shockActive *
        (0.46 + 0.36 * tapPulse);

    float causticPulse =
        (0.5 + 0.5 * sin(tapDistDesign * 0.050 - travelingPhase * 1.7 + shockAge * 8.2)) *
        screenRing *
        shockActive *
        (0.64 + 0.36 * shockInteraction);

    float crossingFront =
        primaryFront * secondaryFront +
        screenRing * diagonalWake;

    float interferenceField =
        (0.5 + 0.5 * sin(tapDistDesign * 0.042 - travelingPhase * 1.35)) *
        (0.5 + 0.5 * sin((touchDeltaDesign.x * shockSide + touchDeltaDesign.y * 0.54) * 0.034 + travelingPhase)) *
        shockActive *
        shockInteraction;

    float selfCoupling =
        clamp(crossingFront * (0.72 + 0.46 * shockInteraction) + interferenceField * 0.44, 0.0, 1.8);

    float compositeShock =
        primaryFront * 0.54 +
        secondaryFront * 0.38 +
        screenRing * 0.34 +
        diagonalWake * 0.28 +
        causticPulse * 0.16 +
        selfCoupling * 0.30;

    float touchPush =
        exp(-pow(tapDistDesign * 0.0052, 2.0)) *
        tapPulse *
        shockActive;

    float2 tapDir = normalize(p - tapPxDesign + float2(0.001, 0.001));
    float2 frontDir = normalize(float2(shockSide, 0.16 * sin(p.y * 0.021 + time * 1.7)));
    float2 diagonalDir = normalize(float2(0.46 * shockSide, 0.72));
    float2 tapWarp =
        shadertoyRippleWarp * (0.58 + 0.16 * waveStrength) +
        localWaterWarp +
        tapDir * touchPush * 6.0 +
        frontDir * compositeShock * 7.0 +
        diagonalDir * (diagonalWake + selfCoupling * 0.38) * 3.5 +
        float2(0.0, -1.0) * (causticPulse + interferenceField * 0.24) * 2.0;

    float centerPull =
        exp(-pow((p.x - 187.5) / 140.0, 2.0));

    float verticalFlowPull =
        centerPull *
        segmentEase(progress, 0.18, 0.92) *
        34.0 *
        waveStrength;

    float2 flowWarp = refractionWarp + tapWarp;
    float2 liquidFlowWarp = float2(0.0, flowWarp.y);

    pGlobal += liquidFlowWarp * 0.82;
    pGlobal.y += verticalFlowPull;

    float backSpeed = mix(0.70, 0.78, completed);
    float mainSpeed = mix(1.00, 0.92, completed);
    float rimSpeed = mix(1.30, 1.10, completed);

    float2 pShape1Back = pStretched + float2(horizontalDrift * 0.30, baseShiftY * backSpeed * 0.82);
    float2 pShape2Back = pStretched + float2(horizontalDrift * 0.40, baseShiftY * backSpeed * 0.96);
    float2 pWave1Back  = pStretched + float2(horizontalDrift * 0.48, baseShiftY * backSpeed * 0.92);
    float2 pWave2Back  = pStretched + float2(horizontalDrift * 0.50, baseShiftY * backSpeed * 1.04);

    float2 pShape1 = pStretched + float2(horizontalDrift * 0.55, baseShiftY * mainSpeed * 0.95);
    float2 pShape2 = pStretched + float2(horizontalDrift * 0.80, baseShiftY * mainSpeed * 1.12);
    float2 pBgUp   = pStretched + float2(horizontalDrift * 0.30, baseShiftY * mainSpeed * 0.34);
    float2 pWave1  = pStretched + float2(horizontalDrift * 1.05, baseShiftY * mainSpeed * 1.00);
    float2 pWave2  = pStretched + float2(horizontalDrift * 0.95, baseShiftY * mainSpeed * 1.16);

    float2 pRim1 = pStretched + float2(horizontalDrift * 1.28, baseShiftY * rimSpeed * 1.22);
    float2 pRim2 = pStretched + float2(horizontalDrift * 1.10, baseShiftY * rimSpeed * 1.30);

    pShape1Back += liquidFlowWarp * 0.18;
    pShape2Back += liquidFlowWarp * 0.24;
    pWave1Back += liquidFlowWarp * 0.28;
    pWave2Back += liquidFlowWarp * 0.30;

    pShape1 += liquidFlowWarp * 0.50;
    pShape2 += liquidFlowWarp * 0.58;
    pWave1 += liquidFlowWarp * 0.72;
    pWave2 += liquidFlowWarp * 0.68;

    pRim1 += liquidFlowWarp * 0.95;
    pRim2 += liquidFlowWarp * 0.88;

    float2 deepWarp = float2(
        0.0,
        cos(p.x * 0.010 + time * 0.32) * 8.0
    );

    pShape1Back += deepWarp * 0.22;
    pShape2Back += deepWarp * 0.28;
    pWave1Back += deepWarp * 0.34;
    pWave2Back += deepWarp * 0.36;

    pShape1 += deepWarp * 0.52;
    pShape2 += deepWarp * 0.60;
    pWave1 += deepWarp * 0.78;
    pWave2 += deepWarp * 0.72;

    pRim1 += deepWarp * 1.05;
    pRim2 += deepWarp * 0.96;

    // --------------------------------------------------
    // States from specs
    // --------------------------------------------------

    LayerState anim_wave_1 = makeState(
        float2(-38.0, 647.0),
        float2(-238.0, 476.0),
        float2(-121.0, 411.0),
        float2(-117.0, 151.0),

        float2(454.0, 300.0),
        float2(851.0, 562.0),
        float2(619.0, 409.0),
        float2(611.0, 405.0),

        1.00, 0.70, 1.00, 1.00,
        64.0, 64.0, 120.0, 160.0,
        progress
    );

    LayerState anim_wave_2 = makeState(
        float2(-99.0, 364.0),
        float2(-99.0, 442.0),
        float2(-218.0, 197.0),
        float2(-106.0, -107.0),

        float2(556.0, 298.0),
        float2(573.0, 307.0),
        float2(875.0, 466.0),
        float2(589.0, 316.0),

        1.00, 1.00, 1.00, 1.00,
        128.0, 160.0, 120.0, 88.0,
        progress
    );

    LayerState bg_up_02 = makeState(
        float2(-50.0, 37.0),
        float2(-32.0, 37.0),
        float2(-50.0, 37.0),
        float2(-50.0, 37.0),

        float2(475.0, 787.0),
        float2(440.0, 787.0),
        float2(475.0, 787.0),
        float2(475.0, 787.0),

        0.10, 1.00, 1.00, 1.00,
        64.0, 120.0, 64.0, 64.0,
        progress
    );

    LayerState shape_2 = makeState(
        float2(0.0, 705.0),
        float2(-44.0, 856.0),
        float2(-67.0, 663.0),
        float2(-50.0, 702.0),

        float2(375.0, 251.0),
        float2(463.0, 309.0),
        float2(509.0, 340.0),
        float2(475.0, 317.0),

        0.60, 0.70, 0.20, 1.00,
        88.0, 88.0, 88.0, 88.0,
        progress
    );

    LayerState shape_1 = makeState(
        float2(-50.0, 308.0),
        float2(-24.0, 351.0),
        float2(11.0, 78.0),
        float2(-50.0, 308.0),

        float2(475.0, 787.0),
        float2(423.0, 701.0),
        float2(353.0, 585.0),
        float2(475.0, 787.0),

        1.00, 1.00, 0.40, 1.00,
        64.0, 64.0, 146.0, 65.0,
        progress
    );

    // --------------------------------------------------
    // Back liquid layer
    // --------------------------------------------------

    float backShape1 = blueTrapField(
        pShape1Back,
        shape_1,
        87.3259 / 475.0,
        379.735 / 475.0,
        0.0,
        1.0,
        709.291 / 787.0,
        17.4917 / 787.0,
        0.72 * blueDepth
    );

    float backShape2 = blueTrapField(
        pShape2Back,
        shape_2,
        68.9415 / 375.0,
        299.791 / 375.0,
        0.0,
        1.0,
        226.216 / 251.0,
        5.57866 / 251.0,
        0.62 * blueDepth
    );

    float backWave1 = blueTrapField(
        pWave1Back,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        0.72 * blueDepth
    );

    float backWave2 = blueTrapField(
        pWave2Back,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        0.78 * blueDepth
    );

    float backMass = backShape1 + backShape2 + backWave1 + backWave2;
    float backAlpha = 1.0 - exp(-backMass * 0.86);
    backAlpha = clamp(backAlpha * bottomReveal * finalFade, 0.0, 1.0);

    // --------------------------------------------------
    // Main liquid layer
    // --------------------------------------------------

    float shape1Field = blueTrapField(
        pShape1,
        shape_1,
        87.3259 / 475.0,
        379.735 / 475.0,
        0.0,
        1.0,
        709.291 / 787.0,
        17.4917 / 787.0,
        1.08 * blueDepth
    );

    float shape2Field = blueTrapField(
        pShape2,
        shape_2,
        68.9415 / 375.0,
        299.791 / 375.0,
        0.0,
        1.0,
        226.216 / 251.0,
        5.57866 / 251.0,
        0.96 * blueDepth
    );

    float bgUpField = blueTrapField(
        pBgUp,
        bg_up_02,
        0.0,
        1.0,
        87.3259 / 475.0,
        379.735 / 475.0,
        77.709 / 787.0,
        769.508 / 787.0,
        1.03 * blueDepth
    );

    float wave2Field = blueTrapField(
        pWave2,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        1.25 * blueDepth
    );

    float wave1Field = blueTrapField(
        pWave1,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        1.18 * blueDepth
    );

    float svgBlueMass =
        shape1Field +
        shape2Field +
        bgUpField +
        wave1Field +
        wave2Field;

    float mainAlpha = 1.0 - exp(-svgBlueMass * 1.28);
    mainAlpha = clamp(mainAlpha * bottomReveal * finalFade, 0.0, 1.0);

    // --------------------------------------------------
    // Front rim liquid layer
    // --------------------------------------------------

    float rimWave1 = blueTrapField(
        pRim1,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        1.05
    );

    float rimWave2 = blueTrapField(
        pRim2,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        0.98
    );

    float rimAlpha = clamp((rimWave1 + rimWave2) * bottomReveal * rimFinalFade, 0.0, 1.0);
    rimAlpha = smoothstep(0.22, 0.88, rimAlpha);

    float massBreath =
        1.0 +
        0.025 * sin(time * 0.72) +
        0.014 * sin(time * 1.13);

    mainAlpha = clamp(mainAlpha * massBreath, 0.0, 1.0);
    backAlpha = clamp(backAlpha * (1.0 + 0.018 * sin(time * 0.55 + 1.2)), 0.0, 1.0);
    rimAlpha = clamp(rimAlpha * (1.0 + 0.016 * sin(time * 0.80 + 2.1)), 0.0, 1.0);

    float lateAlphaFade = lateTransparency;

    mainAlpha *= mix(1.0, 0.54, lateAlphaFade);
    backAlpha *= mix(1.0, 0.48, lateAlphaFade);
    rimAlpha *= mix(1.0, 0.36, lateAlphaFade);

    // --------------------------------------------------
    // Liquid color model
    // --------------------------------------------------

    float flow =
        0.023 * sin(pGlobal.x * 0.030 + time * 0.75 + rise * 2.2) +
        0.016 * sin(pGlobal.x * 0.070 - time * 0.55 + rise * 3.7) +
        0.011 * sin((pGlobal.x + pGlobal.y) * 0.035 + time * 0.45);

    float liquidY = clamp(
        uv.y * 0.74 + 0.14 + flow - rise * 0.14,
        0.0,
        1.0
    );

    // --------------------------------------------------
    // Delayed blue color ramp
    // --------------------------------------------------

    float blueEmergence = segmentEase(progress, 0.40, 0.56);
    float deepBlueEmergence = segmentEase(progress, 0.54, 0.78);
    float earlySoftness = 1.0 - blueEmergence;

    float targetBluePhase =
        segmentEase(progress, 0.50, 0.62) *
        (1.0 - segmentEase(progress, 0.80, 0.94));

    float3 softAqua = mix(
        cyan,
        aqua,
        0.62
    );

    float3 softBlue = mix(
        aqua,
        targetBlue,
        0.46
    );

    float3 backColor = mix(
        softAqua,
        softBlue,
        smoothstep(0.16, 0.88, liquidY) * blueEmergence
    );

    backColor = mix(
        backColor,
        targetBlue,
        targetBluePhase * 0.72
    );

    backColor = mix(
        backColor,
        mix(targetBlue, deepBlue, 0.26),
        smoothstep(0.78, 1.0, liquidY) * deepBlueEmergence * 0.38
    );

    float3 mainColor = mix(
        cyan,
        aqua,
        smoothstep(0.02, 0.48, liquidY)
    );

    mainColor = mix(
        mainColor,
        softBlue,
        smoothstep(0.34, 0.78, liquidY) * blueEmergence
    );

    mainColor = mix(
        mainColor,
        targetBlue,
        smoothstep(0.44, 0.88, liquidY) * blueEmergence * 0.78
    );

    mainColor = mix(
        mainColor,
        targetBlue,
        targetBluePhase * 0.86
    );

    mainColor = mix(
        mainColor,
        mix(targetBlue, deepBlue, 0.22),
        smoothstep(0.78, 1.0, liquidY) * deepBlueEmergence * 0.42
    );

    mainColor = mix(
        mainColor,
        mix(cyan, aqua, 0.54),
        earlySoftness * 0.38
    );

    backColor = mix(
        backColor,
        mix(cyan, aqua, 0.46),
        earlySoftness * 0.32
    );

    float3 rimColor = mix(
        electric,
        cyan,
        smoothstep(0.0, 1.0, liquidY)
    );

    rimColor = mix(
        rimColor,
        mix(cyan, aqua, 0.52),
        earlySoftness * 0.28
    );

    rimColor = mix(
        rimColor,
        mix(targetBlue, cyan, 0.22),
        targetBluePhase * 0.56
    );

    float3 result = white;

    result = plusDarkerApprox(
        result,
        backColor,
        backAlpha * 0.72
    );

    result = plusDarkerApprox(
        result,
        mainColor,
        mainAlpha
    );

    result += rimColor * rimAlpha * 0.035;

    // --------------------------------------------------
    // Idle wave render
    // --------------------------------------------------

    float idleLuminanceBefore = dot(result, float3(0.299, 0.587, 0.114));

    float idleBlueOnWhite =
        idleWaveEnergy *
        smoothstep(0.56, 1.0, idleLuminanceBefore);

    float idleWhiteOnBlue =
        idleWaveEnergy *
        (1.0 - smoothstep(0.35, 0.88, idleLuminanceBefore));

    result = mix(
        result,
        min(result, waveMid),
        idleBlueOnWhite * 0.22
    );

    result += idleBlueOnWhite * waveDeep * 0.08;
    result += idleWhiteOnBlue * waveGlass * 0.14;
    result += idleWaveEnergy * waveEdge * 0.10;

    // --------------------------------------------------
    // Organic reveal edge glow + surface tension
    // --------------------------------------------------

    result += revealEdgeGlow * float3(0.25, 0.82, 1.0);
    result += revealEdgeGlow * float3(0.75, 1.00, 1.0) * 0.32;

    result += tensionCore * float3(0.56, 1.00, 1.0) * 0.34;

    result += liquidRimLine * float3(0.75, 1.0, 1.0) * 0.18;
    result += liquidRimLine * float3(0.10, 0.55, 1.0) * 0.08;

    result = plusDarkerApprox(
        result,
        deepBlue,
        tensionShadow * 0.18
    );

    // --------------------------------------------------
    // Surface glow
    // --------------------------------------------------

    float liquidAlpha = clamp(mainAlpha + backAlpha * 0.52, 0.0, 1.0);
    float surfaceEnergy = liquidAlpha * (1.0 - liquidAlpha);

    float surfaceGlow = smoothstep(0.08, 0.25, surfaceEnergy);

    result += surfaceGlow * float3(0.10, 0.56, 1.0) * 0.10 * finalFade;
    result += surfaceGlow * float3(0.56, 1.00, 1.0) * 0.045 * finalFade;

    // --------------------------------------------------
    // Bottom clearing
    // --------------------------------------------------

    float bottomClearPower = mix(
        0.38,
        0.68,
        bottomCleanProgress
    );

    result = plusLighterApprox(
        result,
        white,
        min(bottomClear * bottomClearPower, 0.68)
    );

    liquidAlpha *= (1.0 - bottomClear * 0.82);

    // --------------------------------------------------
    // Central white glass lens
    // --------------------------------------------------

    float circleSoftness = mix(
        38.0,
        92.0,
        circleGrowth
    );

    float angle = atan2(
        p.y - center.y,
        p.x - center.x
    );

    float circleNoiseFade = 1.0 - segmentEase(progress, 0.88, 1.00);

    float circleNoise =
        (
            4.2 * sin(angle * 3.0 + time * 0.50) +
            2.6 * sin(angle * 7.0 - time * 0.38)
        ) * circleNoiseFade;

    float circleDist =
        distance(p, center) -
        circleRadius +
        circleNoise;

    float circleFill = 1.0 - smoothstep(
        -circleSoftness * 0.52,
        circleSoftness,
        circleDist
    );

    float circleVisibility = mix(
        0.68,
        0.98,
        smoothstep(0.0, 0.75, progress)
    );

    float visibleCircleFill = circleFill * circleAppear;

    result += visibleCircleFill * circleVisibility * float3(0.12, 0.74, 1.0) * 0.030;

    float circleEdge = exp(-abs(circleDist) / 30.0);
    float tightCircleRim = exp(-abs(circleDist) / 10.0);

    float innerRim = circleEdge * visibleCircleFill * 0.20;

    result += innerRim * float3(0.35, 0.88, 1.0);

    float lensLowerShadow =
        visibleCircleFill *
        smoothstep(center.y - circleRadius * 0.10, center.y + circleRadius * 0.72, p.y) *
        0.055;

    result = mix(
        result,
        result * float3(0.965, 0.985, 1.0),
        lensLowerShadow
    );

    float contactGlow =
        circleEdge *
        liquidAlpha *
        circleAppear *
        (1.0 - circleFill * 0.38);

    float contactTightRim =
        tightCircleRim *
        liquidAlpha *
        circleAppear *
        (1.0 - circleFill * 0.22);

    float magneticPull = segmentEase(progress, 0.35, 0.85);

    float chromaticEdge =
        tightCircleRim *
        liquidAlpha *
        circleAppear *
        (0.35 + 0.65 * magneticPull);

    // Лёгкая хроматическая аберрация при столкновении с центральной маской.
    float2 dirFromCenter = normalize(p - center + float2(0.0001, 0.0001));
    float2 chromaAxis = normalize(float2(0.86, -0.34));

    float chromaDot = dot(dirFromCenter, chromaAxis);
    float redSide = smoothstep(-0.15, 1.0, chromaDot);
    float cyanSide = smoothstep(-0.15, 1.0, -chromaDot);

    result.r += chromaticEdge * redSide * 0.010 * finalFade;
    result.g += chromaticEdge * cyanSide * 0.010 * finalFade;
    result.b += chromaticEdge * cyanSide * 0.022 * finalFade;

    result += contactGlow * float3(0.12, 0.68, 1.0) * (0.76 + magneticPull * 0.18) * finalFade;
    result += contactGlow * float3(0.68, 1.00, 1.0) * (0.30 + magneticPull * 0.12) * finalFade;
    result += contactTightRim * float3(0.72, 1.00, 1.0) * (0.22 + magneticPull * 0.10) * finalFade;

    float innerHalo = exp(
        -max(distance(p, center) - circleRadius * 0.54, 0.0) / 78.0
    );

    result = mix(
        result,
        white,
        innerHalo * 0.11 * circleVisibility * circleAppear
    );

    // --------------------------------------------------
    // Tap blob / residual trail
    // --------------------------------------------------

    float2 tapPx = tapPoint * size;
    float tapDist = distance(position, tapPx);

    float tapTrail =
        exp(-pow(tapDist * 0.010, 2.0)) *
        tapPulse *
        mainAlpha *
        0.10;

    float tapBlobNoise =
        sin(position.x * 0.035 + time * 1.8) *
        sin(position.y * 0.026 - time * 1.3);

    tapTrail *= smoothstep(-0.15, 0.75, tapBlobNoise);

    result += tapTrail * white * finalFade;

    float screenTrailNoise =
        20.0 * sin(uv.y * 13.0 + time * 1.85) +
        12.0 * sin(uv.y * 27.0 - time * 1.10);

    float2 touchDeltaPx = position - tapPx;
    float touchSide = touchDeltaPx.x >= 0.0 ? 1.0 : -1.0;
    float visualShock = dragWave * shockStrength;
    float screenTrailDist = abs(touchDeltaPx.x + screenTrailNoise);
    float screenTrail =
        exp(-pow(screenTrailDist / max(62.0 * waveSpread * shockTrail, 1.0), 2.0)) *
        visualShock *
        mainAlpha *
        finalFade *
        0.22;

    float secondaryTrail =
        exp(-pow((screenTrailDist - mix(70.0, 178.0 * shockTrail, 1.0 - tapPulse)) / max(104.0 * waveSpread, 1.0), 2.0)) *
        visualShock *
        (0.64 + 0.36 * tapPulse) *
        mainAlpha *
        finalFade *
        0.20;

    float diagonalTrailAxis =
        dot(touchDeltaPx, normalize(float2(0.55 * touchSide, 0.83))) +
        22.0 * sin(uv.y * 16.0 + time * 1.6);

    float diagonalTrail =
        exp(-pow(diagonalTrailAxis / max(170.0 * waveSpread, 1.0), 2.0)) *
        exp(-pow(touchDeltaPx.x / max(size.x * 0.82 * shockTrail, 1.0), 2.0)) *
        visualShock *
        mainAlpha *
        finalFade *
        0.18;

    float screenRipple =
        exp(-pow((tapDist - mix(96.0, max(size.x, size.y) * 0.76 * shockTrail, 1.0 - tapPulse)) / max(124.0 * waveSpread, 1.0), 2.0)) *
        visualShock *
        (0.35 + 0.65 * tapPulse) *
        mainAlpha *
        finalFade;

    float causticLines =
        (0.5 + 0.5 * sin(tapDist * 0.062 - time * (6.2 + 1.8 * shockInteraction) + (1.0 - tapPulse) * 7.8)) *
        screenRipple *
        visualShock *
        (0.62 + 0.38 * shockInteraction);

    float wakeCrossing =
        (screenTrail * secondaryTrail + diagonalTrail * screenRipple) *
        (0.76 + 0.44 * shockInteraction);

    float wakeInterference =
        (0.5 + 0.5 * sin(tapDist * 0.040 - time * 5.1)) *
        (0.5 + 0.5 * sin((touchDeltaPx.x * touchSide + touchDeltaPx.y * 0.42) * 0.032 + time * 4.2)) *
        visualShock *
        shockInteraction *
        mainAlpha *
        finalFade;

    float compositeWake =
        screenTrail * 0.48 +
        secondaryTrail * 0.36 +
        diagonalTrail * 0.30 +
        screenRipple * 0.28 +
        causticLines * 0.18 +
        wakeCrossing * 0.42 +
        wakeInterference * 0.16;

    result += screenTrail * white * 0.040;
    result += secondaryTrail * white * 0.032;
    result += diagonalTrail * white * 0.034;
    result += screenRipple * white * 0.044;
    result += causticLines * white * 0.026;
    result += wakeCrossing * white * 0.035;
    result += wakeInterference * white * 0.024;

    // --------------------------------------------------
    // Top reservoir + cinematic finish
    // --------------------------------------------------

    float3 stableFinishColor = mix(
        targetBlue,
        cyan,
        0.18
    );

    float3 initialBottomLikeColor = stableFinishColor;

    float topBreath =
        1.0 +
        completed *
        (
            0.08 * sin(time * 1.55) +
            0.035 * sin(time * 2.25)
        );

    float finalCoreSoft = 1.0 - 0.50 * finalBlur;
    float finalMistBoost = 1.0 + 1.25 * finalBlur;

    float topReservoir =
        exp(-uv.y * 3.20) *
        topReservoirProgress *
        0.38 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topReservoirCore =
        exp(-uv.y * 7.00) *
        topReservoirProgress *
        0.30 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topReservoirGlow =
        exp(-pow((uv.y - 0.125) / 0.26, 2.0)) *
        topReservoirProgress *
        0.13 *
        topBreath *
        finalFade *
        finalMistBoost;

    result = plusDarkerApprox(
        result,
        initialBottomLikeColor,
        topReservoir
    );

    result = plusDarkerApprox(
        result,
        mix(targetBlue, deepBlue, 0.18),
        topReservoirCore
    );

    result += topReservoirGlow * float3(0.22, 0.80, 1.0);

    float finish = topCapProgress;

    float topCapAlpha =
        exp(-uv.y * 4.8) *
        finish *
        0.34 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topCapMist =
        exp(-uv.y * 1.22) *
        finish *
        0.13 *
        topBreath *
        finalFade *
        finalMistBoost;

    result = plusDarkerApprox(
        result,
        initialBottomLikeColor,
        topCapAlpha
    );

    result = plusDarkerApprox(
        result,
        mix(targetBlue, deepBlue, 0.14),
        topCapMist
    );

    result += topCapAlpha * float3(0.10, 0.46, 1.0) * 0.10;
    result += topCapMist * float3(0.42, 0.95, 1.0) * 0.045;

    float3 completionMistColor = mix(
        targetBlue,
        cyan,
        0.22
    );

    float completionMist =
        exp(-uv.y * 1.05) *
        completionMistProgress *
        0.12 *
        finalFade *
        finalMistBoost;

    float trailingGlow =
        exp(-pow((uv.y - 0.18) / 0.22, 2.0)) *
        finalBlur *
        0.10 *
        finalFade;

    result += completionMist * completionMistColor;
    result += trailingGlow * float3(0.30, 0.92, 1.0);

    result += completionFlash * float3(0.45, 0.95, 1.0) * 0.08;

    float completionPulse =
        completionBloom *
        (1.0 - 0.35 * sin(time * 2.4));

    float completionTopGlow =
        exp(-uv.y * 4.2) *
        completionPulse *
        0.06 *
        finalFade;

    result += completionTopGlow * float3(0.30, 0.82, 1.0);
    result = mix(result, white, completionBloom * bottomClear * 0.025);

    // --------------------------------------------------
    // Adaptive tap shockwave
    // --------------------------------------------------

    float rippleRadius = (1.0 - tapPulse) * mix(92.0, 310.0, dragWave);

    float rippleRing =
        exp(-pow((tapDist - rippleRadius) * 0.0064, 2.0)) *
        dragWave *
        (0.28 + 0.72 * tapPulse) *
        mix(0.7, 1.15, waveStrength);

    float rippleCore =
        exp(-pow(tapDist * 0.010, 2.0)) *
        dragWave *
        0.10 *
        waveStrength;

    float luminance = dot(result, float3(0.299, 0.587, 0.114));

    float blueRingStrength = rippleRing * smoothstep(0.60, 1.0, luminance);
    float whiteRingStrength = rippleRing * (1.0 - smoothstep(0.40, 0.90, luminance));

    float frontBand =
        localWaterPressure * 0.34 +
        abs(localWaterWave) * 0.30 +
        compositeWake * 0.24;

    float glassSheen =
        smoothstep(0.42, 1.0, compositeWake + frontBand) *
        (0.5 + 0.5 * sin(position.y * 0.030 - time * 4.5 + tapDist * 0.015)) *
        visualShock;

    result = mix(
        result,
        white,
        blueRingStrength * 0.08 + frontBand * 0.035
    );

    result += blueRingStrength * white * 0.035;

    result += whiteRingStrength * white * 0.10;
    result += rippleCore * white * 0.08;
    result += frontBand * white * 0.045;
    result += glassSheen * white * 0.026;
    result += max(localWaterWave, 0.0) * white * 0.16;
    result = mix(
        result,
        white,
        max(-localWaterWave, 0.0) * 0.030
    );

    // --------------------------------------------------
    // Keyframe-matched hero wash
    // --------------------------------------------------

    float keyProgress = clamp(progress, 0.0, 0.82);
    float keyPresence = smoothstep(0.02, 0.18, keyProgress) * fillGain;

    float keyedEdgeY = interpKeys(
        0.86,
        0.62,
        0.38,
        -0.10,
        keyProgress
    );

    float keyedFeather = interpKeys(
        0.16,
        0.22,
        0.31,
        0.27,
        keyProgress
    );

    float keyDx = uv.x - 0.5;

    float keyedSag =
        keyDx * keyDx *
        interpKeys(0.26, 0.32, 0.24, -0.30, keyProgress);

    float keyedEdgeNoise =
        0.012 * sin(uv.x * 9.0 + time * 0.24 + keyProgress * 4.0) +
        0.007 * sin(uv.x * 21.0 - time * 0.16 + keyProgress * 7.0) +
        dragWave * 0.018 * sin(uv.x * 13.0 + time * 0.36);

    float keyedLowerMass = smoothstep(
        keyedEdgeY - keyedFeather,
        keyedEdgeY + keyedFeather,
        uv.y + keyedSag + keyedEdgeNoise
    );

    float lowerFade = 1.0 - segmentEase(keyProgress, 0.62, 0.90);
    keyedLowerMass *= keyPresence * lowerFade;

    float keyedBottomWeight = smoothstep(0.28, 0.96, uv.y);
    float keyedLowerCore = keyedLowerMass * keyedBottomWeight * 0.88;

    float keyedCyanBand =
        exp(-pow((uv.y - keyedEdgeY) / max(keyedFeather * 1.18, 0.01), 2.0)) *
        exp(-pow(keyDx / 0.62, 2.0)) *
        keyPresence *
        lowerFade;

    float3 keyedBlueColor = mix(
        targetBlue,
        blue,
        0.10 + 0.18 * smoothstep(0.20, 0.46, keyProgress)
    );

    keyedBlueColor = mix(
        keyedBlueColor,
        mix(targetBlue, deepBlue, 0.12),
        smoothstep(0.50, 0.74, keyProgress) * smoothstep(0.58, 1.0, uv.y)
    );

    float3 keyedLowerColor = mix(
        mix(cyan, aqua, 0.50),
        keyedBlueColor,
        smoothstep(0.48, 1.0, uv.y)
    );

    result = plusDarkerApprox(
        result,
        keyedLowerColor,
        keyedLowerCore * 0.42 * fillGain
    );

    result += keyedCyanBand * float3(0.38, 0.88, 1.0) * 0.045 * waveStrength;

    float lensY = interpKeys(
        0.74,
        0.56,
        0.59,
        0.31,
        keyProgress
    );

    float lensRX = interpKeys(
        0.55,
        0.62,
        0.60,
        0.57,
        keyProgress
    );

    float lensRY = interpKeys(
        0.21,
        0.19,
        0.20,
        0.19,
        keyProgress
    );

    float lensTopFade =
        smoothstep(0.08, 0.24, keyProgress) *
        (1.0 - segmentEase(keyProgress, 0.88, 1.0));

    float lensD =
        pow((uv.x - 0.5) / max(lensRX, 0.01), 2.0) +
        pow((uv.y - lensY) / max(lensRY, 0.01), 2.0);

    float keyedWhiteLens =
        (1.0 - smoothstep(0.56, 1.48, lensD)) *
        lensTopFade;

    float keyedLensHalo =
        exp(-pow((sqrt(max(lensD, 0.0)) - 0.88) / 0.46, 2.0)) *
        lensTopFade;

    result += keyedWhiteLens * float3(0.18, 0.74, 1.0) * 0.030 * whiteCore;
    result += keyedLensHalo * float3(0.44, 0.92, 1.0) * 0.055 * whiteCore;

    float topPhase =
        segmentEase(keyProgress, 0.58, 0.84) *
        (1.0 - segmentEase(keyProgress, 0.94, 1.0));

    float topCurve =
        0.24 +
        keyDx * keyDx * 0.62 +
        0.011 * sin(uv.x * 8.0 + time * 0.20);

    float topCap =
        (1.0 - smoothstep(topCurve - 0.16, topCurve + 0.24, uv.y)) *
        topPhase;

    float topCore =
        exp(-uv.y * 3.1) *
        topPhase;

    float topMistBand =
        exp(-pow((uv.y - topCurve) / 0.26, 2.0)) *
        exp(-pow(keyDx / 0.78, 2.0)) *
        topPhase;

    float3 topKeyColor = mix(
        targetBlue,
        blue,
        0.16 * topBloom
    );

    result = plusDarkerApprox(
        result,
        topKeyColor,
        clamp(topCap * 0.46 + topCore * 0.12, 0.0, 1.0)
    );

    result += topMistBand * float3(0.56, 1.0, 1.0) * 0.13 * topBloom;

    float topWhiteBowl =
        (1.0 - smoothstep(0.62, 1.30, lensD)) *
        topPhase *
        0.70 * whiteCore;

    result += topWhiteBowl * float3(0.14, 0.62, 1.0) * 0.025;

    float2 swipeNow = float2((tapPoint.x - 0.5) * (safeSize.x / safeSize.y) + 0.5, tapPoint.y);
    float2 swipePrevious = float2((previousTouchPoint.x - 0.5) * (safeSize.x / safeSize.y) + 0.5, previousTouchPoint.y);
    float2 swipeUv = float2((uv.x - 0.5) * (safeSize.x / safeSize.y) + 0.5, uv.y);
    float2 swipePath = swipeNow - swipePrevious;
    float swipePathLength = length(swipePath);
    float swipeMovement = smootherLiquid(smoothstep(0.002, 0.030, swipePathLength));
    float swipeEnergy = swipePulse * swipeMovement * smoothstep(0.010, 0.16, swipeStrength);
    float2 swipeDir = swipePath / max(swipePathLength, 0.0001);
    float2 swipeNormal = float2(-swipeDir.y, swipeDir.x);
    float2 swipeCenter = mix(swipePrevious, swipeNow, 0.54);
    float2 swipeDelta = swipeUv - swipeCenter;
    float swipeAlong = dot(swipeDelta, swipeDir);
    float swipeLateral = dot(swipeDelta, swipeNormal);
    float swipeLength = mix(0.26, 0.48, smoothstep(0.004, 0.070, swipePathLength));
    float swipeWidth = mix(0.105, 0.172, smoothstep(0.012, 0.30, swipeStrength));
    float swipeBody =
        (1.0 - smoothstep(swipeLength * 0.42, swipeLength * 0.64, abs(swipeAlong))) *
        exp(-pow(swipeLateral / max(swipeWidth, 0.001), 2.0));
    float swipeCore =
        (1.0 - smoothstep(swipeLength * 0.18, swipeLength * 0.46, abs(swipeAlong))) *
        exp(-pow(swipeLateral / max(swipeWidth * 0.52, 0.001), 2.0));
    float swipeTail =
        smoothstep(-swipeLength * 0.62, -swipeLength * 0.08, swipeAlong) *
        (1.0 - smoothstep(swipeLength * 0.08, swipeLength * 0.60, swipeAlong)) *
        exp(-pow(swipeLateral / max(swipeWidth * 1.28, 0.001), 2.0));
    float swipeRipple =
        0.5 + 0.5 * sin(swipeAlong * 34.0 - swipeLateral * 13.0 + time * 1.8);
    float swipeSmear = clamp((swipeBody * 0.72 + swipeCore * 0.34 + swipeTail * 0.42) * swipeEnergy, 0.0, 1.0);
    float swipeGlassEdge =
        exp(-pow((abs(swipeLateral) - swipeWidth * 0.72) / max(swipeWidth * 0.36, 0.001), 2.0)) *
        (1.0 - smoothstep(swipeLength * 0.38, swipeLength * 0.66, abs(swipeAlong))) *
        swipeEnergy;
    float swipeAura =
        exp(-pow(swipeLateral / max(swipeWidth * 1.72, 0.001), 2.0)) *
        (1.0 - smoothstep(swipeLength * 0.48, swipeLength * 0.82, abs(swipeAlong))) *
        swipeEnergy;
    float swipeFlow =
        (0.5 + 0.5 * sin(swipeAlong * 13.0 - time * 2.2)) *
        exp(-pow(swipeLateral / max(swipeWidth * 1.08, 0.001), 2.0)) *
        swipeEnergy;

    result = mix(
        result,
        white,
        clamp(swipeSmear * (0.66 + swipeCore * 0.28), 0.0, 0.82)
    );
    result = plusDarkerApprox(
        result,
        white,
        clamp(swipeAura * 0.18 + swipeFlow * 0.08, 0.0, 0.24)
    );
    result += swipeSmear * white * 0.050;
    result += swipeGlassEdge * white * (0.044 + swipeRipple * 0.024);

    float grainMask = clamp(
        liquidAlpha +
        backAlpha * 0.55 +
        mainAlpha * 0.35 +
        topReservoirProgress * 0.30 +
        idleWaveEnergy * 0.30,
        0.0,
        1.0
    );

    float grain = (hashLiquid(position + float2(time * 0.37)) - 0.5);

    result += grain * mix(0.0012, 0.0052, grainMask) * finalFade;

    float rippleShade = clamp(shadertoyRippleLight, -1.0, 1.0) * rippleEnvelope;
    result += rippleShade * white * 0.14;
    result = mix(
        result,
        white,
        max(-rippleShade, 0.0) * 0.035
    );

    float3 lightResult = clamp(result, 0.0, 1.0);

    float3 preThemeMotionResult = lightResult;
    float3 darkSourceLightResult = lightResult;

    float motionColorRestore = clamp(
        tapTrail * 2.10 +
        screenTrail * 2.40 +
        secondaryTrail * 2.00 +
        diagonalTrail * 1.85 +
        screenRipple * 1.65 +
        compositeWake * 1.45 +
        frontBand * 1.55 +
        swipeSmear * 1.95 +
        swipeAura * 1.35 +
        swipeGlassEdge * 1.70 +
        abs(rippleShade) * 1.40,
        0.0,
        1.0
    );
    motionColorRestore = smootherLiquid(motionColorRestore);

    float yellowColoredPresence =
        smoothstep(0.018, 0.27, distance(lightResult, white)) *
        (1.0 - motionColorRestore * 0.98);
    float yellowProgressPresence = smoothstep(0.025, 0.16, progress);
    float yellowWarmDepth = smoothstep(0.46, 1.0, uv.y);
    float yellowTopGlow = 1.0 - smoothstep(0.16, 0.58, uv.y);
    float yellowBottomGlow = smoothstep(0.55, 1.0, uv.y);

    float3 yellowLemon = float3(1.0, 0.975, 0.035);
    float3 yellowSoft = float3(1.0, 0.955, 0.24);
    float3 yellowAmber = float3(1.0, 0.635, 0.060);
    float3 yellowTarget = mix(yellowLemon, yellowAmber, smootherLiquid(yellowWarmDepth));
    yellowTarget = mix(yellowTarget, yellowSoft, yellowTopGlow * 0.24);
    yellowTarget = mix(yellowTarget, yellowAmber, yellowBottomGlow * 0.20);

    float yellowWhiteCenterY =
        0.515 +
        0.020 * sin(time * 0.18 + progress * 4.2);

    float yellowWhiteCenterD =
        pow((uv.x - 0.50) / 0.73, 2.0) +
        pow((uv.y - yellowWhiteCenterY) / 0.205, 2.0);

    float yellowWhiteCenter =
        (1.0 - smoothstep(0.58, 1.34, yellowWhiteCenterD)) *
        yellowProgressPresence *
        (1.0 - segmentEase(progress, 0.94, 1.0) * 0.16);

    float yellowTopWash =
        exp(-pow((uv.y - 0.145) / 0.34, 2.0)) *
        yellowColoredPresence *
        0.18;

    float yellowBottomWash =
        exp(-pow((uv.y - 0.955) / 0.30, 2.0)) *
        yellowColoredPresence *
        0.26;

    lightResult = mix(
        lightResult,
        yellowTarget,
        isYellowPreset * clamp(yellowColoredPresence * 0.92, 0.0, 0.92)
    );

    lightResult = mix(
        lightResult,
        white,
        isYellowPreset * clamp(yellowWhiteCenter * 0.84, 0.0, 0.86)
    );

    lightResult += isYellowPreset * yellowTopWash * float3(1.0, 0.96, 0.08);
    lightResult += isYellowPreset * yellowBottomWash * float3(1.0, 0.53, 0.03);
    lightResult = clamp(lightResult, 0.0, 1.0);
    lightResult = mix(
        lightResult,
        preThemeMotionResult,
        isYellowPreset * motionColorRestore
    );

    // Shared travelling-band timing; each light preset applies its own palette below.
    float referenceBandCenter;
    float referenceBandWidth;
    if (progress <= 0.50) {
        float phase = smootherLiquid(progress / 0.50);
        referenceBandCenter = bandMotion(1.105, 0.855, 0.0, -0.838028, progress / 0.50, 0.50);
        referenceBandWidth = mix(0.205, 0.315, phase);
    } else if (progress <= 0.70) {
        float phase = smootherLiquid((progress - 0.50) / 0.20);
        referenceBandCenter = bandMotion(0.855, 0.515, -0.838028, -1.676693, (progress - 0.50) / 0.20, 0.20);
        referenceBandWidth = mix(0.315, 0.285, phase);
    } else {
        float phase = smootherLiquid((progress - 0.70) / 0.30);
        referenceBandCenter = bandMotion(0.515, 0.020, -1.676693, 0.0, (progress - 0.70) / 0.30, 0.30);
        referenceBandWidth = mix(0.285, 0.235, phase);
    }

    // Yellow follows the established Blue entry; Blue geometry stays unchanged.
    referenceBandCenter -= clamp(isBluePreset + isYellowPreset, 0.0, 1.0) * 0.065 * smoothstep(0.0, 0.05, progress) *
        (1.0 - segmentEase(progress, 0.26, 0.45));
    // Continue the shared mass upward after 90%, without changing the clock.
    referenceBandCenter -= 0.075 * segmentEase(progress, 0.90, 1.0);

    float referenceWarp =
        sin(uv.x * 5.7 + time * 0.11) * 0.018 +
        sin(uv.x * 10.4 - time * 0.08 + 1.2) * 0.008;
    float referenceDistance = uv.y + referenceWarp - referenceBandCenter;
    float referenceOuter = exp(-pow(referenceDistance / referenceBandWidth, 2.0));
    float referenceBody = exp(-pow(referenceDistance / (referenceBandWidth * 0.70), 2.0));
    float referenceCore = exp(-pow(referenceDistance / (referenceBandWidth * 0.34), 2.0));
    float referenceEntry = smoothstep(0.002, 0.020, progress);
    referenceOuter *= referenceEntry;
    referenceBody *= referenceEntry;
    referenceCore *= referenceEntry;

    float3 referenceCyan = float3(0.380, 0.910, 1.000);
    float3 referenceBlue = float3(0.259, 0.545, 0.976); // #428BF9
    float3 referenceBlueAccent = float3(0.000, 0.424, 1.000); // #006CFF
    // One broad pigment profile avoids the narrow accent stripe produced by
    // compositing several differently sized blue cores over one another.
    float blueLightDensity = exp(-pow(referenceDistance / (referenceBandWidth * 0.82), 2.0)) * referenceEntry;
    float3 blueLightPigment = mix(referenceCyan, mix(referenceBlue, referenceBlueAccent, 0.36),
        blueLightDensity * blueLightDensity * 0.85);
    float3 referenceBlueResult = mix(white, blueLightPigment,
        referenceOuter * (0.82 + 0.16 * blueLightDensity));

    // Match Blue Light's monotonic depth profile: orange in the dense body,
    // #FFDD2D in the shoulder, then yellow coverage dissolving into white.
    float yellowOrangeWeight = pow(blueLightDensity, 4.0) * 0.60;
    float3 yellowLightOrange = mix(yellowMidColor.rgb, yellowHotColor.rgb, 0.25);
    float3 yellowLightPigment = mix(yellowLightAccent, yellowLightOrange, yellowOrangeWeight);
    float3 referenceYellowResult = mix(white, yellowLightPigment,
        referenceOuter * (0.82 + 0.16 * blueLightDensity));

    lightResult = mix(lightResult, referenceBlueResult, isBluePreset);
    lightResult = mix(lightResult, referenceYellowResult, isYellowPreset);

    float liquidPresence = clamp(distance(darkSourceLightResult, white) * 1.38, 0.0, 1.0);
    float glowPresence = clamp(
        liquidPresence +
        rimAlpha * 0.32 +
        revealEdgeGlow * 0.50 +
        surfaceGlow * 0.22,
        0.0,
        1.0
    );
    float finishLift = segmentEase(progress, 0.76, 1.00);
    float bottomWeightDark = smoothstep(0.32, 1.0, uv.y);
    float topWeightDark = 1.0 - smoothstep(0.10, 0.46, uv.y);
    float finishTopPush =
        finishLift *
        (1.0 - smoothstep(0.11, 0.48, uv.y)) *
        (0.78 + 0.22 * exp(-pow((uv.y - 0.08) / 0.17, 2.0)));
    float sideGlowDark =
        exp(-pow(uv.x / 0.13, 2.0)) +
        exp(-pow((1.0 - uv.x) / 0.13, 2.0));

    float darkLowerField = clamp(
        glowPresence * (0.56 + bottomWeightDark * 0.42) +
        keyedLowerCore * 0.92 +
        keyedCyanBand * 0.44 +
        liquidAlpha * bottomWeightDark * 0.54 +
        surfaceGlow * 0.22,
        0.0,
        1.0
    );
    darkLowerField *= mix(1.0, 0.015, finishLift);

    float darkTopField = clamp(
        topPhase * (topCap * 0.80 + topCore * 0.34 + topMistBand * 0.72) +
        topReservoir * 0.72 +
        topReservoirCore * 0.54 +
        topReservoirGlow * 0.80 +
        completionMist * 0.82 +
        trailingGlow * 0.70 +
        completionTopGlow * 0.80 +
        finishLift * topWeightDark * 1.04 +
        finishTopPush * 0.42,
        0.0,
        1.0
    );

    // The dark palette always starts on a true black canvas. The selected color is
    // revealed only by the progressing field, never inherited from the light result.
    float darkColorReveal = smoothstep(0.015, 0.24, progress);
    darkLowerField *= darkColorReveal;
    darkTopField *= darkColorReveal;

    float cyanWashDark = clamp(
        keyedCyanBand * 0.70 +
        keyedLensHalo * 0.30 +
        revealEdgeGlow * 0.72 +
        rimAlpha * 0.24,
        0.0,
        1.0
    ) * darkColorReveal;

    // One soft, asymmetric reduction of light behind the digits; no ring or
    // constant-radius plateau. Coordinates match the existing counter region.
    float counterDrift = sin(time * 0.16) * 0.006;
    float2 counterDelta = float2(
        (uv.x - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.29,
        (uv.y - 0.475 + sin(uv.x * 8.0 + 0.8) * 0.016 + counterDrift) / 0.090
    );
    float2 counterLobe = float2((uv.x - 0.57) / 0.23, (uv.y - 0.45 + counterDrift) / 0.105);
    float counterProtection = 0.76 * exp(-dot(counterDelta, counterDelta)) +
        0.24 * exp(-dot(counterLobe, counterLobe));
    // A diffuse light pocket restores the clean light-theme counter area
    // without the former circular stroke or stacked glass-lens masks.
    lightResult = mix(lightResult, white, counterProtection * 0.32);

    float centerVoidD =
        pow((uv.x - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.354, 2.0) +
        pow((uv.y - 0.475 + sin(uv.x * 8.0 + 0.8) * 0.014) / 0.150, 2.0);
    float centerVoid = (1.0 - smoothstep(0.36, 1.68, centerVoidD)) *
        mix(0.56, 0.82, smoothstep(0.02, 0.58, progress));
    float centerVoidSoft = (1.0 - smoothstep(0.58, 2.55, centerVoidD)) *
        mix(0.18, 0.32, smoothstep(0.10, 0.72, progress));
    float centerReduction = clamp(centerVoid * 0.58 + centerVoidSoft * 0.18, 0.0, 0.70);

    float topBlackShelf =
        (1.0 - smoothstep(0.20, 0.52, uv.y)) *
        (1.0 - smoothstep(0.0, 0.18, progress)) *
        0.38;

    float3 darkBase = float3(0.0, 0.0, 0.0);
    float3 darkNavy = float3(0.004, 0.010, 0.024);
    float3 darkBlueGlow = mix(
        float3(0.045, 0.230, 0.780),
        float3(0.820, 0.405, 0.018),
        isYellowPreset
    );
    float3 darkElectric = mix(
        float3(0.100, 0.430, 1.000),
        float3(1.000, 0.720, 0.030),
        isYellowPreset
    );
    float3 darkCyan = mix(
        float3(0.520, 0.960, 1.000),
        float3(1.000, 0.925, 0.210),
        isYellowPreset
    );
    float3 darkMintCyan = mix(
        float3(0.650, 1.000, 0.900),
        float3(1.000, 0.970, 0.560),
        isYellowPreset
    );

    float lowerIntensity = smootherLiquid(darkLowerField);
    float topIntensity = smootherLiquid(darkTopField);
    float edgeIntensity = clamp(sideGlowDark * (darkLowerField * 0.30 + darkTopField * 0.34), 0.0, 1.0);

    float3 darkResult = darkBase;
    darkResult = mix(darkResult, darkNavy, clamp(darkLowerField * 0.52 + darkTopField * 0.38, 0.0, 1.0));
    darkResult += mix(darkBlueGlow, darkElectric, smoothstep(0.22, 0.92, lowerIntensity)) * lowerIntensity * 0.82;
    darkResult += darkCyan * cyanWashDark * 0.24;
    darkResult += darkMintCyan * keyedWhiteLens * 0.10 * darkColorReveal;
    darkResult += mix(darkBlueGlow, darkElectric, 0.52) * topIntensity * 0.86;
    darkResult += darkCyan * topMistBand * 0.22 * darkColorReveal;
    darkResult += darkElectric * edgeIntensity * 0.42;
    darkResult += mix(darkBlueGlow, darkElectric, 0.72) * finishTopPush * 0.34;

    darkResult = mix(darkResult, darkBase, clamp(centerVoidSoft, 0.0, 0.34));
    darkResult = mix(darkResult, darkBase, clamp(centerVoid, 0.0, 0.86));
    darkResult = mix(darkResult, darkBase, finishLift * smoothstep(0.30, 0.72, uv.y) * 0.64);
    darkResult = mix(darkResult, darkBase, topBlackShelf);
    float blueIdleAccent = isBluePreset * idleWaveEnergy * (1.0 - motionColorRestore * 0.85);
    darkResult += float3(0.000, 0.423529, 1.000) * blueIdleAccent * 0.74;
    darkResult += float3(0.540, 0.900, 1.000) * blueIdleAccent * 0.24;
    float yellowIdleAccent = isYellowPreset * idleWaveEnergy * (1.0 - motionColorRestore * 0.85);
    darkResult += float3(1.000, 0.780, 0.075) * yellowIdleAccent * 0.62;
    darkResult += float3(1.000, 0.956, 0.365) * yellowIdleAccent * 0.24;

    // Dark mode uses the same travelling band as the light reference. Only the
    // canvas changes to black; no accumulated color remains below the band.
    float3 darkBandOuterColor = mix(targetBlue, cyan, 0.30);
    float3 darkBandBodyColor = mix(targetBlue, electric, 0.34);
    float3 darkBandCoreColor = mix(targetBlue, electric, 0.72);
    if (isYellowPreset > 0.5) {
        // Carry Blue Dark's dominant-channel light field through the shared
        // masks first. Apply Yellow's palette after them, not before dimming.
        darkBandOuterColor = darkBandBodyColor = darkBandCoreColor = float3(1.0);
    }
    float darkBandEntry = smoothstep(0.002, 0.020, progress);
    float darkBandOuter = referenceOuter * darkBandEntry;
    float darkBandBody = referenceBody * darkBandEntry;
    float darkBandCore = referenceCore * darkBandEntry;
    float3 travellingDarkResult = darkBase;
    travellingDarkResult += darkBandOuterColor * darkBandOuter * 0.20;
    travellingDarkResult += darkBandBodyColor * darkBandBody * 0.58;
    travellingDarkResult += darkBandCoreColor * darkBandCore * 0.54;
    travellingDarkResult = mix(
        travellingDarkResult,
        darkBase,
        centerReduction
    );
    darkResult = travellingDarkResult;
    // Clear behind the moving mass, not through its bright core at 70–85%.
    // Rejoin the original completion fade before the explicit endpoint gate.
    float completionBlackout =
        segmentEase(progress, 0.58, 0.98) *
        smoothstep(0.06, 0.38, uv.y) *
        mix(smoothstep(0.04, 0.32, referenceDistance),
            1.0, segmentEase(progress, 0.85, 0.98));
    darkResult = mix(darkResult, darkBase, completionBlackout);
    // Hard safety gate: no color is allowed to leak into a dark-theme canvas at 0%.
    // This is intentionally applied after every dark effect contribution.
    float darkCanvasReveal = smoothstep(0.0, 0.10, progress);
    darkResult = mix(darkBase, darkResult, darkCanvasReveal);

    float finishSync = segmentEase(progress, 0.94, 1.0);
    float endpointCoverage = referenceOuter * (0.82 + 0.16 * blueLightDensity) *
        (1.0 - counterProtection * 0.32);
    float3 endpointColor = isYellowPreset > 0.5 ? float3(1.0) : darkBandCoreColor;
    darkResult = mix(darkResult, endpointColor * endpointCoverage, finishSync);
    // Blue Dark's unbounded density is the only spatial input to palette
    // mapping. A second, narrower body mask made the other palettes read as
    // stripes even though their outer coverage matched Blue.
    float sharedLightField = max(darkResult.r, max(darkResult.g, darkResult.b));
    // REGRESSION LOCK: geometry is resolved ONCE before any of the four palettes.
    // Main/front/free-wave fields contain no theme or color coefficients.
    float idleDensity = idleActivity > 0.0
        ? idleWaveDensity(position, size, idleActivity, idleTime, waveStrength) : 0.0;
    IdleContact contact = sharedIdleContact(sharedLightField, float(half(idleDensity)));
    float3 blueDarkReference = darkResult;
    if (isYellowPreset > 0.5) {
        blueDarkReference = float3(0.10, 0.55, 1.0) * sharedLightField;
        // No endpoint hue/exposure switch, threshold or highlight layer.
        darkResult = yellowDarkDensityPalette(sharedLightField);
    }
    // QA A: MAIN spatial symmetry only. Palette, density readout and all
    // interaction fields above stay original. No RGB/pixel mirroring.
    float qaVisualDistance = referenceDistance;
    float qaVisualCenterReduction = centerReduction;
    float qaVisualCompletion = completionBlackout;
    float3 qaVisualMain = darkResult;
    if (isBluePreset > 0.5 && themeStrength > 0.5) {
        QaCommonMainShape qaCommon = qaCommonMainShape(uv, progress, time,
            referenceBandCenter, referenceWarp, centerVoidD, counterProtection, counterDrift);
        float qaMirrorX = 1.0 - uv.x;
        float qaMirrorWarp = sin(qaMirrorX * 5.7 + time * 0.11) * 0.018 +
            sin(qaMirrorX * 10.4 - time * 0.08 + 1.2) * 0.008;
        qaVisualDistance = qaCommon.distance;
        float qaOuter = qaDisplayMainGaussian(qaVisualDistance,referenceBandWidth,1.0) * referenceEntry;
        float qaBody = qaDisplayMainGaussian(qaVisualDistance,referenceBandWidth,0.70) * referenceEntry;
        float qaCore = qaDisplayMainGaussian(qaVisualDistance,referenceBandWidth,0.34) * referenceEntry;
        float qaMirrorVoidD =
            pow((qaMirrorX - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.354, 2.0) +
            pow((uv.y - 0.475 + sin(qaMirrorX * 8.0 + 0.8) * 0.014) / 0.150, 2.0);
        float qaBalancedVoidD = qaCommon.voidD;
        float qaVoid = qaDisplayCentreProfile(qaBalancedVoidD,progress) *
            mix(0.56, 0.82, smoothstep(0.02, 0.58, progress));
        float qaVoidSoft = (1.0 - smoothstep(0.58, 2.55, qaCompactMainCentre(qaBalancedVoidD,progress))) *
            mix(0.18, 0.32, smoothstep(0.10, 0.72, progress));
        qaVisualCenterReduction = clamp(qaVoid * 0.58 + qaVoidSoft * 0.18, 0.0, 0.70);
        // QA DARK SPOT ONLY: release the fixed counter pocket as MAIN clears it.
        // Contact density above, mapped exterior fade and every palette stay original.
        float qaCounterClearance = (0.475-referenceBandCenter)/referenceBandWidth;
        qaVisualCenterReduction *= 1.0-segmentEase(qaCounterClearance,0.0,0.70);
        qaVisualCompletion = segmentEase(progress, 0.58, 0.98) *
            smoothstep(0.06, 0.38, uv.y) * mix(smoothstep(0.04, 0.32, qaVisualDistance),
                1.0, segmentEase(progress, 0.85, 0.98));
        float2 qaMirrorCounter = float2(
            (qaMirrorX - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.29,
            (uv.y - 0.475 + sin(qaMirrorX * 8.0 + 0.8) * 0.016 + counterDrift) / 0.090);
        float2 qaMirrorLobe = float2((qaMirrorX - 0.57) / 0.23, (uv.y - 0.45 + counterDrift) / 0.105);
        float qaCounter = qaCommon.counter;
        float qaBlueDensity = exp(-pow(qaVisualDistance / (referenceBandWidth * 0.82), 2.0)) * referenceEntry;
        float qaEndpoint = qaOuter * (0.82 + 0.16 * qaBlueDensity) * (1.0 - qaCounter * 0.32);
        // QA: reuse the approved 33% exterior attenuation in MAIN-local coordinates.
        // Original geometry, A symmetry and contact masks above are untouched.
        const float qaFadeReferenceProgress = 0.33;
        float qaFadeReferenceCenter = bandMotion(1.105, 0.855, 0.0, -0.838028,
            qaFadeReferenceProgress / 0.50, 0.50);
        qaFadeReferenceCenter -= 0.065 * smoothstep(0.0, 0.05, qaFadeReferenceProgress) *
            (1.0 - segmentEase(qaFadeReferenceProgress, 0.26, 0.45));
        float qaFadeReferenceWidth = mix(0.205, 0.315,
            smootherLiquid(qaFadeReferenceProgress / 0.50));
        float qaFadeLocalDistance = qaVisualDistance / referenceBandWidth;
        float qaFadeReferenceY = qaFadeReferenceCenter - qaCommon.warp -
            qaFadeLocalDistance * qaFadeReferenceWidth;
        float qaFadeVoidD =
            pow((uv.x - 0.5 + sin(qaFadeReferenceY * 11.0 + time * 0.12) * 0.018) / 0.354, 2.0) +
            pow((qaFadeReferenceY - 0.475 + sin(uv.x * 8.0 + 0.8) * 0.014) / 0.150, 2.0);
        float qaFadeMirrorVoidD =
            pow((qaMirrorX - 0.5 + sin(qaFadeReferenceY * 11.0 + time * 0.12) * 0.018) / 0.354, 2.0) +
            pow((qaFadeReferenceY - 0.475 + sin(qaMirrorX * 8.0 + 0.8) * 0.014) / 0.150, 2.0);
        float qaFadeBalancedVoidD = (qaFadeVoidD + qaFadeMirrorVoidD) * 0.5;
        float qaFadeVoid = (1.0 - smoothstep(0.36, 1.68, qaFadeBalancedVoidD)) *
            mix(0.56, 0.82, smoothstep(0.02, 0.58, qaFadeReferenceProgress));
        float qaFadeVoidSoft = (1.0 - smoothstep(0.58, 2.55, qaFadeBalancedVoidD)) *
            mix(0.18, 0.32, smoothstep(0.10, 0.72, qaFadeReferenceProgress));
        float qaFadeReferenceReduction = clamp(qaFadeVoid * 0.58 + qaFadeVoidSoft * 0.18, 0.0, 0.70);
        // Restrict this readout to the outgoing lower flank beyond the existing core.
        // Reuse core/body radii and the upper-travel interval, not a progress-86 switch.
        // Complete the existing local-mask transition within the core radius.
        // Do not rebuild a second shoulder at the body/core junction.
        float qaFadeExteriorWeight = segmentEase(qaFadeLocalDistance, 0.0, 0.34) *
            segmentEase(progress, 0.70, 0.90);
        float qaFadeTransmission = mix(
            (1.0 - qaVisualCenterReduction) * (1.0 - qaVisualCompletion),
            1.0 - qaFadeReferenceReduction * (1.0 - finishSync), qaFadeExteriorWeight);
        qaVisualMain = (darkBandOuterColor * qaOuter * 0.20 +
            darkBandBodyColor * qaBody * 0.58 + darkBandCoreColor * qaCore * 0.54) *
            darkBandEntry * qaFadeTransmission * darkCanvasReveal;
        // Preserve the travelling profile at completion: synchronize intensity,
        // not a second, broader endpoint geometry. Evaluate its visible peak only.
        float qaPeakY = clamp(referenceBandCenter - qaCommon.warp, 0.0, 1.0);
        float qaPeakU = (qaPeakY + qaCommon.warp - referenceBandCenter) / referenceBandWidth;
        float qaPeakOuter = qaDisplayMainGaussian(qaPeakU,1.0,1.0);
        float qaPeakBody = qaDisplayMainGaussian(qaPeakU,1.0,0.70);
        float qaPeakCore = qaDisplayMainGaussian(qaPeakU,1.0,0.34);
        float qaPeakBlue = exp(-pow(qaPeakU / 0.82, 2.0));
        float2 qaPeakCounter = float2(
            (uv.x - 0.5 + sin(qaPeakY * 11.0 + time * 0.12) * 0.018) / 0.29,
            (qaPeakY - 0.475 + sin(uv.x * 8.0 + 0.8) * 0.016 + counterDrift) / 0.090);
        float2 qaPeakLobe = float2((uv.x - 0.57) / 0.23, (qaPeakY - 0.45 + counterDrift) / 0.105);
        float2 qaPeakMirrorCounter = float2(
            (qaMirrorX - 0.5 + sin(qaPeakY * 11.0 + time * 0.12) * 0.018) / 0.29,
            (qaPeakY - 0.475 + sin(qaMirrorX * 8.0 + 0.8) * 0.016 + counterDrift) / 0.090);
        float2 qaPeakMirrorLobe = float2((qaMirrorX - 0.57) / 0.23, (qaPeakY - 0.45 + counterDrift) / 0.105);
        float qaPeakProtection = (0.76 * exp(-dot(qaPeakCounter, qaPeakCounter)) +
            0.24 * exp(-dot(qaPeakLobe, qaPeakLobe)) +
            0.76 * exp(-dot(qaPeakMirrorCounter, qaPeakMirrorCounter)) +
            0.24 * exp(-dot(qaPeakMirrorLobe, qaPeakMirrorLobe))) * 0.5;
        float qaEndpointPeak = qaPeakOuter * (0.82 + 0.16 * qaPeakBlue) * (1.0 - qaPeakProtection * 0.32);
        float qaTravellingPeak = qaPeakOuter * 0.20 + qaPeakBody * 0.58 + qaPeakCore * 0.54;
        qaVisualMain *= mix(1.0, qaEndpointPeak / max(qaTravellingPeak, 0.000001), finishSync);
        qaVisualMain*=qaCentreMainRetention(qaOuter,qaBody,qaCore,qaCommon.voidD,progress);
        qaVisualMain+=darkBandOuterColor*qaRestoreMainOuter(qaOuter,darkBandEntry,darkCanvasReveal,
            qaFadeTransmission,qaVisualDistance,referenceBandWidth,qaCommon.voidD,progress);
        // QA complete display-shape transfer, not a partial peripheral mask.
        // Preserve33/63 and the accepted endpoint with existing travel keys.
        float qaShapeTransfer=segmentEase(progress,0.70,0.76)*(1.0-finishSync);
        if(qaShapeTransfer>0.0) {
            float qaLightShape=qaAcceptedLightShapeDensity(uv,progress,time,
                referenceBandCenter,referenceBandWidth);
            // Same display density, original Dark RGB readout. Do not apply
            // per-column peak ratios: their lobe crossings form tunnel walls.
            float3 qaShapeMain=darkBandCoreColor*qaLightShape;
            qaVisualMain=mix(qaVisualMain,qaShapeMain,qaShapeTransfer);
        }
        if(progress>0.85) {
            qaVisualMain=darkBandCoreColor*qaMainAtPose(uv,progress,time,true);
        } else if(progress>0.78) {
            float density=qaVisualMain.b;
            qaVisualMain*=qaDarkLateFade(density,qaVisualDistance/referenceBandWidth,progress)/
                max(density,0.000001);
        }
        darkResult = qaVisualMain;
    }
    float qaMainGrain=grain;
    if(isBluePreset>0.5 && themeStrength>0.5 && progress>0.85)
        qaMainGrain=hashLiquid(position+float2(qaMainPoseTime(progress,time)*0.37))-0.5;
    darkResult += qaMainGrain * mix(0.0010, 0.0035, grainMask) *
        (1.0 - completionBlackout) * darkCanvasReveal;
    blueDarkReference = clamp(blueDarkReference + grain * mix(0.0010, 0.0035, grainMask) *
        (1.0 - completionBlackout) * darkCanvasReveal, 0.0, 1.0);
    float3 finishedDark = clamp(darkResult, 0.0, 1.0);
    if (isBluePreset > 0.5 && themeStrength > 0.5) {
        finishedDark.b = qaNativeBlueCap(darkResult.b);
    }
    // White transmits the same density field. Channel-wise absorption gives
    // blue -> cyan -> white / orange -> yellow -> white continuously, rather
    // than painting a saturated band with separate hue and opacity masks.
    float3 blueTransmission = mix(referenceBlue, referenceBlueAccent, 0.65);
    float3 yellowTransmission = float3(yellowLightOrange.r,
        mix(yellowMidColor.g, yellowHotColor.g, 0.75),
        pow(yellowLightAccent.b, 2.5));
    float3 transmission = mix(blueTransmission, yellowTransmission, isYellowPreset);
    float3 matchingLight = pow(max(transmission, float3(0.0001)), float3(sharedLightField));
    lightResult = mix(lightResult, matchingLight, clamp(isBluePreset + isYellowPreset, 0.0, 1.0));
    result = mix(lightResult, finishedDark, themeStrength);

    // Explicit boundary states for the dark theme. These sit after all palette
    // effects, so a selected color can never replace the black canvas at rest.
    float darkTheme = step(0.5, themeStrength);
    float darkAtRest = 1.0 - smoothstep(0.001, 0.035, progress);
    result = mix(result, darkBase, darkTheme * darkAtRest);
    blueDarkReference = mix(blueDarkReference, darkBase, darkTheme * darkAtRest);

    // Purely visual history; no clock or field value feeds the progress mechanic.
    if (interactionFloatCount > 0) {
        float trail = interactionLightField(uv, safeSize.x / safeSize.y, interactionSegments, interactionFloatCount);
        float readability = 1.0 - 0.88 * counterProtection;
        // Exposure depends on local interaction accumulation, so a first pass
        // cannot start white merely because it crosses a bright progress band.
        float heat = trail;
        float brighter = 1.0 - exp(-max(heat - 0.35, 0.0) * 0.95);
        float excessHeat = max(heat - 1.45, 0.0);
        float exposure = 1.0 - exp(-excessHeat * excessHeat / 3.0);
        float3 trailColor;
        if (isYellowPreset > 0.5) {
            // Channel-wise exponential exposure used to push R and G towards
            // equality, leaving olive on black. Keep warm hue while light grows.
            float3 warm = darkTheme > 0.5
                ? mix(yellowDeepColor.rgb, min(yellowHotColor.rgb * 1.18, 1.0), brighter)
                : mix(yellowHotColor.rgb, yellowLightAccent, 0.48 + brighter * 0.52);
            float cream = smoothstep(0.70, 3.0, heat) * 0.75;
            if (darkTheme < 0.5) {
                // A broad orange interval separates yellow pigment from light,
                // making the trail readable even over a saturated yellow base.
                float orange = exp(-pow((heat - 0.85) / 0.90, 2.0)) *
                    (1.0 - exp(-heat * 2.0)) * 0.75;
                warm = mix(yellowLightAccent, yellowLightOrange, orange);
                cream = smoothstep(1.55, 3.50, heat) * 0.75;
                float accumulatedHeat = max(heat - 2.0, 0.0);
                exposure = 1.0 - exp(-accumulatedHeat * accumulatedHeat / 2.8);
            }
            warm = mix(warm, mix(yellowHotColor.rgb, white, 0.82), cream);
            trailColor = mix(warm, mix(yellowHotColor.rgb, white, 0.94), exposure);
        } else {
            // Reuse the cyan produced by the existing additive idle overlap.
            float3 overlapCyan = clamp(targetBlue + float3(0.14, 0.48, 1.0), 0.0, 1.0);
            float3 lightBlue = mix(targetBlue, mix(referenceCyan, overlapCyan, darkTheme), brighter);
            trailColor = mix(lightBlue, float3(0.91, 0.98, 1.0), exposure);
        }
        // Protect text through coverage, not heat: the mask must not turn a
        // hot white/cyan/cream trail into a different, muddy color at its edge.
        float opacity = (0.78 + 0.22 * exposure) * (1.0 - exp(-trail * 0.95)) * readability;
        if (darkTheme > 0.5) {
            float3 backdrop = result;
            result = 1.0 - (1.0 - result) * (1.0 - trailColor * opacity);
            if (isYellowPreset > 0.5) {
                // Same trail field, alpha and screen blending as Blue Dark;
                // only reduce color energy if the warm overlap is brighter.
                float3 blueTrail = mix(mix(float3(0.10, 0.55, 1.0),
                    float3(0.24, 1.0, 1.0), brighter), float3(0.91, 0.98, 1.0), exposure);
                float3 blueOverlap = 1.0 - (1.0 - blueDarkReference) * (1.0 - blueTrail * opacity);
                // Balance only added trail light: a history buffer must never
                // darken the untouched backdrop, even when its samples faded.
                result = backdrop + balanceYellowDarkLight(max(result - backdrop, 0.0),
                    max(blueOverlap - blueDarkReference, 0.0));
            }
        } else {
            // Keep the old Blue Light screen-pass character, driven by local
            // overlap rather than separate offset strokes. First passes stay colored.
            float pigmentOpacity = opacity * (0.76 + 0.24 * exposure);
            result = mix(result, trailColor, pigmentOpacity);
            float3 screenLight = isYellowPreset > 0.5
                ? mix(yellowLightAccent, white, 0.80)
                : float3(0.80, 0.9059, 1.0); // Original Blue Light screen color.
            result = 1.0 - (1.0 - result) * (1.0 - screenLight * exposure * opacity * 0.42);
        }
    }

    half4 output = half4(half3(clamp(result, 0.0, 1.0)), 1.0);
    if (themeStrength < 0.5 && idleActivity > 0.0) {
        output = blendLightIdle(output, idleWaveColor(idleDensity, 0.0, gradientColorIndex),
            contact, gradientColorIndex, transmission);
    }
    if (themeStrength > 0.5 && (isBluePreset + isYellowPreset) > 0.5 && idleActivity > 0.0) {
        output = blendDarkIdle(output, idleWaveColor(idleDensity, 1.0, gradientColorIndex),
            contact, gradientColorIndex);
    }
    return output;
}

float idleWaveDensity(
    float2 position, float2 size, float activity, float time, float waveStrength
) {
    float2 safeSize = max(size, float2(1.0));
    float2 p = position / safeSize * float2(375.0, 812.0);
    float cycleRaw = fract(time / 3.0);
    float cycle = smootherLiquid(cycleRaw);
    float visibility =
        smoothstep(0.02, 0.11, cycleRaw) *
        (1.0 - smoothstep(0.88, 1.0, cycleRaw)) *
        smootherLiquid(clamp(activity, 0.0, 1.0));

    float waveY = mix(-110.0, 925.0, cycle);
    float width = mix(72.0, 420.0, cycle);
    float thickness = mix(19.0, 42.0, cycle);
    float dx = p.x - 187.5;
    float arcY = waveY + (dx * dx) / max(width * 1.72, 1.0);
    float distanceToArc = p.y - arcY;

    float mainWave =
        exp(-pow(distanceToArc / thickness, 2.0)) *
        exp(-pow(dx / width, 2.0));
    float secondWave =
        exp(-pow((distanceToArc + 72.0) / (thickness * 1.35), 2.0)) *
        exp(-pow(dx / (width * 1.18), 2.0)) *
        0.32;
    float halo =
        exp(-pow((p.y - waveY) / 180.0, 2.0)) *
        exp(-pow(dx / max(width * 1.18, 1.0), 2.0)) *
        0.12;
    float energy = clamp(mainWave + secondWave + halo, 0.0, 1.0) *
        visibility * clamp(waveStrength, 0.3, 2.0);

    return clamp(energy * 0.84, 0.0, 0.86);
}

float lightIdleWaveDensity(float2 position, float2 size, float activity, float time, float waveStrength) {
    float2 p = position / max(size, float2(1.0)) * float2(375.0, 812.0);
    float cycleRaw = fract(time / 3.0);
    float cycle = smootherLiquid(cycleRaw);
    float visibility = smoothstep(0.02, 0.11, cycleRaw) *
        (1.0 - smoothstep(0.88, 1.0, cycleRaw)) * smootherLiquid(clamp(activity, 0.0, 1.0));
    float waveY = mix(-110.0, 925.0, cycle);
    float width = mix(72.0, 420.0, cycle);
    float thickness = mix(19.0, 42.0, cycle);
    float dx = p.x - 187.5;
    float distanceToArc = p.y - waveY - dx * dx / max(width * 1.72, 1.0);
    float energy = exp(-pow(distanceToArc / thickness, 2.0)) * exp(-pow(dx / width, 2.0));
    return clamp(energy * visibility * clamp(waveStrength, 0.3, 2.0) * 0.84, 0.0, 0.86);
}

half4 idleWaveColor(float waveAlpha, float themeStrength, float gradientColorIndex) {
    float preset = clamp(round(gradientColorIndex), 0.0, 4.0);
    float isYellow = 1.0 - step(0.5, abs(preset - 3.0));
    // A single premultiplied light-theme pass can tint white and illuminate
    // pigment. Multiply could only darken; multiply + addition made contours
    // where the two opposite responses cancelled or clipped.
    // Fixed chroma avoids a pale hole in the wave's brighter center.
    // Geometry, halo and alpha are shared with the Blue Dark reference.
    float3 lightWave = mix(float3(0.380, 0.910, 1.0), float3(1.0), 0.04);
    // Yellow Light uses the same warm red/green hue with no white/blue
    // component in its wave pigment, so the filled core stays saturated.
    float3 yellowWavePigment = float3(yellowLightAccent.r, yellowLightAccent.g, 0.0);
    lightWave = mix(lightWave, yellowWavePigment, isYellow);
    float3 darkWave = float3(0.14, 0.48, 1.0);
    // Warm amber source; only RGB changes, not alpha or either wave field.
    float3 warmWave = mix(yellowHotColor.rgb, yellowLightAccent, 0.60);
    darkWave = mix(darkWave, warmWave, isYellow);
    float3 waveColor = mix(lightWave, darkWave, clamp(themeStrength, 0.0, 1.0));

    return half4(half3(waveColor * waveAlpha), half(waveAlpha));
}

half4 acceptedYellowDarkWave(float density) {
    float3 warmWave = mix(yellowMidColor.rgb, yellowLightAccent, 0.20);
    // Keep the warm orange source at its configured exposure. Matching Blue's
    // lower luminance made both free orange and contact yellow muddy.
    return half4(half3(warmWave * density), half(density));
}

half4 idleWaveField(
    float2 position, half4 color, float2 size, float activity, float time,
    float waveStrength, float themeStrength, float gradientColorIndex
) {
    return idleWaveColor(idleWaveDensity(position, size, activity, time, waveStrength),
        themeStrength, gradientColorIndex);
}

[[ stitchable ]]
half4 idleWaveOverlay(
    float2 position, half4 color, float2 size, float activity, float time,
    float waveStrength, float themeStrength, float gradientColorIndex
) {
    return idleWaveField(position, color, size, activity, time, waveStrength,
        themeStrength, gradientColorIndex);
}

float3 idleContactLight(float3 source, float3 contactColor, IdleContact contact) {
    // Color only the free-wave density. The contact assigned to the main
    // front is mapped separately, using the SAME partition in Light/Dark.
    float interiorContact = contact.intersection - contact.frontReaction;
    return source * contact.freeIdle + (contactColor - source) * interiorContact;
}

half4 blendLightIdle(half4 color, half4 wave, IdleContact contact, float gradientColorIndex, float3 transmission) {
    if (wave.a == half(0.0)) { return color; }
    float3 source = float3(wave.rgb) / contact.idle;
    bool isYellow = abs(round(gradientColorIndex) - 3.0) < 0.5;
    bool hasSharedLiquid = isYellow || abs(round(gradientColorIndex)) < 0.5;
    float3 contactColor = isYellow ? float3(yellowLightAccent.r, yellowLightAccent.g, 0.0) : float3(0.24, 1.0, 1.0);
    float3 tint;
    float3 base = float3(color.rgb) / max(float(color.a), 0.00001);
    if (!hasSharedLiquid) {
        // Preserve other presets' original RGB compositing.
        tint = mix(source, contactColor, contact.coverage);
        float3 target = tint + base * (1.0 - base) *
            mix(tint, float3(1.0), 0.55) * 0.55;
        return half4(half3(clamp(mix(base, target, contact.idle), 0.0, 1.0) *
            float(color.a)), color.a);
    }
    if (!isYellow) {
        // The main front has already moved in geometry. Composite its single
        // cyan wave once; interior contact changes chroma without a second rim.
        float3 target = mix(source, contactColor, contact.coverage);
        return half4(half3(clamp(mix(base, target, contact.idle), 0.0, 1.0) * float(color.a)), color.a);
    }
    // Yellow Light: one saturated warm wave over the displaced main front.
    // Retain full warm yellow chroma at intersection; the locally displaced
    // orange main front supplies contrast, not white light or another rim.
    float3 warmContact = float3(1.0, yellowLightAccent.g, 0.0);
    float3 target = mix(source, warmContact, contact.coverage);
    return half4(half3(clamp(mix(base, target, contact.idle), 0.0, 1.0) * float(color.a)), color.a);
}

half4 correctedLightIdle(half4 color, half4 wave, IdleContact contact, float gradientColorIndex, float3 transmission) {
    if (wave.a == half(0.0)) { return color; }
    float3 source = float3(wave.rgb) / contact.idle;
    bool isYellow = abs(round(gradientColorIndex) - 3.0) < 0.5;
    bool hasSharedLiquid = isYellow || abs(round(gradientColorIndex)) < 0.5;
    float3 contactColor = isYellow ? float3(1.0, 1.0, 0.0) : float3(0.24, 1.0, 1.0);
    float3 tint;
    float3 base = float3(color.rgb) / max(float(color.a), 0.00001);
    if (!hasSharedLiquid) {
        // Preserve other presets' original RGB compositing.
        tint = mix(source, contactColor, contact.coverage);
        float3 target = tint + base * (1.0 - base) *
            mix(tint, float3(1.0), 0.55) * 0.55;
        return half4(half3(clamp(mix(base, target, contact.idle), 0.0, 1.0) *
            float(color.a)), color.a);
    }
    // Composite the unchanged wave over the stationary MAIN with the accepted C1.
    float3 freePigment = isYellow ? float3(1.0, 0.61, 0.08) : float3(0.14, 0.48, 1.0);
    float3 mainColor = correctedLightPigment(contact.main, gradientColorIndex, transmission);
    float overlap = contact.intersection / max(contact.idle, 0.00001);
    float contactAmount = 1.0 - pow(1.0 - clamp(overlap, 0.0, 1.0), 3.0);
    float3 pigment = mix(freePigment, contactColor, contactAmount);
    // At collision, retain more MAIN contrast instead of covering the bent
    // boundary with an almost opaque ridge. Width/feather and free alpha stay
    // unchanged; the saturated contact pigment occupies only the intersection.
    float collisionTransparency = isYellow ? 0.20 : 0.35;
    float opacity = contact.idle * (1.0 - collisionTransparency * clamp(overlap, 0.0, 1.0));
    float3 afterContact = mix(mainColor, pigment, opacity);
    // Retain history while compositing the one unchanged wave field.
    return half4(half3(clamp(base + afterContact - mainColor, 0.0, 1.0) *
        float(color.a)), color.a);
}

float3 restoredYellowDarkTint(float3 source, float3 contactColor, float coverage) {
    return mix(source, contactColor, clamp(coverage, 0.0, 1.0));
}

half4 restoredYellowDarkContact(half4 color, half4 wave, float gradientColorIndex, float coverage) {
    if (wave.a == half(0.0)) { return color; }
    float alpha = float(wave.a);
    float3 base = float3(color.rgb);
    bool isYellow = abs(round(gradientColorIndex) - 3.0) < 0.5;
    float3 contactColor = isYellow ? float3(1.0, 0.90, 0.0) : float3(0.24, 1.0, 1.0);
    float3 light = restoredYellowDarkTint(float3(wave.rgb) / alpha,
        contactColor, coverage) * alpha;
    float3 overlap = clamp(base + light, 0.0, 1.0);
    if (isYellow) {
        // Preserve the successful Yellow contact and its saturated warm peak.
        overlap = min(overlap, contactColor * overlap.r);
    }
    return half4(half3(overlap), color.a);
}

half4 blendDarkIdle(half4 color, half4 wave, IdleContact contact, float gradientColorIndex) {
    if (wave.a == half(0.0)) { return color; }
    float3 base = float3(color.rgb);
    bool isYellow = abs(round(gradientColorIndex) - 3.0) < 0.5;
    if (isYellow) {
        // Map the SAME accepted Dark union M+W, including the reacted front,
        // with one palette. Dimming a fixed yellow wave into black made olive;
        // adding it over an already bright main palette made clipped bands.
        // Preserve the incoming grain/history by applying only the palette delta.
        float3 paletteDelta = yellowDarkDensityPalette(contact.reactedMain + contact.freeIdle)
            - yellowDarkDensityPalette(contact.main);
        return half4(half3(clamp(base + paletteDelta, 0.0, 1.0)), color.a);
    }
    float3 contactColor = isYellow ? yellowLightAccent : float3(0.24, 1.0, 1.0);
    // Map the reacted MAIN front and free idle separately. Their sum is
    // exactly the accepted Dark main + source*W + (contactColor-source)*C.
    float3 reactedMain = base + contactColor * contact.frontReaction;
    float3 light = idleContactLight(float3(wave.rgb) / contact.idle,
        contactColor, contact);
    float3 overlap = clamp(reactedMain + light, 0.0, 1.0);
    return half4(half3(overlap), color.a);
}

[[ stitchable ]]
float2 idleWaveDistortion(
    float2 position,
    float2 size,
    float activity,
    float time,
    float waveStrength
) {
    float2 safeSize = max(size, float2(1.0));
    float2 p = position / safeSize * float2(375.0, 812.0);
    float cycleRaw = fract(time / 3.0);
    float cycle = smootherLiquid(cycleRaw);
    float visibility =
        smoothstep(0.02, 0.11, cycleRaw) *
        (1.0 - smoothstep(0.88, 1.0, cycleRaw)) *
        smootherLiquid(clamp(activity, 0.0, 1.0));

    float waveY = mix(-110.0, 925.0, cycle);
    float width = mix(72.0, 420.0, cycle);
    float thickness = mix(24.0, 54.0, cycle);
    float dx = p.x - 187.5;
    float arcSlope = (2.0 * dx) / max(width * 1.72, 1.0);
    float arcY = waveY + (dx * dx) / max(width * 1.72, 1.0);
    float distanceToArc = p.y - arcY;

    float ridge =
        exp(-pow(distanceToArc / thickness, 2.0)) *
        exp(-pow(dx / (width * 1.10), 2.0));
    float softWake =
        exp(-pow((distanceToArc + 70.0) / (thickness * 1.75), 2.0)) *
        exp(-pow(dx / (width * 1.24), 2.0)) *
        0.38;
    float energy = clamp(ridge + softWake, 0.0, 1.0) * visibility;

    float strength = clamp(waveStrength, 0.0, 3.0);
    float displacement = energy * mix(3.0, 10.5, strength / 3.0) * strength;
    float2 normal = normalize(float2(-arcSlope, 1.0));
    float phase = sin(distanceToArc / max(thickness, 1.0) * 2.4 + time * 0.34);
    float2 referenceOffset = normal * displacement * (0.78 + phase * 0.22);
    float2 pixelScale = safeSize / float2(375.0, 812.0);
    float2 offset = clamp(referenceOffset * pixelScale, float2(-14.0), float2(14.0));

    return position + offset;
}

struct WaterSurfaceSample {
    float height;
    float2 slope;
};

float waterCausticThread(float2 uv, float2 slope, float height, float time, float speed) {
    float2 refracted = uv + slope * 0.14;
    float t = time * speed;

    float threadA = sin(refracted.x * 11.5 + refracted.y * 3.6 + height * 1.10 + t * 0.20);
    float threadB = sin(refracted.y * 10.8 - refracted.x * 3.2 - height * 0.95 - t * 0.18);
    float threadC = sin((refracted.x + refracted.y) * 8.4 + slope.x * 5.2 - t * 0.14);

    float mesh = (threadA * threadB + threadC * 0.38) * 0.32 + 0.50;
    float brightLines = smoothstep(0.70, 0.955, mesh);
    float softNet = smoothstep(0.42, 0.88, mesh) * 0.22;

    return brightLines + softNet;
}

WaterSurfaceSample waterSurfaceField(float2 uv, float time, float scale, float speed) {
    float2 p = uv * scale;
    float t = time * speed;

    float height = 0.0;
    float2 slope = float2(0.0);

    float2 d0 = normalize(float2(0.92, 0.38));
    float f0 = 1.42;
    float a0 = 0.62;
    float phase0 = dot(p, d0) * f0 + t * 0.26;
    height += sin(phase0) * a0;
    slope += d0 * (cos(phase0) * a0 * f0);

    float2 d1 = normalize(float2(-0.42, 0.91));
    float f1 = 2.18;
    float a1 = 0.34;
    float phase1 = dot(p, d1) * f1 - t * 0.22 + 1.7;
    height += sin(phase1) * a1;
    slope += d1 * (cos(phase1) * a1 * f1);

    float2 d2 = normalize(float2(0.35, 0.94));
    float f2 = 3.35;
    float a2 = 0.18;
    float phase2 = dot(p, d2) * f2 + t * 0.18 + 3.1;
    height += sin(phase2) * a2;
    slope += d2 * (cos(phase2) * a2 * f2);

    float2 d3 = normalize(float2(-0.84, -0.54));
    float f3 = 4.80;
    float a3 = 0.075;
    float phase3 = dot(p, d3) * f3 - t * 0.30 + sin(phase0) * 0.22;
    height += sin(phase3) * a3;
    slope += d3 * (cos(phase3) * a3 * f3);

    WaterSurfaceSample sample;
    sample.height = height;
    sample.slope = slope * 0.018;

    return sample;
}

[[ stitchable ]]
half4 waterCausticOverlay(
    float2 position,
    half4 color,
    float2 size,
    float2 tapPoint,
    float2 previousTouchPoint,
    float tapPulse,
    float time,
    float dragWave,
    float waterIntensity,
    float waterScale,
    float waterSpeed
) {
    waterIntensity = clamp(waterIntensity, 0.0, 10.0);
    waterScale = clamp(waterScale, 0.0, 10.0);
    waterSpeed = clamp(waterSpeed, 0.0, 10.0);
    tapPulse = smootherLiquid(clamp(tapPulse, 0.0, 1.0));
    dragWave = clamp(dragWave, 0.0, 1.0);

    float2 safeSize = float2(max(size.x, 1.0), max(size.y, 1.0));
    float2 uv = position / safeSize;
    float aspect = safeSize.x / safeSize.y;
    float2 waterUv = float2((uv.x - 0.5) * aspect + 0.5, uv.y);
    float2 touchUv = float2((tapPoint.x - 0.5) * aspect + 0.5, tapPoint.y);
    float2 previousUv = float2((previousTouchPoint.x - 0.5) * aspect + 0.5, previousTouchPoint.y);

    float2 path = touchUv - previousUv;
    float pathLength = length(path);
    float2 pathDir = path / max(pathLength, 0.0001);
    float2 pathNormal = float2(-pathDir.y, pathDir.x);
    float pathProjection = clamp(dot(waterUv - previousUv, path) / max(dot(path, path), 0.0001), 0.0, 1.0);
    float2 pathPoint = previousUv + path * pathProjection;

    float movement = smootherLiquid(smoothstep(0.004, 0.060, pathLength));
    float interaction = tapPulse * movement * (0.30 + 0.48 * dragWave);
    float2 fromFinger = waterUv - touchUv;
    float longitudinal = dot(fromFinger, pathDir);
    float lateral = dot(fromFinger, pathNormal);
    float behind = max(-longitudinal, 0.0);
    float touchDistance = length(fromFinger);
    float trailDistance = length(waterUv - pathPoint);
    float fingerField = exp(-pow(touchDistance / 0.28, 2.0));
    float trailFalloff = exp(-pow(trailDistance / 0.205, 2.0)) * movement;
    float wakeEnvelope =
        exp(-abs(lateral) * 4.8) *
        smoothstep(0.012, 0.090, behind) *
        exp(-behind * 1.10);
    float vWakeCoord = abs(lateral) - behind * 0.42;
    float vWakeMask =
        exp(-pow(vWakeCoord / 0.060, 2.0)) *
        smoothstep(0.018, 0.105, behind) *
        exp(-behind * 0.92);

    float scaleProgress = smootherLiquid(waterScale / 10.0);
    float scale = mix(1.75, 3.65, scaleProgress);
    WaterSurfaceSample surface = waterSurfaceField(waterUv, time, scale, waterSpeed);

    float wakePhase = behind * mix(12.0, 22.0, scaleProgress) + abs(lateral) * 4.8 - time * waterSpeed * 0.95;
    float wakeRipple = (0.5 + 0.5 * sin(wakePhase)) * wakeEnvelope * interaction;

    float vWakePhase = behind * mix(15.0, 28.0, scaleProgress) - time * waterSpeed * 1.15 + abs(lateral) * 2.8;
    float vWakeRipple = (0.5 + 0.5 * sin(vWakePhase)) * vWakeMask * interaction;

    float trailPhase = trailDistance * mix(14.0, 28.0, scaleProgress) - time * waterSpeed * 1.05 + pathProjection * 2.2;
    float trailRipple = (0.5 + 0.5 * sin(trailPhase)) * trailFalloff * interaction;
    float bowPressure =
        exp(-pow((longitudinal + 0.026) / 0.085, 2.0)) *
        exp(-pow(lateral / 0.19, 2.0)) *
        interaction;

    float localInfluence = clamp(
        fingerField * 0.22 +
        wakeEnvelope * 0.85 +
        vWakeMask * 0.90 +
        trailFalloff * 1.10 +
        bowPressure * 0.75,
        0.0,
        1.0
    );

    surface.slope +=
        pathDir * (wakeRipple * 0.006 + trailRipple * 0.005 + bowPressure * 0.008) +
        pathNormal * (vWakeRipple * sign(lateral) * 0.007);
    surface.height += (wakeRipple + vWakeRipple + trailRipple + bowPressure) * 0.052;

    float baseCaustic = waterCausticThread(waterUv + surface.slope * (0.70 + localInfluence * 0.60), surface.slope, surface.height, time, waterSpeed);
    float normalWave = dot(surface.slope, normalize(float2(-0.44, -0.66)));
    float idleCaustic = smoothstep(0.50, 0.945, baseCaustic);
    float causticVeins = pow(clamp(idleCaustic, 0.0, 1.0), 1.55);
    float idleSilk =
        smoothstep(0.30, 0.88, 0.5 + 0.5 * sin(surface.height * 1.35 + normalWave * 2.0 + time * waterSpeed * 0.12));

    float2 swellUv = waterUv + surface.slope * 0.55;
    float broadSwell =
        0.5 + 0.5 * sin(
            swellUv.x * 2.7 +
            swellUv.y * 3.4 +
            sin(swellUv.y * 1.8 + time * waterSpeed * 0.18) * 0.55 +
            time * waterSpeed * 0.16
        );
    broadSwell = smoothstep(0.18, 0.92, broadSwell);

    float aiFlowA =
        0.5 + 0.5 * sin(
            swellUv.x * 3.2 -
            swellUv.y * 2.3 +
            surface.height * 0.72 +
            time * waterSpeed * 0.22
        );
    float aiFlowB =
        0.5 + 0.5 * sin(
            swellUv.x * -2.1 +
            swellUv.y * 3.7 +
            normalWave * 1.85 -
            time * waterSpeed * 0.18
        );
    float aiRibbon =
        smoothstep(0.42, 0.94, aiFlowA) *
        smoothstep(0.20, 0.86, aiFlowB);
    float aiRibbonSoft =
        smoothstep(0.18, 0.92, 0.5 + 0.5 * sin(aiFlowA * 3.14159 + aiFlowB * 2.4));

    float3 normal = normalize(float3(-surface.slope.x * 10.5, -surface.slope.y * 10.5, 1.0));
    float3 lightDir = normalize(float3(-0.38, -0.62, 0.78));
    float3 viewDir = float3(0.0, 0.0, 1.0);
    float fresnel = pow(clamp(1.0 - normal.z, 0.0, 1.0) * 2.8, 1.65);
    float specular = pow(max(dot(reflect(-lightDir, normal), viewDir), 0.0), 34.0);

    float idleSurface =
        broadSwell * 0.030 +
        aiRibbon * 0.030 +
        aiRibbonSoft * 0.018 +
        causticVeins * 0.018 +
        idleSilk * 0.024 +
        fresnel * 0.035 +
        specular * 0.060;
    float interactionSurface =
        causticVeins * localInfluence * interaction * 0.055 +
        (wakeRipple + vWakeRipple + trailRipple) * 0.085 +
        bowPressure * 0.045 +
        localInfluence * interaction * aiRibbonSoft * 0.080;

    float edgeFade =
        smoothstep(0.00, 0.04, uv.x) *
        (1.0 - smoothstep(0.96, 1.00, uv.x)) *
        smoothstep(0.00, 0.05, uv.y) *
        (1.0 - smoothstep(0.94, 1.00, uv.y));

    float waterLines = idleSurface + interactionSurface;

    float alpha = clamp(waterLines * waterIntensity, 0.018, 0.168) * edgeFade;

    float3 aiBlue = float3(0.23, 0.55, 1.0);
    float3 aiCyan = float3(0.32, 0.98, 1.0);
    float3 aiViolet = float3(0.66, 0.42, 1.0);
    float3 aiMagenta = float3(1.0, 0.42, 0.78);
    float3 aiWarm = float3(1.0, 0.68, 0.36);

    float3 intelligenceColor =
        mix(aiBlue, aiCyan, smoothstep(0.15, 0.85, aiFlowA));
    intelligenceColor =
        mix(intelligenceColor, aiViolet, smoothstep(0.34, 0.92, aiFlowB) * 0.72);
    intelligenceColor =
        mix(intelligenceColor, aiMagenta, smoothstep(0.60, 0.98, aiFlowA * aiFlowB) * 0.45);
    intelligenceColor =
        mix(intelligenceColor, aiWarm, smoothstep(0.72, 1.0, broadSwell) * 0.16);

    float3 waterColor =
        intelligenceColor * (broadSwell * 0.035 + aiRibbon * 0.075 + aiRibbonSoft * 0.040) +
        float3(0.34, 0.82, 1.0) * (idleSilk * 0.014 + fresnel * 0.050) +
        float3(0.58, 0.96, 1.0) * (causticVeins * 0.026 + interactionSurface * 0.24) +
        float3(0.96, 0.98, 1.0) * (specular * 0.10 + bowPressure * 0.026);

    return half4(
        half3(clamp(waterColor, 0.0, 1.0)),
        half(alpha)
    );
}

[[ stitchable ]]
float2 gradientTrailDistortion(
    float2 position,
    float2 size,
    float2 tapPoint,
    float2 previousTouchPoint,
    float strength,
    float time
) {
    strength = clamp(strength, 0.0, 1.0);

    float2 safeSize = float2(max(size.x, 1.0), max(size.y, 1.0));
    float2 uv = position / safeSize;
    float aspect = safeSize.x / safeSize.y;
    float2 trailUv = float2((uv.x - 0.5) * aspect + 0.5, uv.y);
    float2 touchUv = float2((tapPoint.x - 0.5) * aspect + 0.5, tapPoint.y);
    float2 previousUv = float2((previousTouchPoint.x - 0.5) * aspect + 0.5, previousTouchPoint.y);

    float2 path = touchUv - previousUv;
    float pathLength = length(path);
    float2 direction = path / max(pathLength, 0.0001);
    float projection = clamp(dot(trailUv - previousUv, path) / max(dot(path, path), 0.000001), 0.0, 1.0);
    float2 delta = (trailUv - mix(previousUv, touchUv, projection)) / float2(0.065, 0.075);
    float envelope = exp(-dot(delta, delta));
    // The old projection gates compressed an up-to-7.5 pt displacement into
    // a few pixels, folding the gradient into moving slices. No phase ripple,
    // no clipped offset: a bounded Gaussian deformation remains smooth.
    float movement = pathLength / (pathLength + 0.025);
    float2 offset = direction * (1.5 * strength * movement * envelope);

    return position + offset;
}

[[ stitchable ]]
float2 waterSurfaceDistortion(
    float2 position,
    float2 size,
    float2 tapPoint,
    float2 previousTouchPoint,
    float tapPulse,
    float time,
    float dragWave,
    float waterIntensity,
    float waterScale,
    float waterSpeed
) {
    waterIntensity = clamp(waterIntensity, 0.0, 10.0);
    waterScale = clamp(waterScale, 0.0, 10.0);
    waterSpeed = clamp(waterSpeed, 0.0, 10.0);
    tapPulse = smootherLiquid(clamp(tapPulse, 0.0, 1.0));
    dragWave = clamp(dragWave, 0.0, 1.0);

    float2 safeSize = float2(max(size.x, 1.0), max(size.y, 1.0));
    float2 uv = position / safeSize;
    float aspect = safeSize.x / safeSize.y;
    float2 waterUv = float2((uv.x - 0.5) * aspect + 0.5, uv.y);
    float2 touchUv = float2((tapPoint.x - 0.5) * aspect + 0.5, tapPoint.y);
    float2 previousUv = float2((previousTouchPoint.x - 0.5) * aspect + 0.5, previousTouchPoint.y);
    float2 path = touchUv - previousUv;
    float pathLength = length(path);
    float2 pathDir = path / max(pathLength, 0.0001);
    float2 pathNormal = float2(-pathDir.y, pathDir.x);
    float pathProjection = clamp(dot(waterUv - previousUv, path) / max(dot(path, path), 0.0001), 0.0, 1.0);
    float2 pathPoint = previousUv + path * pathProjection;

    float2 fromFinger = waterUv - touchUv;
    float longitudinal = dot(fromFinger, pathDir);
    float lateral = dot(fromFinger, pathNormal);
    float behind = max(-longitudinal, 0.0);
    float touchDistance = length(fromFinger);
    float trailDistance = length(waterUv - pathPoint);
    float movement = smootherLiquid(smoothstep(0.004, 0.060, pathLength));
    float touchField = exp(-pow(touchDistance / 0.250, 2.0));
    float trailField = exp(-pow(trailDistance / 0.190, 2.0)) * movement;
    float wakeEnvelope =
        exp(-abs(lateral) * 4.6) *
        smoothstep(0.012, 0.090, behind) *
        exp(-behind * 1.05);
    float vWakeCoord = abs(lateral) - behind * 0.42;
    float vWakeField =
        exp(-pow(vWakeCoord / 0.065, 2.0)) *
        smoothstep(0.018, 0.105, behind) *
        exp(-behind * 0.88);
    float interaction = tapPulse * movement * (0.30 + 0.48 * dragWave);

    float scaleProgress = smootherLiquid(waterScale / 10.0);
    float scale = mix(2.20, 5.15, scaleProgress);
    WaterSurfaceSample surface = waterSurfaceField(waterUv, time, scale, waterSpeed);
    float wakePhase = behind * mix(28.0, 48.0, scaleProgress) + abs(lateral) * 10.0 - time * waterSpeed * 2.15;
    float wakeSlope = cos(wakePhase) * wakeEnvelope;
    float vWakePhase = behind * mix(34.0, 58.0, scaleProgress) - time * waterSpeed * 2.65 + abs(lateral) * 4.8;
    float vWakeSlope = cos(vWakePhase) * vWakeField;
    float bowPush =
        exp(-pow((longitudinal + 0.022) / 0.075, 2.0)) *
        exp(-pow(lateral / 0.17, 2.0));
    float localInfluence = clamp(touchField * 0.28 + wakeEnvelope + vWakeField + trailField * 1.35, 0.0, 1.0);

    surface.slope +=
        surface.slope * localInfluence * 0.32 +
        pathDir * (wakeSlope * 0.016 + bowPush * 0.010) * interaction +
        pathNormal * (vWakeSlope * sign(lateral) * 0.014) * interaction +
        pathDir * trailField * interaction * 0.012;

    float edgeFade =
        smoothstep(0.000, 0.045, uv.x) *
        (1.0 - smoothstep(0.955, 1.000, uv.x)) *
        smoothstep(0.000, 0.045, uv.y) *
        (1.0 - smoothstep(0.955, 1.000, uv.y));

    float active = clamp(interaction * localInfluence * waterIntensity, 0.0, 1.0);
    float2 offset = surface.slope * safeSize.y * active * (0.72 + 1.15 * dragWave);
    offset += pathDir * trailField * interaction * waterIntensity * 0.70;
    offset *= edgeFade;
    offset = clamp(offset, float2(-2.2), float2(2.2));

    return position + offset;
}

[[ stitchable ]]
float2 shockwaveScreenDistortion(
    float2 position,
    float2 size,
    float2 tapPoint,
    float pulse,
    float time
) {
    pulse = clamp(pulse, 0.0, 1.0);

    float2 safeSize = float2(max(size.x, 1.0), max(size.y, 1.0));
    float2 tapPx = tapPoint * safeSize;
    float2 delta = position - tapPx;
    float dist = length(delta);
    float2 dir = delta / max(dist, 0.001);

    float age = 1.0 - pulse;
    float maxRadius = max(safeSize.x, safeSize.y) * 0.58;
    float radius = mix(8.0, maxRadius, smootherLiquid(age));
    float width = mix(48.0, 78.0, smootherLiquid(age));
    float ringCoord = (dist - radius) / max(width, 1.0);
    float ring = exp(-ringCoord * ringCoord);
    float wake = exp(-pow((dist - radius + width * 0.70) / max(width * 1.55, 1.0), 2.0));
    float fade = pulse * pulse * (1.0 - smoothstep(0.86, 1.0, age));

    float signedBend = ringCoord * ring - wake * 0.22;
    float amplitude = mix(7.0, 2.0, smootherLiquid(age)) * fade;
    float edgeFade =
        smoothstep(0.000, 0.040, position.x / safeSize.x) *
        (1.0 - smoothstep(0.960, 1.000, position.x / safeSize.x)) *
        smoothstep(0.000, 0.040, position.y / safeSize.y) *
        (1.0 - smoothstep(0.960, 1.000, position.y / safeSize.y));
    float2 offset = dir * signedBend * amplitude * edgeFade;

    return position + offset;
}

[[ stitchable ]]
half4 shockwaveRippleOverlay(
    float2 position,
    half4 color,
    float2 size,
    float2 tapPoint,
    float pulse,
    float time
) {
    pulse = clamp(pulse, 0.0, 1.0);

    float2 safeSize = float2(max(size.x, 1.0), max(size.y, 1.0));
    float aspect = safeSize.x / safeSize.y;
    float2 uv = position / safeSize;
    float2 origin = tapPoint;
    float2 aspectDelta = uv - origin;
    aspectDelta.x *= aspect;
    float dist = length(aspectDelta);
    float age = 1.0 - pulse;
    float progress = smootherLiquid(age);
    float radius = 0.66;
    float speed = 1.38;
    float damping = 0.86;
    float waveCount = 2.0;
    float waveSoftness = 1.0;
    float waveSpacing = 0.35;
    float fadeSpeed = 1.08;
    float leadingRadius = progress * radius * speed;
    float life = exp(-age * fadeSpeed * 0.9) * (1.0 - smoothstep(0.82, 1.0, progress));
    float spatialFade = exp(-dist * damping * 0.85);
    float width = mix(0.012, 0.08, clamp(waveSoftness, 0.0, 1.0)) * radius;
    float rippleAmount = 0.0;
    float edgeGlow = 0.0;

    for (int waveIndex = 0; waveIndex < 2; waveIndex++) {
        float spacing = radius * waveSpacing / max(waveCount, 1.0);
        float ringRadius = leadingRadius - float(waveIndex) * spacing;
        if (ringRadius <= 0.0) {
            continue;
        }

        float ringDistance = abs(dist - ringRadius);
        float ring = exp(-pow(ringDistance / max(width, 0.001), 2.0));
        float rimWidth = max(width * 0.42, 0.001);
        float rim = exp(-pow(ringDistance / rimWidth, 2.0));
        float fadeBack = mix(1.0, 0.52, float(waveIndex) / max(waveCount - 1.0, 1.0));
        rippleAmount += ring * fadeBack;
        edgeGlow += rim * fadeBack * life * spatialFade;
    }

    rippleAmount = clamp(rippleAmount, 0.0, 1.0) * life * spatialFade;
    float shimmer = clamp(rippleAmount * 2.1, 0.0, 1.0);
    float glow = pow(clamp(edgeGlow, 0.0, 1.0), 1.8) * 0.50 * 0.035;
    float softLens = exp(-pow(dist / max(leadingRadius * 0.78 + 0.020, 0.001), 2.0)) *
        (1.0 - smoothstep(0.18, 0.86, age)) *
        0.045;
    float alpha = clamp(shimmer * 0.034 + glow * 0.36 + softLens, 0.0, 0.075);

    float3 rippleColor =
        float3(0.84, 1.0, 1.0) * (shimmer * 0.08 + glow * 0.72) +
        float3(1.0, 0.86, 0.64) * glow +
        float3(0.18, 0.70, 1.0) * softLens;

    return half4(
        half3(clamp(rippleColor, 0.0, 1.0)),
        half(alpha)
    );
}


// QA-only source restoration from theme-isolation-pass/after.metal.
half4 qaHistoricalYellowDarkWave(float density) {
    float3 warmWave = mix(yellowMidColor.rgb, yellowLightAccent, 0.20);
    float3 source = balanceYellowDarkLight(warmWave, float3(0.14, 0.48, 1.0));
    return half4(half3(source * density), half(density));
}

half4 qaHistoricalYellowDarkContact(half4 color, half4 wave, float gradientColorIndex, float coverage) {
    if (wave.a == half(0.0)) { return color; }
    float alpha = float(wave.a);
    float3 base = float3(color.rgb);
    bool isYellow = abs(round(gradientColorIndex) - 3.0) < 0.5;
    float3 contactColor = isYellow ? yellowLightAccent : float3(0.24, 1.0, 1.0);
    float3 light = restoredYellowDarkTint(float3(wave.rgb) / alpha,
        contactColor, coverage) * alpha;
    float3 overlap = clamp(base + light, 0.0, 1.0);
    if (isYellow) {
        // Preserve the successful Yellow contact and its saturated warm peak.
        overlap = min(overlap, yellowLightAccent * overlap.r);
    }
    return half4(half3(overlap), color.a);
}

half4 qaContactDarkReference(
    float2 position,
    half4 color,
    float2 size,
    float progress,
    float tapPulse,
    float2 tapPoint,
    float2 previousTouchPoint,
    float swipePulse,
    float swipeStrength,
    float time,
    float progressSpeed,
    float fillGain,
    float waveStrength,
    float waveSpread,
    float topBloom,
    float whiteCore,
    float blueDepth,
    float dragWave,
    float shockStrength,
    float shockInteraction,
    float shockTrail,
    float waveCount,
    float themeStrength,
    float gradientColorIndex,
    float idleActivity,
    float idleTime,
    device const float *interactionSegments,
    int interactionFloatCount
) {
    progress = clamp(progress, 0.0, 1.0);
    progressSpeed = clamp(progressSpeed, 0.0, 10.0);
    fillGain = clamp(fillGain, 0.0, 10.0);
    waveStrength = clamp(waveStrength, 0.0, 10.0);
    waveSpread = clamp(waveSpread, 0.0, 10.0);
    topBloom = clamp(topBloom, 0.0, 10.0);
    whiteCore = clamp(whiteCore, 0.0, 10.0);
    blueDepth = clamp(blueDepth, 0.0, 10.0);
    dragWave = clamp(dragWave, 0.0, 1.0);
    swipePulse = smootherLiquid(clamp(swipePulse, 0.0, 1.0));
    swipeStrength = clamp(swipeStrength, 0.0, 1.0);
    shockStrength = clamp(shockStrength, 0.0, 10.0);
    shockInteraction = clamp(shockInteraction, 0.0, 10.0);
    shockTrail = clamp(shockTrail, 0.0, 10.0);
    waveCount = clamp(round(waveCount), 0.0, 10.0);
    themeStrength = clamp(themeStrength, 0.0, 1.0);
    gradientColorIndex = clamp(round(gradientColorIndex), 0.0, 4.0);
    float isBluePreset = 1.0 - step(0.5, abs(gradientColorIndex));
    float isYellowPreset = 1.0 - step(0.5, abs(gradientColorIndex - 3.0));

    float2 design = float2(375.0, 812.0);
    float2 safeSize = float2(max(size.x, 1.0), max(size.y, 1.0));

    float2 p = float2(
        position.x / safeSize.x * design.x,
        position.y / safeSize.y * design.y
    );

    float2 uv = position / safeSize;

    float3 white = float3(1.0);

    // Blue gradient shares the light idle-wave palette: #1A8CFF.
    float3 cyan = float3(0.10, 0.55, 1.0);
    float3 aqua = float3(0.10, 0.55, 1.0);
    float3 blue = float3(0.10, 0.55, 1.0);
    float3 deepBlue = float3(0.10, 0.55, 1.0);
    float3 electric = float3(0.10, 0.55, 1.0);
    float3 targetBlue = float3(0.10, 0.55, 1.0);

    if (gradientColorIndex < 2.5 && gradientColorIndex > 1.5) {
        cyan = float3(0.62, 0.46, 1.0);
        aqua = float3(0.43, 0.28, 0.94);
        blue = float3(0.22, 0.12, 0.72);
        deepBlue = float3(0.09, 0.05, 0.34);
        electric = float3(0.82, 0.58, 1.0);
        targetBlue = float3(0.56, 0.42, 1.0);
    } else if (gradientColorIndex < 3.5 && gradientColorIndex > 2.5) {
        cyan = mix(yellowHotColor.rgb, white, 0.32);
        aqua = yellowHotColor.rgb;
        blue = yellowMidColor.rgb;
        deepBlue = yellowDeepColor.rgb;
        electric = yellowHotColor.rgb;
        targetBlue = yellowMidColor.rgb;
    } else if (gradientColorIndex > 3.5) {
        cyan = float3(1.0, 0.46, 0.68);
        aqua = float3(0.94, 0.26, 0.58);
        blue = float3(0.60, 0.14, 0.52);
        deepBlue = float3(0.26, 0.05, 0.20);
        electric = float3(1.0, 0.68, 0.88);
        targetBlue = float3(1.0, 0.42, 0.66);
    }

    float3 waveMid = mix(targetBlue, aqua, 0.24);
    float3 waveDeep = mix(deepBlue, targetBlue, 0.18);
    float3 waveGlass = mix(cyan, white, 0.68);
    float3 waveEdge = mix(electric, cyan, 0.36);

    // --------------------------------------------------
    // Idle shockwave
    // --------------------------------------------------

    float idleWaveActivity = smootherLiquid(swipeStrength);
    float idleWaveFade = mix(0.92, 0.78, smoothstep(0.92, 1.0, progress)) * idleWaveActivity;

    float idlePeriod = 3.0;
    float idleCycleRaw = fract(time / idlePeriod);
    float idleCycle = smootherLiquid(idleCycleRaw);

    float idleWaveVisibility =
        smoothstep(0.02, 0.11, idleCycleRaw) *
        (1.0 - smoothstep(0.88, 1.0, idleCycleRaw)) *
        idleWaveFade;

    float idleWaveY = mix(-110.0, 925.0, idleCycle);

    float idleWidth = mix(72.0, 420.0, idleCycle);
    float idleThickness = mix(19.0, 42.0, idleCycle);

    float idleDx = p.x - 187.5;

    float idleArcY =
        idleWaveY +
        (idleDx * idleDx) / max(idleWidth * 1.72, 1.0);

    float idleWaveDist = p.y - idleArcY;

    float idleMainWave =
        exp(-pow(idleWaveDist / idleThickness, 2.0)) *
        exp(-pow(idleDx / idleWidth, 2.0));

    float idleSecondWave =
        exp(-pow((idleWaveDist + 72.0) / (idleThickness * 1.35), 2.0)) *
        exp(-pow(idleDx / (idleWidth * 1.18), 2.0)) *
        0.42;

    float idleThirdWave =
        exp(-pow((idleWaveDist + 132.0) / (idleThickness * 1.75), 2.0)) *
        exp(-pow(idleDx / (idleWidth * 1.32), 2.0)) *
        0.20;

    float idleConeGlow =
        exp(-pow((p.y - idleWaveY) / 180.0, 2.0)) *
        exp(-pow(idleDx / max(idleWidth * 1.18, 1.0), 2.0)) *
        0.18;

    float idleWaveEnergy =
        clamp(
            idleMainWave +
            idleSecondWave +
            idleThirdWave +
            idleConeGlow,
            0.0,
            1.0
        ) *
        idleWaveVisibility *
        waveStrength;

    // --------------------------------------------------
    // Continuous upward motion
    // --------------------------------------------------

    // Use the original gradient motion curve for every palette and theme.
    float baseRise = progress * (0.42 + 0.58 * progress);
    float smoothRise = smootherLiquid(progress);
    float rise = mix(baseRise, smoothRise, 0.34);
    float finalLiftBoost = segmentEase(progress, 0.74, 1.00);
    float lateLiftBoost = segmentEase(progress, 0.88, 1.00);

    float circleGrowth = smootherLiquid(progress);

    float2 center = float2(187.5, 406.0);
    float circleAppear = smoothstep(0.025, 0.12, progress * (0.70 + progressSpeed * 3.0));
    float circleRadius = mix(74.0, 178.0, circleGrowth) * mix(0.92, 1.08, waveSpread - 0.5);

    float bottomCleanProgress = segmentEase(progress, 0.42, 1.00);
    float topCapProgress = segmentEase(progress, 0.82, 1.00);
    float topReservoirProgress = segmentEase(progress, 0.58, 1.00);

    float completionBloom = segmentEase(progress, 0.96, 1.00);
    float completed = smoothstep(0.995, 1.0, progress);

    float globalLift =
        mix(0.0, 1380.0, rise) +
        260.0 * finalLiftBoost +
        540.0 * lateLiftBoost;

    float initialDrop = 350.0 * (1.0 - rise);

    float finalBlur = segmentEase(progress, 0.70, 1.00);
    float completionMistProgress = segmentEase(progress, 0.84, 1.00);

    float completionFlash = 0.0;

    // Позже начинаем растворять градиент.
    float lateTransparency = segmentEase(progress, 0.90, 1.00);

    float mainFinalFade = mix(1.0, 0.62, lateTransparency);
    float rimFinalFade = mix(1.0, 0.44, lateTransparency);
    float finalFade = mainFinalFade;

    // Делаем градиент более вытянутым в первой половине
    // и чуть компактнее к финалу, но мягче, чем раньше.
    float shrinkAfterHalf = segmentEase(progress, 0.64, 1.00);

    float stretchFactor = mix(
        0.30,
        0.64,
        shrinkAfterHalf
    );

    float2 pStretched = float2(
        p.x,
        406.0 + (p.y - 406.0) * stretchFactor
    );

    // --------------------------------------------------
    // Bottom clearing mask
    // --------------------------------------------------

    float clearEdgeY = mix(1060.0, 225.0, bottomCleanProgress);
    float clearFeather = mix(205.0, 360.0, bottomCleanProgress);

    float clearWave =
        24.0 * sin(p.x * 0.018 + time * 0.50 + rise * 2.0) +
        15.0 * sin(p.x * 0.041 - time * 0.36 + rise * 4.0) +
        8.0  * sin((p.x + p.y) * 0.020 + time * 0.22);

    float bottomClear = smoothstep(
        clearEdgeY - clearFeather,
        clearEdgeY + clearFeather,
        p.y + clearWave
    );

    float bottomOnly = smoothstep(0.38, 1.0, uv.y);
    bottomClear *= bottomOnly;

    // --------------------------------------------------
    // Organic liquid reveal edge
    // --------------------------------------------------

    float revealEdgeY = mix(910.0, -1450.0, rise);

    // Граница сверху и снизу мягче.
    float revealFeather = mix(
        140.0,
        360.0 + 340.0 * finalBlur,
        rise
    );

    float revealWaveA =
        34.0 * sin(p.x * 0.013 + time * 0.42 + rise * 2.1);

    float revealWaveB =
        18.0 * sin(p.x * 0.031 - time * 0.56 + rise * 3.4);

    float revealWaveC =
        9.0 * sin(p.x * 0.071 + time * 0.33 - rise * 1.6);

    float domainWarp =
        13.0 * sin((p.x + p.y) * 0.018 + time * 0.28) +
        7.0  * sin((p.x - p.y) * 0.026 - time * 0.31);

    float blob1 =
        42.0 *
        exp(-pow((p.x - 86.0) / 72.0, 2.0)) *
        sin(time * 0.37 + rise * 2.4);

    float blob2 =
        36.0 *
        exp(-pow((p.x - 206.0) / 88.0, 2.0)) *
        sin(time * 0.29 + 1.7 + rise * 2.9);

    float blob3 =
        30.0 *
        exp(-pow((p.x - 318.0) / 76.0, 2.0)) *
        sin(time * 0.34 + 3.1 + rise * 2.2);

    float revealWave =
        revealWaveA +
        revealWaveB +
        revealWaveC +
        domainWarp +
        blob1 +
        blob2 +
        blob3;

    float edgeChaos = mix(
        0.72,
        1.0,
        smoothstep(0.12, 0.65, progress)
    );

    float liquidEdgeY = revealEdgeY - revealWave * edgeChaos;

    float bottomReveal = smoothstep(
        liquidEdgeY - revealFeather,
        liquidEdgeY + revealFeather,
        p.y
    );

    float revealEdgeDist = abs(p.y - liquidEdgeY);

    float revealEdgeGlow =
        exp(-revealEdgeDist / 38.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.22 *
        finalFade;

    float tensionCore =
        exp(-revealEdgeDist / 15.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.18 *
        finalFade;

    float tensionShadow =
        exp(-abs((p.y - liquidEdgeY) - 26.0) / 28.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.10 *
        finalFade;

    float liquidRimLine =
        exp(-revealEdgeDist / 8.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        finalFade;

    // --------------------------------------------------
    // Idle / completion breathing
    // --------------------------------------------------

    float idleEnergy = 1.0 - smoothstep(0.02, 0.22, progress);

    float idleVertical =
        idleEnergy *
        (
            18.0 * sin(time * 0.46) +
            9.0  * sin(time * 0.83)
        );

    float horizontalDrift = 0.0;

    float baseShiftY = globalLift - initialDrop + idleVertical;

    float2 pGlobal = pStretched + float2(horizontalDrift, baseShiftY);

    // --------------------------------------------------
    // Refraction + tap push + flow pull
    // --------------------------------------------------

    float lensDist = distance(p, center);

    float refractionZone =
        exp(-pow((lensDist - circleRadius) / 42.0, 2.0)) *
        circleAppear;

    float2 refractDir = normalize(p - center + float2(0.001, 0.001));
    float2 refractionWarp = refractDir * refractionZone * 10.0;

    float2 tapPxDesign = float2(
        tapPoint.x * design.x,
        tapPoint.y * design.y
    );

    float2 touchDeltaDesign = p - tapPxDesign;
    float tapDistDesign = length(touchDeltaDesign);
    float shockActive = smoothstep(0.04, 1.0, dragWave) * waveStrength * shockStrength;
    float shockAge = clamp((1.0 - tapPulse) / max(shockTrail, 0.30), 0.0, 1.0);
    float shockSide = touchDeltaDesign.x >= 0.0 ? 1.0 : -1.0;
    float travelingPhase = time * (3.8 + 1.4 * shockInteraction);

    float rippleAmplitude = 38.0 * shockStrength;
    float rippleEnvelope = smoothstep(0.01, 0.46, dragWave);
    float waveProgress = clamp(1.0 - tapPulse, 0.0, 1.0);
    float safeWaveSpread = max(waveSpread, 0.001);
    float safeShockTrail = max(shockTrail, 0.001);
    float waveFrontRadius = 24.0 + waveProgress * 250.0 * shockTrail;
    float ringSpacing = 46.0 * waveSpread;
    float ringWidth = max(25.0 * waveSpread, 1.0);
    float finiteRipple = 0.0;

    // Fixed upper bound keeps this predictable on the GPU while allowing 0...10 waves.
    for (int waveIndex = 0; waveIndex < 10; waveIndex++) {
        float index = float(waveIndex);
        float ringRadius = waveFrontRadius - ringSpacing * index;
        float ringEnabled = step(index + 0.5, waveCount) * smoothstep(2.0, 16.0, ringRadius);
        float ring =
            exp(-pow((tapDistDesign - ringRadius) / ringWidth, 2.0)) -
            0.34 * exp(-pow((tapDistDesign - ringRadius + ringWidth * 0.72) / (ringWidth * 1.28), 2.0));
        finiteRipple += ring * ringEnabled * (1.0 - index * 0.075);
    }
    float rippleFade = exp(-waveProgress * 1.35 / max(shockTrail, 0.30));
    float rippleAmount =
        rippleAmplitude *
        finiteRipple *
        rippleEnvelope *
        rippleFade;
    float2 rippleDir = normalize(touchDeltaDesign + float2(0.001, 0.001));
    float2 shadertoyRippleWarp = rippleAmount * rippleDir;
    float shadertoyRippleLight = rippleAmount / max(rippleAmplitude, 1.0);

    // A continuous, soft water response that remains visible while the finger moves.
    float localWaterPressure =
        exp(-pow(tapDistDesign / max(92.0 * waveSpread, 1.0), 2.0)) *
        rippleEnvelope;
    float localWaterWave =
        finiteRipple *
        rippleEnvelope *
        rippleFade;
    float2 localWaterWarp =
        rippleDir *
        (
            localWaterWave * (5.2 + 2.0 * shockStrength) +
            localWaterPressure * 2.8
        );

    float frontNoise =
        12.0 * sin(p.y * 0.018 + time * 2.1) +
        7.0 * sin(p.y * 0.034 - time * 1.4);

    float frontDist = abs(p.x - tapPxDesign.x + frontNoise);
    float primaryFront =
        exp(-pow(frontDist / max(mix(46.0, 82.0, waveSpread), 1.0), 2.0)) *
        shockActive;

    float secondaryFront =
        exp(-pow((frontDist - mix(42.0, 128.0 * shockTrail, shockAge)) / max(mix(104.0, 162.0, waveSpread), 1.0), 2.0)) *
        shockActive *
        (0.72 - 0.26 * shockAge);

    float screenRing =
        exp(-pow((tapDistDesign - mix(42.0, 310.0 * shockTrail, shockAge)) / max(172.0 * safeWaveSpread, 1.0), 2.0)) *
        shockActive *
        (0.38 + 0.62 * tapPulse);

    float diagonalAxis =
        dot(touchDeltaDesign, normalize(float2(0.58 * shockSide, 0.82))) +
        18.0 * sin(p.y * 0.020 + time * 1.9);

    float diagonalWake =
        exp(-pow(diagonalAxis / max(150.0 * safeWaveSpread, 1.0), 2.0)) *
        exp(-pow(touchDeltaDesign.x / max(420.0 * safeShockTrail, 1.0), 2.0)) *
        shockActive *
        (0.46 + 0.36 * tapPulse);

    float causticPulse =
        (0.5 + 0.5 * sin(tapDistDesign * 0.050 - travelingPhase * 1.7 + shockAge * 8.2)) *
        screenRing *
        shockActive *
        (0.64 + 0.36 * shockInteraction);

    float crossingFront =
        primaryFront * secondaryFront +
        screenRing * diagonalWake;

    float interferenceField =
        (0.5 + 0.5 * sin(tapDistDesign * 0.042 - travelingPhase * 1.35)) *
        (0.5 + 0.5 * sin((touchDeltaDesign.x * shockSide + touchDeltaDesign.y * 0.54) * 0.034 + travelingPhase)) *
        shockActive *
        shockInteraction;

    float selfCoupling =
        clamp(crossingFront * (0.72 + 0.46 * shockInteraction) + interferenceField * 0.44, 0.0, 1.8);

    float compositeShock =
        primaryFront * 0.54 +
        secondaryFront * 0.38 +
        screenRing * 0.34 +
        diagonalWake * 0.28 +
        causticPulse * 0.16 +
        selfCoupling * 0.30;

    float touchPush =
        exp(-pow(tapDistDesign * 0.0052, 2.0)) *
        tapPulse *
        shockActive;

    float2 tapDir = normalize(p - tapPxDesign + float2(0.001, 0.001));
    float2 frontDir = normalize(float2(shockSide, 0.16 * sin(p.y * 0.021 + time * 1.7)));
    float2 diagonalDir = normalize(float2(0.46 * shockSide, 0.72));
    float2 tapWarp =
        shadertoyRippleWarp * (0.58 + 0.16 * waveStrength) +
        localWaterWarp +
        tapDir * touchPush * 6.0 +
        frontDir * compositeShock * 7.0 +
        diagonalDir * (diagonalWake + selfCoupling * 0.38) * 3.5 +
        float2(0.0, -1.0) * (causticPulse + interferenceField * 0.24) * 2.0;

    float centerPull =
        exp(-pow((p.x - 187.5) / 140.0, 2.0));

    float verticalFlowPull =
        centerPull *
        segmentEase(progress, 0.18, 0.92) *
        34.0 *
        waveStrength;

    float2 flowWarp = refractionWarp + tapWarp;
    float2 liquidFlowWarp = float2(0.0, flowWarp.y);

    pGlobal += liquidFlowWarp * 0.82;
    pGlobal.y += verticalFlowPull;

    float backSpeed = mix(0.70, 0.78, completed);
    float mainSpeed = mix(1.00, 0.92, completed);
    float rimSpeed = mix(1.30, 1.10, completed);

    float2 pShape1Back = pStretched + float2(horizontalDrift * 0.30, baseShiftY * backSpeed * 0.82);
    float2 pShape2Back = pStretched + float2(horizontalDrift * 0.40, baseShiftY * backSpeed * 0.96);
    float2 pWave1Back  = pStretched + float2(horizontalDrift * 0.48, baseShiftY * backSpeed * 0.92);
    float2 pWave2Back  = pStretched + float2(horizontalDrift * 0.50, baseShiftY * backSpeed * 1.04);

    float2 pShape1 = pStretched + float2(horizontalDrift * 0.55, baseShiftY * mainSpeed * 0.95);
    float2 pShape2 = pStretched + float2(horizontalDrift * 0.80, baseShiftY * mainSpeed * 1.12);
    float2 pBgUp   = pStretched + float2(horizontalDrift * 0.30, baseShiftY * mainSpeed * 0.34);
    float2 pWave1  = pStretched + float2(horizontalDrift * 1.05, baseShiftY * mainSpeed * 1.00);
    float2 pWave2  = pStretched + float2(horizontalDrift * 0.95, baseShiftY * mainSpeed * 1.16);

    float2 pRim1 = pStretched + float2(horizontalDrift * 1.28, baseShiftY * rimSpeed * 1.22);
    float2 pRim2 = pStretched + float2(horizontalDrift * 1.10, baseShiftY * rimSpeed * 1.30);

    pShape1Back += liquidFlowWarp * 0.18;
    pShape2Back += liquidFlowWarp * 0.24;
    pWave1Back += liquidFlowWarp * 0.28;
    pWave2Back += liquidFlowWarp * 0.30;

    pShape1 += liquidFlowWarp * 0.50;
    pShape2 += liquidFlowWarp * 0.58;
    pWave1 += liquidFlowWarp * 0.72;
    pWave2 += liquidFlowWarp * 0.68;

    pRim1 += liquidFlowWarp * 0.95;
    pRim2 += liquidFlowWarp * 0.88;

    float2 deepWarp = float2(
        0.0,
        cos(p.x * 0.010 + time * 0.32) * 8.0
    );

    pShape1Back += deepWarp * 0.22;
    pShape2Back += deepWarp * 0.28;
    pWave1Back += deepWarp * 0.34;
    pWave2Back += deepWarp * 0.36;

    pShape1 += deepWarp * 0.52;
    pShape2 += deepWarp * 0.60;
    pWave1 += deepWarp * 0.78;
    pWave2 += deepWarp * 0.72;

    pRim1 += deepWarp * 1.05;
    pRim2 += deepWarp * 0.96;

    // --------------------------------------------------
    // States from specs
    // --------------------------------------------------

    LayerState anim_wave_1 = makeState(
        float2(-38.0, 647.0),
        float2(-238.0, 476.0),
        float2(-121.0, 411.0),
        float2(-117.0, 151.0),

        float2(454.0, 300.0),
        float2(851.0, 562.0),
        float2(619.0, 409.0),
        float2(611.0, 405.0),

        1.00, 0.70, 1.00, 1.00,
        64.0, 64.0, 120.0, 160.0,
        progress
    );

    LayerState anim_wave_2 = makeState(
        float2(-99.0, 364.0),
        float2(-99.0, 442.0),
        float2(-218.0, 197.0),
        float2(-106.0, -107.0),

        float2(556.0, 298.0),
        float2(573.0, 307.0),
        float2(875.0, 466.0),
        float2(589.0, 316.0),

        1.00, 1.00, 1.00, 1.00,
        128.0, 160.0, 120.0, 88.0,
        progress
    );

    LayerState bg_up_02 = makeState(
        float2(-50.0, 37.0),
        float2(-32.0, 37.0),
        float2(-50.0, 37.0),
        float2(-50.0, 37.0),

        float2(475.0, 787.0),
        float2(440.0, 787.0),
        float2(475.0, 787.0),
        float2(475.0, 787.0),

        0.10, 1.00, 1.00, 1.00,
        64.0, 120.0, 64.0, 64.0,
        progress
    );

    LayerState shape_2 = makeState(
        float2(0.0, 705.0),
        float2(-44.0, 856.0),
        float2(-67.0, 663.0),
        float2(-50.0, 702.0),

        float2(375.0, 251.0),
        float2(463.0, 309.0),
        float2(509.0, 340.0),
        float2(475.0, 317.0),

        0.60, 0.70, 0.20, 1.00,
        88.0, 88.0, 88.0, 88.0,
        progress
    );

    LayerState shape_1 = makeState(
        float2(-50.0, 308.0),
        float2(-24.0, 351.0),
        float2(11.0, 78.0),
        float2(-50.0, 308.0),

        float2(475.0, 787.0),
        float2(423.0, 701.0),
        float2(353.0, 585.0),
        float2(475.0, 787.0),

        1.00, 1.00, 0.40, 1.00,
        64.0, 64.0, 146.0, 65.0,
        progress
    );

    // --------------------------------------------------
    // Back liquid layer
    // --------------------------------------------------

    float backShape1 = blueTrapField(
        pShape1Back,
        shape_1,
        87.3259 / 475.0,
        379.735 / 475.0,
        0.0,
        1.0,
        709.291 / 787.0,
        17.4917 / 787.0,
        0.72 * blueDepth
    );

    float backShape2 = blueTrapField(
        pShape2Back,
        shape_2,
        68.9415 / 375.0,
        299.791 / 375.0,
        0.0,
        1.0,
        226.216 / 251.0,
        5.57866 / 251.0,
        0.62 * blueDepth
    );

    float backWave1 = blueTrapField(
        pWave1Back,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        0.72 * blueDepth
    );

    float backWave2 = blueTrapField(
        pWave2Back,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        0.78 * blueDepth
    );

    float backMass = backShape1 + backShape2 + backWave1 + backWave2;
    float backAlpha = 1.0 - exp(-backMass * 0.86);
    backAlpha = clamp(backAlpha * bottomReveal * finalFade, 0.0, 1.0);

    // --------------------------------------------------
    // Main liquid layer
    // --------------------------------------------------

    float shape1Field = blueTrapField(
        pShape1,
        shape_1,
        87.3259 / 475.0,
        379.735 / 475.0,
        0.0,
        1.0,
        709.291 / 787.0,
        17.4917 / 787.0,
        1.08 * blueDepth
    );

    float shape2Field = blueTrapField(
        pShape2,
        shape_2,
        68.9415 / 375.0,
        299.791 / 375.0,
        0.0,
        1.0,
        226.216 / 251.0,
        5.57866 / 251.0,
        0.96 * blueDepth
    );

    float bgUpField = blueTrapField(
        pBgUp,
        bg_up_02,
        0.0,
        1.0,
        87.3259 / 475.0,
        379.735 / 475.0,
        77.709 / 787.0,
        769.508 / 787.0,
        1.03 * blueDepth
    );

    float wave2Field = blueTrapField(
        pWave2,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        1.25 * blueDepth
    );

    float wave1Field = blueTrapField(
        pWave1,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        1.18 * blueDepth
    );

    float svgBlueMass =
        shape1Field +
        shape2Field +
        bgUpField +
        wave1Field +
        wave2Field;

    float mainAlpha = 1.0 - exp(-svgBlueMass * 1.28);
    mainAlpha = clamp(mainAlpha * bottomReveal * finalFade, 0.0, 1.0);

    // --------------------------------------------------
    // Front rim liquid layer
    // --------------------------------------------------

    float rimWave1 = blueTrapField(
        pRim1,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        1.05
    );

    float rimWave2 = blueTrapField(
        pRim2,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        0.98
    );

    float rimAlpha = clamp((rimWave1 + rimWave2) * bottomReveal * rimFinalFade, 0.0, 1.0);
    rimAlpha = smoothstep(0.22, 0.88, rimAlpha);

    float massBreath =
        1.0 +
        0.025 * sin(time * 0.72) +
        0.014 * sin(time * 1.13);

    mainAlpha = clamp(mainAlpha * massBreath, 0.0, 1.0);
    backAlpha = clamp(backAlpha * (1.0 + 0.018 * sin(time * 0.55 + 1.2)), 0.0, 1.0);
    rimAlpha = clamp(rimAlpha * (1.0 + 0.016 * sin(time * 0.80 + 2.1)), 0.0, 1.0);

    float lateAlphaFade = lateTransparency;

    mainAlpha *= mix(1.0, 0.54, lateAlphaFade);
    backAlpha *= mix(1.0, 0.48, lateAlphaFade);
    rimAlpha *= mix(1.0, 0.36, lateAlphaFade);

    // --------------------------------------------------
    // Liquid color model
    // --------------------------------------------------

    float flow =
        0.023 * sin(pGlobal.x * 0.030 + time * 0.75 + rise * 2.2) +
        0.016 * sin(pGlobal.x * 0.070 - time * 0.55 + rise * 3.7) +
        0.011 * sin((pGlobal.x + pGlobal.y) * 0.035 + time * 0.45);

    float liquidY = clamp(
        uv.y * 0.74 + 0.14 + flow - rise * 0.14,
        0.0,
        1.0
    );

    // --------------------------------------------------
    // Delayed blue color ramp
    // --------------------------------------------------

    float blueEmergence = segmentEase(progress, 0.40, 0.56);
    float deepBlueEmergence = segmentEase(progress, 0.54, 0.78);
    float earlySoftness = 1.0 - blueEmergence;

    float targetBluePhase =
        segmentEase(progress, 0.50, 0.62) *
        (1.0 - segmentEase(progress, 0.80, 0.94));

    float3 softAqua = mix(
        cyan,
        aqua,
        0.62
    );

    float3 softBlue = mix(
        aqua,
        targetBlue,
        0.46
    );

    float3 backColor = mix(
        softAqua,
        softBlue,
        smoothstep(0.16, 0.88, liquidY) * blueEmergence
    );

    backColor = mix(
        backColor,
        targetBlue,
        targetBluePhase * 0.72
    );

    backColor = mix(
        backColor,
        mix(targetBlue, deepBlue, 0.26),
        smoothstep(0.78, 1.0, liquidY) * deepBlueEmergence * 0.38
    );

    float3 mainColor = mix(
        cyan,
        aqua,
        smoothstep(0.02, 0.48, liquidY)
    );

    mainColor = mix(
        mainColor,
        softBlue,
        smoothstep(0.34, 0.78, liquidY) * blueEmergence
    );

    mainColor = mix(
        mainColor,
        targetBlue,
        smoothstep(0.44, 0.88, liquidY) * blueEmergence * 0.78
    );

    mainColor = mix(
        mainColor,
        targetBlue,
        targetBluePhase * 0.86
    );

    mainColor = mix(
        mainColor,
        mix(targetBlue, deepBlue, 0.22),
        smoothstep(0.78, 1.0, liquidY) * deepBlueEmergence * 0.42
    );

    mainColor = mix(
        mainColor,
        mix(cyan, aqua, 0.54),
        earlySoftness * 0.38
    );

    backColor = mix(
        backColor,
        mix(cyan, aqua, 0.46),
        earlySoftness * 0.32
    );

    float3 rimColor = mix(
        electric,
        cyan,
        smoothstep(0.0, 1.0, liquidY)
    );

    rimColor = mix(
        rimColor,
        mix(cyan, aqua, 0.52),
        earlySoftness * 0.28
    );

    rimColor = mix(
        rimColor,
        mix(targetBlue, cyan, 0.22),
        targetBluePhase * 0.56
    );

    float3 result = white;

    result = plusDarkerApprox(
        result,
        backColor,
        backAlpha * 0.72
    );

    result = plusDarkerApprox(
        result,
        mainColor,
        mainAlpha
    );

    result += rimColor * rimAlpha * 0.035;

    // --------------------------------------------------
    // Idle wave render
    // --------------------------------------------------

    float idleLuminanceBefore = dot(result, float3(0.299, 0.587, 0.114));

    float idleBlueOnWhite =
        idleWaveEnergy *
        smoothstep(0.56, 1.0, idleLuminanceBefore);

    float idleWhiteOnBlue =
        idleWaveEnergy *
        (1.0 - smoothstep(0.35, 0.88, idleLuminanceBefore));

    result = mix(
        result,
        min(result, waveMid),
        idleBlueOnWhite * 0.22
    );

    result += idleBlueOnWhite * waveDeep * 0.08;
    result += idleWhiteOnBlue * waveGlass * 0.14;
    result += idleWaveEnergy * waveEdge * 0.10;

    // --------------------------------------------------
    // Organic reveal edge glow + surface tension
    // --------------------------------------------------

    result += revealEdgeGlow * float3(0.25, 0.82, 1.0);
    result += revealEdgeGlow * float3(0.75, 1.00, 1.0) * 0.32;

    result += tensionCore * float3(0.56, 1.00, 1.0) * 0.34;

    result += liquidRimLine * float3(0.75, 1.0, 1.0) * 0.18;
    result += liquidRimLine * float3(0.10, 0.55, 1.0) * 0.08;

    result = plusDarkerApprox(
        result,
        deepBlue,
        tensionShadow * 0.18
    );

    // --------------------------------------------------
    // Surface glow
    // --------------------------------------------------

    float liquidAlpha = clamp(mainAlpha + backAlpha * 0.52, 0.0, 1.0);
    float surfaceEnergy = liquidAlpha * (1.0 - liquidAlpha);

    float surfaceGlow = smoothstep(0.08, 0.25, surfaceEnergy);

    result += surfaceGlow * float3(0.10, 0.56, 1.0) * 0.10 * finalFade;
    result += surfaceGlow * float3(0.56, 1.00, 1.0) * 0.045 * finalFade;

    // --------------------------------------------------
    // Bottom clearing
    // --------------------------------------------------

    float bottomClearPower = mix(
        0.38,
        0.68,
        bottomCleanProgress
    );

    result = plusLighterApprox(
        result,
        white,
        min(bottomClear * bottomClearPower, 0.68)
    );

    liquidAlpha *= (1.0 - bottomClear * 0.82);

    // --------------------------------------------------
    // Central white glass lens
    // --------------------------------------------------

    float circleSoftness = mix(
        38.0,
        92.0,
        circleGrowth
    );

    float angle = atan2(
        p.y - center.y,
        p.x - center.x
    );

    float circleNoiseFade = 1.0 - segmentEase(progress, 0.88, 1.00);

    float circleNoise =
        (
            4.2 * sin(angle * 3.0 + time * 0.50) +
            2.6 * sin(angle * 7.0 - time * 0.38)
        ) * circleNoiseFade;

    float circleDist =
        distance(p, center) -
        circleRadius +
        circleNoise;

    float circleFill = 1.0 - smoothstep(
        -circleSoftness * 0.52,
        circleSoftness,
        circleDist
    );

    float circleVisibility = mix(
        0.68,
        0.98,
        smoothstep(0.0, 0.75, progress)
    );

    float visibleCircleFill = circleFill * circleAppear;

    result += visibleCircleFill * circleVisibility * float3(0.12, 0.74, 1.0) * 0.030;

    float circleEdge = exp(-abs(circleDist) / 30.0);
    float tightCircleRim = exp(-abs(circleDist) / 10.0);

    float innerRim = circleEdge * visibleCircleFill * 0.20;

    result += innerRim * float3(0.35, 0.88, 1.0);

    float lensLowerShadow =
        visibleCircleFill *
        smoothstep(center.y - circleRadius * 0.10, center.y + circleRadius * 0.72, p.y) *
        0.055;

    result = mix(
        result,
        result * float3(0.965, 0.985, 1.0),
        lensLowerShadow
    );

    float contactGlow =
        circleEdge *
        liquidAlpha *
        circleAppear *
        (1.0 - circleFill * 0.38);

    float contactTightRim =
        tightCircleRim *
        liquidAlpha *
        circleAppear *
        (1.0 - circleFill * 0.22);

    float magneticPull = segmentEase(progress, 0.35, 0.85);

    float chromaticEdge =
        tightCircleRim *
        liquidAlpha *
        circleAppear *
        (0.35 + 0.65 * magneticPull);

    // Лёгкая хроматическая аберрация при столкновении с центральной маской.
    float2 dirFromCenter = normalize(p - center + float2(0.0001, 0.0001));
    float2 chromaAxis = normalize(float2(0.86, -0.34));

    float chromaDot = dot(dirFromCenter, chromaAxis);
    float redSide = smoothstep(-0.15, 1.0, chromaDot);
    float cyanSide = smoothstep(-0.15, 1.0, -chromaDot);

    result.r += chromaticEdge * redSide * 0.010 * finalFade;
    result.g += chromaticEdge * cyanSide * 0.010 * finalFade;
    result.b += chromaticEdge * cyanSide * 0.022 * finalFade;

    result += contactGlow * float3(0.12, 0.68, 1.0) * (0.76 + magneticPull * 0.18) * finalFade;
    result += contactGlow * float3(0.68, 1.00, 1.0) * (0.30 + magneticPull * 0.12) * finalFade;
    result += contactTightRim * float3(0.72, 1.00, 1.0) * (0.22 + magneticPull * 0.10) * finalFade;

    float innerHalo = exp(
        -max(distance(p, center) - circleRadius * 0.54, 0.0) / 78.0
    );

    result = mix(
        result,
        white,
        innerHalo * 0.11 * circleVisibility * circleAppear
    );

    // --------------------------------------------------
    // Tap blob / residual trail
    // --------------------------------------------------

    float2 tapPx = tapPoint * size;
    float tapDist = distance(position, tapPx);

    float tapTrail =
        exp(-pow(tapDist * 0.010, 2.0)) *
        tapPulse *
        mainAlpha *
        0.10;

    float tapBlobNoise =
        sin(position.x * 0.035 + time * 1.8) *
        sin(position.y * 0.026 - time * 1.3);

    tapTrail *= smoothstep(-0.15, 0.75, tapBlobNoise);

    result += tapTrail * white * finalFade;

    float screenTrailNoise =
        20.0 * sin(uv.y * 13.0 + time * 1.85) +
        12.0 * sin(uv.y * 27.0 - time * 1.10);

    float2 touchDeltaPx = position - tapPx;
    float touchSide = touchDeltaPx.x >= 0.0 ? 1.0 : -1.0;
    float visualShock = dragWave * shockStrength;
    float screenTrailDist = abs(touchDeltaPx.x + screenTrailNoise);
    float screenTrail =
        exp(-pow(screenTrailDist / max(62.0 * waveSpread * shockTrail, 1.0), 2.0)) *
        visualShock *
        mainAlpha *
        finalFade *
        0.22;

    float secondaryTrail =
        exp(-pow((screenTrailDist - mix(70.0, 178.0 * shockTrail, 1.0 - tapPulse)) / max(104.0 * waveSpread, 1.0), 2.0)) *
        visualShock *
        (0.64 + 0.36 * tapPulse) *
        mainAlpha *
        finalFade *
        0.20;

    float diagonalTrailAxis =
        dot(touchDeltaPx, normalize(float2(0.55 * touchSide, 0.83))) +
        22.0 * sin(uv.y * 16.0 + time * 1.6);

    float diagonalTrail =
        exp(-pow(diagonalTrailAxis / max(170.0 * waveSpread, 1.0), 2.0)) *
        exp(-pow(touchDeltaPx.x / max(size.x * 0.82 * shockTrail, 1.0), 2.0)) *
        visualShock *
        mainAlpha *
        finalFade *
        0.18;

    float screenRipple =
        exp(-pow((tapDist - mix(96.0, max(size.x, size.y) * 0.76 * shockTrail, 1.0 - tapPulse)) / max(124.0 * waveSpread, 1.0), 2.0)) *
        visualShock *
        (0.35 + 0.65 * tapPulse) *
        mainAlpha *
        finalFade;

    float causticLines =
        (0.5 + 0.5 * sin(tapDist * 0.062 - time * (6.2 + 1.8 * shockInteraction) + (1.0 - tapPulse) * 7.8)) *
        screenRipple *
        visualShock *
        (0.62 + 0.38 * shockInteraction);

    float wakeCrossing =
        (screenTrail * secondaryTrail + diagonalTrail * screenRipple) *
        (0.76 + 0.44 * shockInteraction);

    float wakeInterference =
        (0.5 + 0.5 * sin(tapDist * 0.040 - time * 5.1)) *
        (0.5 + 0.5 * sin((touchDeltaPx.x * touchSide + touchDeltaPx.y * 0.42) * 0.032 + time * 4.2)) *
        visualShock *
        shockInteraction *
        mainAlpha *
        finalFade;

    float compositeWake =
        screenTrail * 0.48 +
        secondaryTrail * 0.36 +
        diagonalTrail * 0.30 +
        screenRipple * 0.28 +
        causticLines * 0.18 +
        wakeCrossing * 0.42 +
        wakeInterference * 0.16;

    result += screenTrail * white * 0.040;
    result += secondaryTrail * white * 0.032;
    result += diagonalTrail * white * 0.034;
    result += screenRipple * white * 0.044;
    result += causticLines * white * 0.026;
    result += wakeCrossing * white * 0.035;
    result += wakeInterference * white * 0.024;

    // --------------------------------------------------
    // Top reservoir + cinematic finish
    // --------------------------------------------------

    float3 stableFinishColor = mix(
        targetBlue,
        cyan,
        0.18
    );

    float3 initialBottomLikeColor = stableFinishColor;

    float topBreath =
        1.0 +
        completed *
        (
            0.08 * sin(time * 1.55) +
            0.035 * sin(time * 2.25)
        );

    float finalCoreSoft = 1.0 - 0.50 * finalBlur;
    float finalMistBoost = 1.0 + 1.25 * finalBlur;

    float topReservoir =
        exp(-uv.y * 3.20) *
        topReservoirProgress *
        0.38 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topReservoirCore =
        exp(-uv.y * 7.00) *
        topReservoirProgress *
        0.30 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topReservoirGlow =
        exp(-pow((uv.y - 0.125) / 0.26, 2.0)) *
        topReservoirProgress *
        0.13 *
        topBreath *
        finalFade *
        finalMistBoost;

    result = plusDarkerApprox(
        result,
        initialBottomLikeColor,
        topReservoir
    );

    result = plusDarkerApprox(
        result,
        mix(targetBlue, deepBlue, 0.18),
        topReservoirCore
    );

    result += topReservoirGlow * float3(0.22, 0.80, 1.0);

    float finish = topCapProgress;

    float topCapAlpha =
        exp(-uv.y * 4.8) *
        finish *
        0.34 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topCapMist =
        exp(-uv.y * 1.22) *
        finish *
        0.13 *
        topBreath *
        finalFade *
        finalMistBoost;

    result = plusDarkerApprox(
        result,
        initialBottomLikeColor,
        topCapAlpha
    );

    result = plusDarkerApprox(
        result,
        mix(targetBlue, deepBlue, 0.14),
        topCapMist
    );

    result += topCapAlpha * float3(0.10, 0.46, 1.0) * 0.10;
    result += topCapMist * float3(0.42, 0.95, 1.0) * 0.045;

    float3 completionMistColor = mix(
        targetBlue,
        cyan,
        0.22
    );

    float completionMist =
        exp(-uv.y * 1.05) *
        completionMistProgress *
        0.12 *
        finalFade *
        finalMistBoost;

    float trailingGlow =
        exp(-pow((uv.y - 0.18) / 0.22, 2.0)) *
        finalBlur *
        0.10 *
        finalFade;

    result += completionMist * completionMistColor;
    result += trailingGlow * float3(0.30, 0.92, 1.0);

    result += completionFlash * float3(0.45, 0.95, 1.0) * 0.08;

    float completionPulse =
        completionBloom *
        (1.0 - 0.35 * sin(time * 2.4));

    float completionTopGlow =
        exp(-uv.y * 4.2) *
        completionPulse *
        0.06 *
        finalFade;

    result += completionTopGlow * float3(0.30, 0.82, 1.0);
    result = mix(result, white, completionBloom * bottomClear * 0.025);

    // --------------------------------------------------
    // Adaptive tap shockwave
    // --------------------------------------------------

    float rippleRadius = (1.0 - tapPulse) * mix(92.0, 310.0, dragWave);

    float rippleRing =
        exp(-pow((tapDist - rippleRadius) * 0.0064, 2.0)) *
        dragWave *
        (0.28 + 0.72 * tapPulse) *
        mix(0.7, 1.15, waveStrength);

    float rippleCore =
        exp(-pow(tapDist * 0.010, 2.0)) *
        dragWave *
        0.10 *
        waveStrength;

    float luminance = dot(result, float3(0.299, 0.587, 0.114));

    float blueRingStrength = rippleRing * smoothstep(0.60, 1.0, luminance);
    float whiteRingStrength = rippleRing * (1.0 - smoothstep(0.40, 0.90, luminance));

    float frontBand =
        localWaterPressure * 0.34 +
        abs(localWaterWave) * 0.30 +
        compositeWake * 0.24;

    float glassSheen =
        smoothstep(0.42, 1.0, compositeWake + frontBand) *
        (0.5 + 0.5 * sin(position.y * 0.030 - time * 4.5 + tapDist * 0.015)) *
        visualShock;

    result = mix(
        result,
        white,
        blueRingStrength * 0.08 + frontBand * 0.035
    );

    result += blueRingStrength * white * 0.035;

    result += whiteRingStrength * white * 0.10;
    result += rippleCore * white * 0.08;
    result += frontBand * white * 0.045;
    result += glassSheen * white * 0.026;
    result += max(localWaterWave, 0.0) * white * 0.16;
    result = mix(
        result,
        white,
        max(-localWaterWave, 0.0) * 0.030
    );

    // --------------------------------------------------
    // Keyframe-matched hero wash
    // --------------------------------------------------

    float keyProgress = clamp(progress, 0.0, 0.82);
    float keyPresence = smoothstep(0.02, 0.18, keyProgress) * fillGain;

    float keyedEdgeY = interpKeys(
        0.86,
        0.62,
        0.38,
        -0.10,
        keyProgress
    );

    float keyedFeather = interpKeys(
        0.16,
        0.22,
        0.31,
        0.27,
        keyProgress
    );

    float keyDx = uv.x - 0.5;

    float keyedSag =
        keyDx * keyDx *
        interpKeys(0.26, 0.32, 0.24, -0.30, keyProgress);

    float keyedEdgeNoise =
        0.012 * sin(uv.x * 9.0 + time * 0.24 + keyProgress * 4.0) +
        0.007 * sin(uv.x * 21.0 - time * 0.16 + keyProgress * 7.0) +
        dragWave * 0.018 * sin(uv.x * 13.0 + time * 0.36);

    float keyedLowerMass = smoothstep(
        keyedEdgeY - keyedFeather,
        keyedEdgeY + keyedFeather,
        uv.y + keyedSag + keyedEdgeNoise
    );

    float lowerFade = 1.0 - segmentEase(keyProgress, 0.62, 0.90);
    keyedLowerMass *= keyPresence * lowerFade;

    float keyedBottomWeight = smoothstep(0.28, 0.96, uv.y);
    float keyedLowerCore = keyedLowerMass * keyedBottomWeight * 0.88;

    float keyedCyanBand =
        exp(-pow((uv.y - keyedEdgeY) / max(keyedFeather * 1.18, 0.01), 2.0)) *
        exp(-pow(keyDx / 0.62, 2.0)) *
        keyPresence *
        lowerFade;

    float3 keyedBlueColor = mix(
        targetBlue,
        blue,
        0.10 + 0.18 * smoothstep(0.20, 0.46, keyProgress)
    );

    keyedBlueColor = mix(
        keyedBlueColor,
        mix(targetBlue, deepBlue, 0.12),
        smoothstep(0.50, 0.74, keyProgress) * smoothstep(0.58, 1.0, uv.y)
    );

    float3 keyedLowerColor = mix(
        mix(cyan, aqua, 0.50),
        keyedBlueColor,
        smoothstep(0.48, 1.0, uv.y)
    );

    result = plusDarkerApprox(
        result,
        keyedLowerColor,
        keyedLowerCore * 0.42 * fillGain
    );

    result += keyedCyanBand * float3(0.38, 0.88, 1.0) * 0.045 * waveStrength;

    float lensY = interpKeys(
        0.74,
        0.56,
        0.59,
        0.31,
        keyProgress
    );

    float lensRX = interpKeys(
        0.55,
        0.62,
        0.60,
        0.57,
        keyProgress
    );

    float lensRY = interpKeys(
        0.21,
        0.19,
        0.20,
        0.19,
        keyProgress
    );

    float lensTopFade =
        smoothstep(0.08, 0.24, keyProgress) *
        (1.0 - segmentEase(keyProgress, 0.88, 1.0));

    float lensD =
        pow((uv.x - 0.5) / max(lensRX, 0.01), 2.0) +
        pow((uv.y - lensY) / max(lensRY, 0.01), 2.0);

    float keyedWhiteLens =
        (1.0 - smoothstep(0.56, 1.48, lensD)) *
        lensTopFade;

    float keyedLensHalo =
        exp(-pow((sqrt(max(lensD, 0.0)) - 0.88) / 0.46, 2.0)) *
        lensTopFade;

    result += keyedWhiteLens * float3(0.18, 0.74, 1.0) * 0.030 * whiteCore;
    result += keyedLensHalo * float3(0.44, 0.92, 1.0) * 0.055 * whiteCore;

    float topPhase =
        segmentEase(keyProgress, 0.58, 0.84) *
        (1.0 - segmentEase(keyProgress, 0.94, 1.0));

    float topCurve =
        0.24 +
        keyDx * keyDx * 0.62 +
        0.011 * sin(uv.x * 8.0 + time * 0.20);

    float topCap =
        (1.0 - smoothstep(topCurve - 0.16, topCurve + 0.24, uv.y)) *
        topPhase;

    float topCore =
        exp(-uv.y * 3.1) *
        topPhase;

    float topMistBand =
        exp(-pow((uv.y - topCurve) / 0.26, 2.0)) *
        exp(-pow(keyDx / 0.78, 2.0)) *
        topPhase;

    float3 topKeyColor = mix(
        targetBlue,
        blue,
        0.16 * topBloom
    );

    result = plusDarkerApprox(
        result,
        topKeyColor,
        clamp(topCap * 0.46 + topCore * 0.12, 0.0, 1.0)
    );

    result += topMistBand * float3(0.56, 1.0, 1.0) * 0.13 * topBloom;

    float topWhiteBowl =
        (1.0 - smoothstep(0.62, 1.30, lensD)) *
        topPhase *
        0.70 * whiteCore;

    result += topWhiteBowl * float3(0.14, 0.62, 1.0) * 0.025;

    float2 swipeNow = float2((tapPoint.x - 0.5) * (safeSize.x / safeSize.y) + 0.5, tapPoint.y);
    float2 swipePrevious = float2((previousTouchPoint.x - 0.5) * (safeSize.x / safeSize.y) + 0.5, previousTouchPoint.y);
    float2 swipeUv = float2((uv.x - 0.5) * (safeSize.x / safeSize.y) + 0.5, uv.y);
    float2 swipePath = swipeNow - swipePrevious;
    float swipePathLength = length(swipePath);
    float swipeMovement = smootherLiquid(smoothstep(0.002, 0.030, swipePathLength));
    float swipeEnergy = swipePulse * swipeMovement * smoothstep(0.010, 0.16, swipeStrength);
    float2 swipeDir = swipePath / max(swipePathLength, 0.0001);
    float2 swipeNormal = float2(-swipeDir.y, swipeDir.x);
    float2 swipeCenter = mix(swipePrevious, swipeNow, 0.54);
    float2 swipeDelta = swipeUv - swipeCenter;
    float swipeAlong = dot(swipeDelta, swipeDir);
    float swipeLateral = dot(swipeDelta, swipeNormal);
    float swipeLength = mix(0.26, 0.48, smoothstep(0.004, 0.070, swipePathLength));
    float swipeWidth = mix(0.105, 0.172, smoothstep(0.012, 0.30, swipeStrength));
    float swipeBody =
        (1.0 - smoothstep(swipeLength * 0.42, swipeLength * 0.64, abs(swipeAlong))) *
        exp(-pow(swipeLateral / max(swipeWidth, 0.001), 2.0));
    float swipeCore =
        (1.0 - smoothstep(swipeLength * 0.18, swipeLength * 0.46, abs(swipeAlong))) *
        exp(-pow(swipeLateral / max(swipeWidth * 0.52, 0.001), 2.0));
    float swipeTail =
        smoothstep(-swipeLength * 0.62, -swipeLength * 0.08, swipeAlong) *
        (1.0 - smoothstep(swipeLength * 0.08, swipeLength * 0.60, swipeAlong)) *
        exp(-pow(swipeLateral / max(swipeWidth * 1.28, 0.001), 2.0));
    float swipeRipple =
        0.5 + 0.5 * sin(swipeAlong * 34.0 - swipeLateral * 13.0 + time * 1.8);
    float swipeSmear = clamp((swipeBody * 0.72 + swipeCore * 0.34 + swipeTail * 0.42) * swipeEnergy, 0.0, 1.0);
    float swipeGlassEdge =
        exp(-pow((abs(swipeLateral) - swipeWidth * 0.72) / max(swipeWidth * 0.36, 0.001), 2.0)) *
        (1.0 - smoothstep(swipeLength * 0.38, swipeLength * 0.66, abs(swipeAlong))) *
        swipeEnergy;
    float swipeAura =
        exp(-pow(swipeLateral / max(swipeWidth * 1.72, 0.001), 2.0)) *
        (1.0 - smoothstep(swipeLength * 0.48, swipeLength * 0.82, abs(swipeAlong))) *
        swipeEnergy;
    float swipeFlow =
        (0.5 + 0.5 * sin(swipeAlong * 13.0 - time * 2.2)) *
        exp(-pow(swipeLateral / max(swipeWidth * 1.08, 0.001), 2.0)) *
        swipeEnergy;

    result = mix(
        result,
        white,
        clamp(swipeSmear * (0.66 + swipeCore * 0.28), 0.0, 0.82)
    );
    result = plusDarkerApprox(
        result,
        white,
        clamp(swipeAura * 0.18 + swipeFlow * 0.08, 0.0, 0.24)
    );
    result += swipeSmear * white * 0.050;
    result += swipeGlassEdge * white * (0.044 + swipeRipple * 0.024);

    float grainMask = clamp(
        liquidAlpha +
        backAlpha * 0.55 +
        mainAlpha * 0.35 +
        topReservoirProgress * 0.30 +
        idleWaveEnergy * 0.30,
        0.0,
        1.0
    );

    float grain = (hashLiquid(position + float2(time * 0.37)) - 0.5);

    result += grain * mix(0.0012, 0.0052, grainMask) * finalFade;

    float rippleShade = clamp(shadertoyRippleLight, -1.0, 1.0) * rippleEnvelope;
    result += rippleShade * white * 0.14;
    result = mix(
        result,
        white,
        max(-rippleShade, 0.0) * 0.035
    );

    float3 lightResult = clamp(result, 0.0, 1.0);

    float3 preThemeMotionResult = lightResult;
    float3 darkSourceLightResult = lightResult;

    float motionColorRestore = clamp(
        tapTrail * 2.10 +
        screenTrail * 2.40 +
        secondaryTrail * 2.00 +
        diagonalTrail * 1.85 +
        screenRipple * 1.65 +
        compositeWake * 1.45 +
        frontBand * 1.55 +
        swipeSmear * 1.95 +
        swipeAura * 1.35 +
        swipeGlassEdge * 1.70 +
        abs(rippleShade) * 1.40,
        0.0,
        1.0
    );
    motionColorRestore = smootherLiquid(motionColorRestore);

    float yellowColoredPresence =
        smoothstep(0.018, 0.27, distance(lightResult, white)) *
        (1.0 - motionColorRestore * 0.98);
    float yellowProgressPresence = smoothstep(0.025, 0.16, progress);
    float yellowWarmDepth = smoothstep(0.46, 1.0, uv.y);
    float yellowTopGlow = 1.0 - smoothstep(0.16, 0.58, uv.y);
    float yellowBottomGlow = smoothstep(0.55, 1.0, uv.y);

    float3 yellowLemon = float3(1.0, 0.975, 0.035);
    float3 yellowSoft = float3(1.0, 0.955, 0.24);
    float3 yellowAmber = float3(1.0, 0.635, 0.060);
    float3 yellowTarget = mix(yellowLemon, yellowAmber, smootherLiquid(yellowWarmDepth));
    yellowTarget = mix(yellowTarget, yellowSoft, yellowTopGlow * 0.24);
    yellowTarget = mix(yellowTarget, yellowAmber, yellowBottomGlow * 0.20);

    float yellowWhiteCenterY =
        0.515 +
        0.020 * sin(time * 0.18 + progress * 4.2);

    float yellowWhiteCenterD =
        pow((uv.x - 0.50) / 0.73, 2.0) +
        pow((uv.y - yellowWhiteCenterY) / 0.205, 2.0);

    float yellowWhiteCenter =
        (1.0 - smoothstep(0.58, 1.34, yellowWhiteCenterD)) *
        yellowProgressPresence *
        (1.0 - segmentEase(progress, 0.94, 1.0) * 0.16);

    float yellowTopWash =
        exp(-pow((uv.y - 0.145) / 0.34, 2.0)) *
        yellowColoredPresence *
        0.18;

    float yellowBottomWash =
        exp(-pow((uv.y - 0.955) / 0.30, 2.0)) *
        yellowColoredPresence *
        0.26;

    lightResult = mix(
        lightResult,
        yellowTarget,
        isYellowPreset * clamp(yellowColoredPresence * 0.92, 0.0, 0.92)
    );

    lightResult = mix(
        lightResult,
        white,
        isYellowPreset * clamp(yellowWhiteCenter * 0.84, 0.0, 0.86)
    );

    lightResult += isYellowPreset * yellowTopWash * float3(1.0, 0.96, 0.08);
    lightResult += isYellowPreset * yellowBottomWash * float3(1.0, 0.53, 0.03);
    lightResult = clamp(lightResult, 0.0, 1.0);
    lightResult = mix(
        lightResult,
        preThemeMotionResult,
        isYellowPreset * motionColorRestore
    );

    // Shared travelling-band timing; each light preset applies its own palette below.
    float referenceBandCenter;
    float referenceBandWidth;
    if (progress <= 0.50) {
        float phase = smootherLiquid(progress / 0.50);
        referenceBandCenter = bandMotion(1.105, 0.855, 0.0, -0.838028, progress / 0.50, 0.50);
        referenceBandWidth = mix(0.205, 0.315, phase);
    } else if (progress <= 0.70) {
        float phase = smootherLiquid((progress - 0.50) / 0.20);
        referenceBandCenter = bandMotion(0.855, 0.515, -0.838028, -1.676693, (progress - 0.50) / 0.20, 0.20);
        referenceBandWidth = mix(0.315, 0.285, phase);
    } else {
        float phase = smootherLiquid((progress - 0.70) / 0.30);
        referenceBandCenter = bandMotion(0.515, 0.020, -1.676693, 0.0, (progress - 0.70) / 0.30, 0.30);
        referenceBandWidth = mix(0.285, 0.235, phase);
    }

    // Yellow follows the established Blue entry; Blue geometry stays unchanged.
    referenceBandCenter -= clamp(isBluePreset + isYellowPreset, 0.0, 1.0) * 0.065 * smoothstep(0.0, 0.05, progress) *
        (1.0 - segmentEase(progress, 0.26, 0.45));
    // Continue the shared mass upward after 90%, without changing the clock.
    referenceBandCenter -= 0.075 * segmentEase(progress, 0.90, 1.0);

    float referenceWarp =
        sin(uv.x * 5.7 + time * 0.11) * 0.018 +
        sin(uv.x * 10.4 - time * 0.08 + 1.2) * 0.008;
    float referenceDistance = uv.y + referenceWarp - referenceBandCenter;
    float referenceOuter = exp(-pow(referenceDistance / referenceBandWidth, 2.0));
    float referenceBody = exp(-pow(referenceDistance / (referenceBandWidth * 0.70), 2.0));
    float referenceCore = exp(-pow(referenceDistance / (referenceBandWidth * 0.34), 2.0));
    float referenceEntry = smoothstep(0.002, 0.020, progress);
    referenceOuter *= referenceEntry;
    referenceBody *= referenceEntry;
    referenceCore *= referenceEntry;

    float3 referenceCyan = float3(0.380, 0.910, 1.000);
    float3 referenceBlue = float3(0.259, 0.545, 0.976); // #428BF9
    float3 referenceBlueAccent = float3(0.000, 0.424, 1.000); // #006CFF
    // One broad pigment profile avoids the narrow accent stripe produced by
    // compositing several differently sized blue cores over one another.
    float blueLightDensity = exp(-pow(referenceDistance / (referenceBandWidth * 0.82), 2.0)) * referenceEntry;
    float3 blueLightPigment = mix(referenceCyan, mix(referenceBlue, referenceBlueAccent, 0.36),
        blueLightDensity * blueLightDensity * 0.85);
    float3 referenceBlueResult = mix(white, blueLightPigment,
        referenceOuter * (0.82 + 0.16 * blueLightDensity));

    // Match Blue Light's monotonic depth profile: orange in the dense body,
    // #FFDD2D in the shoulder, then yellow coverage dissolving into white.
    float yellowOrangeWeight = pow(blueLightDensity, 4.0) * 0.60;
    float3 yellowLightOrange = mix(yellowMidColor.rgb, yellowHotColor.rgb, 0.25);
    float3 yellowLightPigment = mix(yellowLightAccent, yellowLightOrange, yellowOrangeWeight);
    float3 referenceYellowResult = mix(white, yellowLightPigment,
        referenceOuter * (0.82 + 0.16 * blueLightDensity));

    lightResult = mix(lightResult, referenceBlueResult, isBluePreset);
    lightResult = mix(lightResult, referenceYellowResult, isYellowPreset);

    float liquidPresence = clamp(distance(darkSourceLightResult, white) * 1.38, 0.0, 1.0);
    float glowPresence = clamp(
        liquidPresence +
        rimAlpha * 0.32 +
        revealEdgeGlow * 0.50 +
        surfaceGlow * 0.22,
        0.0,
        1.0
    );
    float finishLift = segmentEase(progress, 0.76, 1.00);
    float bottomWeightDark = smoothstep(0.32, 1.0, uv.y);
    float topWeightDark = 1.0 - smoothstep(0.10, 0.46, uv.y);
    float finishTopPush =
        finishLift *
        (1.0 - smoothstep(0.11, 0.48, uv.y)) *
        (0.78 + 0.22 * exp(-pow((uv.y - 0.08) / 0.17, 2.0)));
    float sideGlowDark =
        exp(-pow(uv.x / 0.13, 2.0)) +
        exp(-pow((1.0 - uv.x) / 0.13, 2.0));

    float darkLowerField = clamp(
        glowPresence * (0.56 + bottomWeightDark * 0.42) +
        keyedLowerCore * 0.92 +
        keyedCyanBand * 0.44 +
        liquidAlpha * bottomWeightDark * 0.54 +
        surfaceGlow * 0.22,
        0.0,
        1.0
    );
    darkLowerField *= mix(1.0, 0.015, finishLift);

    float darkTopField = clamp(
        topPhase * (topCap * 0.80 + topCore * 0.34 + topMistBand * 0.72) +
        topReservoir * 0.72 +
        topReservoirCore * 0.54 +
        topReservoirGlow * 0.80 +
        completionMist * 0.82 +
        trailingGlow * 0.70 +
        completionTopGlow * 0.80 +
        finishLift * topWeightDark * 1.04 +
        finishTopPush * 0.42,
        0.0,
        1.0
    );

    // The dark palette always starts on a true black canvas. The selected color is
    // revealed only by the progressing field, never inherited from the light result.
    float darkColorReveal = smoothstep(0.015, 0.24, progress);
    darkLowerField *= darkColorReveal;
    darkTopField *= darkColorReveal;

    float cyanWashDark = clamp(
        keyedCyanBand * 0.70 +
        keyedLensHalo * 0.30 +
        revealEdgeGlow * 0.72 +
        rimAlpha * 0.24,
        0.0,
        1.0
    ) * darkColorReveal;

    // One soft, asymmetric reduction of light behind the digits; no ring or
    // constant-radius plateau. Coordinates match the existing counter region.
    float counterDrift = sin(time * 0.16) * 0.006;
    float2 counterDelta = float2(
        (uv.x - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.29,
        (uv.y - 0.475 + sin(uv.x * 8.0 + 0.8) * 0.016 + counterDrift) / 0.090
    );
    float2 counterLobe = float2((uv.x - 0.57) / 0.23, (uv.y - 0.45 + counterDrift) / 0.105);
    float counterProtection = 0.76 * exp(-dot(counterDelta, counterDelta)) +
        0.24 * exp(-dot(counterLobe, counterLobe));
    // A diffuse light pocket restores the clean light-theme counter area
    // without the former circular stroke or stacked glass-lens masks.
    lightResult = mix(lightResult, white, counterProtection * 0.32);

    float centerVoidD =
        pow((uv.x - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.354, 2.0) +
        pow((uv.y - 0.475 + sin(uv.x * 8.0 + 0.8) * 0.014) / 0.150, 2.0);
    float centerVoid = (1.0 - smoothstep(0.36, 1.68, centerVoidD)) *
        mix(0.56, 0.82, smoothstep(0.02, 0.58, progress));
    float centerVoidSoft = (1.0 - smoothstep(0.58, 2.55, centerVoidD)) *
        mix(0.18, 0.32, smoothstep(0.10, 0.72, progress));
    float centerReduction = clamp(centerVoid * 0.58 + centerVoidSoft * 0.18, 0.0, 0.70);

    float topBlackShelf =
        (1.0 - smoothstep(0.20, 0.52, uv.y)) *
        (1.0 - smoothstep(0.0, 0.18, progress)) *
        0.38;

    float3 darkBase = float3(0.0, 0.0, 0.0);
    float3 darkNavy = float3(0.004, 0.010, 0.024);
    float3 darkBlueGlow = mix(
        float3(0.045, 0.230, 0.780),
        float3(0.820, 0.405, 0.018),
        isYellowPreset
    );
    float3 darkElectric = mix(
        float3(0.100, 0.430, 1.000),
        float3(1.000, 0.720, 0.030),
        isYellowPreset
    );
    float3 darkCyan = mix(
        float3(0.520, 0.960, 1.000),
        float3(1.000, 0.925, 0.210),
        isYellowPreset
    );
    float3 darkMintCyan = mix(
        float3(0.650, 1.000, 0.900),
        float3(1.000, 0.970, 0.560),
        isYellowPreset
    );

    float lowerIntensity = smootherLiquid(darkLowerField);
    float topIntensity = smootherLiquid(darkTopField);
    float edgeIntensity = clamp(sideGlowDark * (darkLowerField * 0.30 + darkTopField * 0.34), 0.0, 1.0);

    float3 darkResult = darkBase;
    darkResult = mix(darkResult, darkNavy, clamp(darkLowerField * 0.52 + darkTopField * 0.38, 0.0, 1.0));
    darkResult += mix(darkBlueGlow, darkElectric, smoothstep(0.22, 0.92, lowerIntensity)) * lowerIntensity * 0.82;
    darkResult += darkCyan * cyanWashDark * 0.24;
    darkResult += darkMintCyan * keyedWhiteLens * 0.10 * darkColorReveal;
    darkResult += mix(darkBlueGlow, darkElectric, 0.52) * topIntensity * 0.86;
    darkResult += darkCyan * topMistBand * 0.22 * darkColorReveal;
    darkResult += darkElectric * edgeIntensity * 0.42;
    darkResult += mix(darkBlueGlow, darkElectric, 0.72) * finishTopPush * 0.34;

    darkResult = mix(darkResult, darkBase, clamp(centerVoidSoft, 0.0, 0.34));
    darkResult = mix(darkResult, darkBase, clamp(centerVoid, 0.0, 0.86));
    darkResult = mix(darkResult, darkBase, finishLift * smoothstep(0.30, 0.72, uv.y) * 0.64);
    darkResult = mix(darkResult, darkBase, topBlackShelf);
    float blueIdleAccent = isBluePreset * idleWaveEnergy * (1.0 - motionColorRestore * 0.85);
    darkResult += float3(0.000, 0.423529, 1.000) * blueIdleAccent * 0.74;
    darkResult += float3(0.540, 0.900, 1.000) * blueIdleAccent * 0.24;
    float yellowIdleAccent = isYellowPreset * idleWaveEnergy * (1.0 - motionColorRestore * 0.85);
    darkResult += float3(1.000, 0.780, 0.075) * yellowIdleAccent * 0.62;
    darkResult += float3(1.000, 0.956, 0.365) * yellowIdleAccent * 0.24;

    // Dark mode uses the same travelling band as the light reference. Only the
    // canvas changes to black; no accumulated color remains below the band.
    float3 darkBandOuterColor = mix(targetBlue, cyan, 0.30);
    float3 darkBandBodyColor = mix(targetBlue, electric, 0.34);
    float3 darkBandCoreColor = mix(targetBlue, electric, 0.72);
    if (isYellowPreset > 0.5) {
        // Carry Blue Dark's dominant-channel light field through the shared
        // masks first. Apply Yellow's palette after them, not before dimming.
        darkBandOuterColor = darkBandBodyColor = darkBandCoreColor = float3(1.0);
    }
    float darkBandEntry = smoothstep(0.002, 0.020, progress);
    float darkBandOuter = referenceOuter * darkBandEntry;
    float darkBandBody = referenceBody * darkBandEntry;
    float darkBandCore = referenceCore * darkBandEntry;
    float3 travellingDarkResult = darkBase;
    travellingDarkResult += darkBandOuterColor * darkBandOuter * 0.20;
    travellingDarkResult += darkBandBodyColor * darkBandBody * 0.58;
    travellingDarkResult += darkBandCoreColor * darkBandCore * 0.54;
    travellingDarkResult = mix(
        travellingDarkResult,
        darkBase,
        centerReduction
    );
    darkResult = travellingDarkResult;
    // Clear behind the moving mass, not through its bright core at 70–85%.
    // Rejoin the original completion fade before the explicit endpoint gate.
    float completionBlackout =
        segmentEase(progress, 0.58, 0.98) *
        smoothstep(0.06, 0.38, uv.y) *
        mix(smoothstep(0.04, 0.32, referenceDistance),
            1.0, segmentEase(progress, 0.85, 0.98));
    darkResult = mix(darkResult, darkBase, completionBlackout);
    // Hard safety gate: no color is allowed to leak into a dark-theme canvas at 0%.
    // This is intentionally applied after every dark effect contribution.
    float darkCanvasReveal = smoothstep(0.0, 0.10, progress);
    darkResult = mix(darkBase, darkResult, darkCanvasReveal);

    float finishSync = segmentEase(progress, 0.94, 1.0);
    float endpointCoverage = referenceOuter * (0.82 + 0.16 * blueLightDensity) *
        (1.0 - counterProtection * 0.32);
    float3 endpointColor = isYellowPreset > 0.5 ? float3(1.0) : darkBandCoreColor;
    darkResult = mix(darkResult, endpointColor * endpointCoverage, finishSync);
    // Blue Dark's unbounded density is the only spatial input to palette
    // mapping. A second, narrower body mask made the other palettes read as
    // stripes even though their outer coverage matched Blue.
    float sharedLightField = max(darkResult.r, max(darkResult.g, darkResult.b));
    // REGRESSION LOCK: geometry is resolved ONCE before any of the four palettes.
    // Main/front/free-wave fields contain no theme or color coefficients.
    float idleDensity = idleActivity > 0.0
        ? idleWaveDensity(position, size, idleActivity, idleTime, waveStrength) : 0.0;
    IdleContact contact = sharedIdleContact(sharedLightField, float(half(idleDensity)));
    float3 blueDarkReference = darkResult;
    if (isYellowPreset > 0.5) {
        blueDarkReference = float3(0.10, 0.55, 1.0) * sharedLightField;
        // No endpoint hue/exposure switch, threshold or highlight layer.
        darkResult = yellowDarkDensityPalette(sharedLightField);
    }
    // QA A: MAIN spatial symmetry only. Palette, density readout and all
    // interaction fields above stay original. No RGB/pixel mirroring.
    float qaVisualDistance = referenceDistance;
    float qaVisualCenterReduction = centerReduction;
    float qaVisualCompletion = completionBlackout;
    float3 qaVisualMain = darkResult;
    if (isBluePreset > 0.5 && themeStrength > 0.5) {
        float qaMirrorX = 1.0 - uv.x;
        float qaMirrorWarp = sin(qaMirrorX * 5.7 + time * 0.11) * 0.018 +
            sin(qaMirrorX * 10.4 - time * 0.08 + 1.2) * 0.008;
        qaVisualDistance = uv.y + (referenceWarp + qaMirrorWarp) * 0.5 - referenceBandCenter;
        float qaOuter = exp(-pow(qaVisualDistance / referenceBandWidth, 2.0)) * referenceEntry;
        float qaBody = exp(-pow(qaVisualDistance / (referenceBandWidth * 0.70), 2.0)) * referenceEntry;
        float qaCore = exp(-pow(qaVisualDistance / (referenceBandWidth * 0.34), 2.0)) * referenceEntry;
        float qaMirrorVoidD =
            pow((qaMirrorX - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.354, 2.0) +
            pow((uv.y - 0.475 + sin(qaMirrorX * 8.0 + 0.8) * 0.014) / 0.150, 2.0);
        float qaBalancedVoidD = (centerVoidD + qaMirrorVoidD) * 0.5;
        float qaVoid = (1.0 - smoothstep(0.36, 1.68, qaBalancedVoidD)) *
            mix(0.56, 0.82, smoothstep(0.02, 0.58, progress));
        float qaVoidSoft = (1.0 - smoothstep(0.58, 2.55, qaBalancedVoidD)) *
            mix(0.18, 0.32, smoothstep(0.10, 0.72, progress));
        qaVisualCenterReduction = clamp(qaVoid * 0.58 + qaVoidSoft * 0.18, 0.0, 0.70);
        qaVisualCompletion = segmentEase(progress, 0.58, 0.98) *
            smoothstep(0.06, 0.38, uv.y) * mix(smoothstep(0.04, 0.32, qaVisualDistance),
                1.0, segmentEase(progress, 0.85, 0.98));
        float2 qaMirrorCounter = float2(
            (qaMirrorX - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.29,
            (uv.y - 0.475 + sin(qaMirrorX * 8.0 + 0.8) * 0.016 + counterDrift) / 0.090);
        float2 qaMirrorLobe = float2((qaMirrorX - 0.57) / 0.23, (uv.y - 0.45 + counterDrift) / 0.105);
        float qaCounter = (counterProtection + 0.76 * exp(-dot(qaMirrorCounter, qaMirrorCounter)) +
            0.24 * exp(-dot(qaMirrorLobe, qaMirrorLobe))) * 0.5;
        float qaBlueDensity = exp(-pow(qaVisualDistance / (referenceBandWidth * 0.82), 2.0)) * referenceEntry;
        float qaEndpoint = qaOuter * (0.82 + 0.16 * qaBlueDensity) * (1.0 - qaCounter * 0.32);
        // QA: reuse the approved 33% exterior attenuation in MAIN-local coordinates.
        // Original geometry, A symmetry and contact masks above are untouched.
        const float qaFadeReferenceProgress = 0.33;
        float qaFadeReferenceCenter = bandMotion(1.105, 0.855, 0.0, -0.838028,
            qaFadeReferenceProgress / 0.50, 0.50);
        qaFadeReferenceCenter -= 0.065 * smoothstep(0.0, 0.05, qaFadeReferenceProgress) *
            (1.0 - segmentEase(qaFadeReferenceProgress, 0.26, 0.45));
        float qaFadeReferenceWidth = mix(0.205, 0.315,
            smootherLiquid(qaFadeReferenceProgress / 0.50));
        float qaFadeLocalDistance = qaVisualDistance / referenceBandWidth;
        float qaFadeReferenceY = qaFadeReferenceCenter - (referenceWarp + qaMirrorWarp) * 0.5 -
            qaFadeLocalDistance * qaFadeReferenceWidth;
        float qaFadeVoidD =
            pow((uv.x - 0.5 + sin(qaFadeReferenceY * 11.0 + time * 0.12) * 0.018) / 0.354, 2.0) +
            pow((qaFadeReferenceY - 0.475 + sin(uv.x * 8.0 + 0.8) * 0.014) / 0.150, 2.0);
        float qaFadeMirrorVoidD =
            pow((qaMirrorX - 0.5 + sin(qaFadeReferenceY * 11.0 + time * 0.12) * 0.018) / 0.354, 2.0) +
            pow((qaFadeReferenceY - 0.475 + sin(qaMirrorX * 8.0 + 0.8) * 0.014) / 0.150, 2.0);
        float qaFadeBalancedVoidD = (qaFadeVoidD + qaFadeMirrorVoidD) * 0.5;
        float qaFadeVoid = (1.0 - smoothstep(0.36, 1.68, qaFadeBalancedVoidD)) *
            mix(0.56, 0.82, smoothstep(0.02, 0.58, qaFadeReferenceProgress));
        float qaFadeVoidSoft = (1.0 - smoothstep(0.58, 2.55, qaFadeBalancedVoidD)) *
            mix(0.18, 0.32, smoothstep(0.10, 0.72, qaFadeReferenceProgress));
        float qaFadeReferenceReduction = clamp(qaFadeVoid * 0.58 + qaFadeVoidSoft * 0.18, 0.0, 0.70);
        // Restrict this readout to the outgoing lower flank beyond the existing core.
        // Reuse core/body radii and the upper-travel interval, not a progress-86 switch.
        // Complete the existing local-mask transition within the core radius.
        // Do not rebuild a second shoulder at the body/core junction.
        float qaFadeExteriorWeight = segmentEase(qaFadeLocalDistance, 0.0, 0.34) *
            segmentEase(progress, 0.70, 0.90);
        float qaFadeTransmission = mix(
            (1.0 - qaVisualCenterReduction) * (1.0 - qaVisualCompletion),
            1.0 - qaFadeReferenceReduction * (1.0 - finishSync), qaFadeExteriorWeight);
        qaVisualMain = (darkBandOuterColor * qaOuter * 0.20 +
            darkBandBodyColor * qaBody * 0.58 + darkBandCoreColor * qaCore * 0.54) *
            darkBandEntry * qaFadeTransmission * darkCanvasReveal;
        // Preserve the travelling profile at completion: synchronize intensity,
        // not a second, broader endpoint geometry. Evaluate its visible peak only.
        float qaPeakY = clamp(referenceBandCenter - (referenceWarp + qaMirrorWarp) * 0.5, 0.0, 1.0);
        float qaPeakU = (qaPeakY + (referenceWarp + qaMirrorWarp) * 0.5 - referenceBandCenter) / referenceBandWidth;
        float qaPeakOuter = exp(-pow(qaPeakU, 2.0));
        float qaPeakBody = exp(-pow(qaPeakU / 0.70, 2.0));
        float qaPeakCore = exp(-pow(qaPeakU / 0.34, 2.0));
        float qaPeakBlue = exp(-pow(qaPeakU / 0.82, 2.0));
        float2 qaPeakCounter = float2(
            (uv.x - 0.5 + sin(qaPeakY * 11.0 + time * 0.12) * 0.018) / 0.29,
            (qaPeakY - 0.475 + sin(uv.x * 8.0 + 0.8) * 0.016 + counterDrift) / 0.090);
        float2 qaPeakLobe = float2((uv.x - 0.57) / 0.23, (qaPeakY - 0.45 + counterDrift) / 0.105);
        float2 qaPeakMirrorCounter = float2(
            (qaMirrorX - 0.5 + sin(qaPeakY * 11.0 + time * 0.12) * 0.018) / 0.29,
            (qaPeakY - 0.475 + sin(qaMirrorX * 8.0 + 0.8) * 0.016 + counterDrift) / 0.090);
        float2 qaPeakMirrorLobe = float2((qaMirrorX - 0.57) / 0.23, (qaPeakY - 0.45 + counterDrift) / 0.105);
        float qaPeakProtection = (0.76 * exp(-dot(qaPeakCounter, qaPeakCounter)) +
            0.24 * exp(-dot(qaPeakLobe, qaPeakLobe)) +
            0.76 * exp(-dot(qaPeakMirrorCounter, qaPeakMirrorCounter)) +
            0.24 * exp(-dot(qaPeakMirrorLobe, qaPeakMirrorLobe))) * 0.5;
        float qaEndpointPeak = qaPeakOuter * (0.82 + 0.16 * qaPeakBlue) * (1.0 - qaPeakProtection * 0.32);
        float qaTravellingPeak = qaPeakOuter * 0.20 + qaPeakBody * 0.58 + qaPeakCore * 0.54;
        qaVisualMain *= mix(1.0, qaEndpointPeak / max(qaTravellingPeak, 0.000001), finishSync);
        darkResult = qaVisualMain;
    }
    darkResult += grain * mix(0.0010, 0.0035, grainMask) *
        (1.0 - completionBlackout) * darkCanvasReveal;
    blueDarkReference = clamp(blueDarkReference + grain * mix(0.0010, 0.0035, grainMask) *
        (1.0 - completionBlackout) * darkCanvasReveal, 0.0, 1.0);
    float3 finishedDark = clamp(darkResult, 0.0, 1.0);
    if (isBluePreset > 0.5 && themeStrength > 0.5) {
        finishedDark.b = qaNativeBlueCap(darkResult.b);
    }
    // White transmits the same density field. Channel-wise absorption gives
    // blue -> cyan -> white / orange -> yellow -> white continuously, rather
    // than painting a saturated band with separate hue and opacity masks.
    float3 blueTransmission = mix(referenceBlue, referenceBlueAccent, 0.65);
    float3 yellowTransmission = float3(yellowLightOrange.r,
        mix(yellowMidColor.g, yellowHotColor.g, 0.75),
        pow(yellowLightAccent.b, 2.5));
    float3 transmission = mix(blueTransmission, yellowTransmission, isYellowPreset);
    float3 matchingLight = pow(max(transmission, float3(0.0001)), float3(sharedLightField));
    lightResult = mix(lightResult, matchingLight, clamp(isBluePreset + isYellowPreset, 0.0, 1.0));
    result = mix(lightResult, finishedDark, themeStrength);

    // Explicit boundary states for the dark theme. These sit after all palette
    // effects, so a selected color can never replace the black canvas at rest.
    float darkTheme = step(0.5, themeStrength);
    float darkAtRest = 1.0 - smoothstep(0.001, 0.035, progress);
    result = mix(result, darkBase, darkTheme * darkAtRest);
    blueDarkReference = mix(blueDarkReference, darkBase, darkTheme * darkAtRest);

    // Purely visual history; no clock or field value feeds the progress mechanic.
    if (interactionFloatCount > 0) {
        float trail = interactionLightField(uv, safeSize.x / safeSize.y, interactionSegments, interactionFloatCount);
        float readability = 1.0 - 0.88 * counterProtection;
        // Exposure depends on local interaction accumulation, so a first pass
        // cannot start white merely because it crosses a bright progress band.
        float heat = trail;
        float brighter = 1.0 - exp(-max(heat - 0.35, 0.0) * 0.95);
        float excessHeat = max(heat - 1.45, 0.0);
        float exposure = 1.0 - exp(-excessHeat * excessHeat / 3.0);
        float3 trailColor;
        if (isYellowPreset > 0.5) {
            // Channel-wise exponential exposure used to push R and G towards
            // equality, leaving olive on black. Keep warm hue while light grows.
            float3 warm = darkTheme > 0.5
                ? mix(yellowDeepColor.rgb, min(yellowHotColor.rgb * 1.18, 1.0), brighter)
                : mix(yellowHotColor.rgb, yellowLightAccent, 0.48 + brighter * 0.52);
            float cream = smoothstep(0.70, 3.0, heat) * 0.75;
            if (darkTheme < 0.5) {
                // A broad orange interval separates yellow pigment from light,
                // making the trail readable even over a saturated yellow base.
                float orange = exp(-pow((heat - 0.85) / 0.90, 2.0)) *
                    (1.0 - exp(-heat * 2.0)) * 0.75;
                warm = mix(yellowLightAccent, yellowLightOrange, orange);
                cream = smoothstep(1.55, 3.50, heat) * 0.75;
                float accumulatedHeat = max(heat - 2.0, 0.0);
                exposure = 1.0 - exp(-accumulatedHeat * accumulatedHeat / 2.8);
            }
            warm = mix(warm, mix(yellowHotColor.rgb, white, 0.82), cream);
            trailColor = mix(warm, mix(yellowHotColor.rgb, white, 0.94), exposure);
        } else {
            // Reuse the cyan produced by the existing additive idle overlap.
            float3 overlapCyan = clamp(targetBlue + float3(0.14, 0.48, 1.0), 0.0, 1.0);
            float3 lightBlue = mix(targetBlue, mix(referenceCyan, overlapCyan, darkTheme), brighter);
            trailColor = mix(lightBlue, float3(0.91, 0.98, 1.0), exposure);
        }
        // Protect text through coverage, not heat: the mask must not turn a
        // hot white/cyan/cream trail into a different, muddy color at its edge.
        float opacity = (0.78 + 0.22 * exposure) * (1.0 - exp(-trail * 0.95)) * readability;
        if (darkTheme > 0.5) {
            float3 backdrop = result;
            result = 1.0 - (1.0 - result) * (1.0 - trailColor * opacity);
            if (isYellowPreset > 0.5) {
                // Same trail field, alpha and screen blending as Blue Dark;
                // only reduce color energy if the warm overlap is brighter.
                float3 blueTrail = mix(mix(float3(0.10, 0.55, 1.0),
                    float3(0.24, 1.0, 1.0), brighter), float3(0.91, 0.98, 1.0), exposure);
                float3 blueOverlap = 1.0 - (1.0 - blueDarkReference) * (1.0 - blueTrail * opacity);
                // Balance only added trail light: a history buffer must never
                // darken the untouched backdrop, even when its samples faded.
                result = backdrop + balanceYellowDarkLight(max(result - backdrop, 0.0),
                    max(blueOverlap - blueDarkReference, 0.0));
            }
        } else {
            // Keep the old Blue Light screen-pass character, driven by local
            // overlap rather than separate offset strokes. First passes stay colored.
            float pigmentOpacity = opacity * (0.76 + 0.24 * exposure);
            result = mix(result, trailColor, pigmentOpacity);
            float3 screenLight = isYellowPreset > 0.5
                ? mix(yellowLightAccent, white, 0.80)
                : float3(0.80, 0.9059, 1.0); // Original Blue Light screen color.
            result = 1.0 - (1.0 - result) * (1.0 - screenLight * exposure * opacity * 0.42);
        }
    }

    half4 output = half4(half3(clamp(result, 0.0, 1.0)), 1.0);
    if (themeStrength < 0.5 && idleActivity > 0.0) {
        output = blendLightIdle(output, idleWaveColor(idleDensity, 0.0, gradientColorIndex),
            contact, gradientColorIndex, transmission);
    }
    if (themeStrength > 0.5 && (isBluePreset + isYellowPreset) > 0.5 && idleActivity > 0.0) {
        output = blendDarkIdle(output, idleWaveColor(idleDensity, 1.0, gradientColorIndex),
            contact, gradientColorIndex);
    }
    return output;
}

// Mechanical projection of frozen Blue physical MAIN/W fields; no colour mapping.
float4 yellowReferenceContactFields(
    float2 position,
    half4 color,
    float2 size,
    float progress,
    float tapPulse,
    float2 tapPoint,
    float2 previousTouchPoint,
    float swipePulse,
    float swipeStrength,
    float time,
    float progressSpeed,
    float fillGain,
    float waveStrength,
    float waveSpread,
    float topBloom,
    float whiteCore,
    float blueDepth,
    float dragWave,
    float shockStrength,
    float shockInteraction,
    float shockTrail,
    float waveCount,
    float themeStrength,
    float gradientColorIndex,
    float idleActivity,
    float idleTime,
    device const float *interactionSegments,
    int interactionFloatCount
) {
    progress = clamp(progress, 0.0, 1.0);
    progressSpeed = clamp(progressSpeed, 0.0, 10.0);
    fillGain = clamp(fillGain, 0.0, 10.0);
    waveStrength = clamp(waveStrength, 0.0, 10.0);
    waveSpread = clamp(waveSpread, 0.0, 10.0);
    topBloom = clamp(topBloom, 0.0, 10.0);
    whiteCore = clamp(whiteCore, 0.0, 10.0);
    blueDepth = clamp(blueDepth, 0.0, 10.0);
    dragWave = clamp(dragWave, 0.0, 1.0);
    swipePulse = smootherLiquid(clamp(swipePulse, 0.0, 1.0));
    swipeStrength = clamp(swipeStrength, 0.0, 1.0);
    shockStrength = clamp(shockStrength, 0.0, 10.0);
    shockInteraction = clamp(shockInteraction, 0.0, 10.0);
    shockTrail = clamp(shockTrail, 0.0, 10.0);
    waveCount = clamp(round(waveCount), 0.0, 10.0);
    themeStrength = clamp(themeStrength, 0.0, 1.0);
    gradientColorIndex = clamp(round(gradientColorIndex), 0.0, 4.0);
    float isBluePreset = 1.0 - step(0.5, abs(gradientColorIndex));
    float isYellowPreset = 1.0 - step(0.5, abs(gradientColorIndex - 3.0));

    float2 design = float2(375.0, 812.0);
    float2 safeSize = float2(max(size.x, 1.0), max(size.y, 1.0));

    float2 p = float2(
        position.x / safeSize.x * design.x,
        position.y / safeSize.y * design.y
    );

    float2 uv = position / safeSize;

    float3 white = float3(1.0);

    // Blue gradient shares the light idle-wave palette: #1A8CFF.
    float3 cyan = float3(0.10, 0.55, 1.0);
    float3 aqua = float3(0.10, 0.55, 1.0);
    float3 blue = float3(0.10, 0.55, 1.0);
    float3 deepBlue = float3(0.10, 0.55, 1.0);
    float3 electric = float3(0.10, 0.55, 1.0);
    float3 targetBlue = float3(0.10, 0.55, 1.0);

    if (gradientColorIndex < 2.5 && gradientColorIndex > 1.5) {
        cyan = float3(0.62, 0.46, 1.0);
        aqua = float3(0.43, 0.28, 0.94);
        blue = float3(0.22, 0.12, 0.72);
        deepBlue = float3(0.09, 0.05, 0.34);
        electric = float3(0.82, 0.58, 1.0);
        targetBlue = float3(0.56, 0.42, 1.0);
    } else if (gradientColorIndex < 3.5 && gradientColorIndex > 2.5) {
        cyan = mix(yellowHotColor.rgb, white, 0.32);
        aqua = yellowHotColor.rgb;
        blue = yellowMidColor.rgb;
        deepBlue = yellowDeepColor.rgb;
        electric = yellowHotColor.rgb;
        targetBlue = yellowMidColor.rgb;
    } else if (gradientColorIndex > 3.5) {
        cyan = float3(1.0, 0.46, 0.68);
        aqua = float3(0.94, 0.26, 0.58);
        blue = float3(0.60, 0.14, 0.52);
        deepBlue = float3(0.26, 0.05, 0.20);
        electric = float3(1.0, 0.68, 0.88);
        targetBlue = float3(1.0, 0.42, 0.66);
    }

    float3 waveMid = mix(targetBlue, aqua, 0.24);
    float3 waveDeep = mix(deepBlue, targetBlue, 0.18);
    float3 waveGlass = mix(cyan, white, 0.68);
    float3 waveEdge = mix(electric, cyan, 0.36);

    // --------------------------------------------------
    // Idle shockwave
    // --------------------------------------------------

    float idleWaveActivity = smootherLiquid(swipeStrength);
    float idleWaveFade = mix(0.92, 0.78, smoothstep(0.92, 1.0, progress)) * idleWaveActivity;

    float idlePeriod = 3.0;
    float idleCycleRaw = fract(time / idlePeriod);
    float idleCycle = smootherLiquid(idleCycleRaw);

    float idleWaveVisibility =
        smoothstep(0.02, 0.11, idleCycleRaw) *
        (1.0 - smoothstep(0.88, 1.0, idleCycleRaw)) *
        idleWaveFade;

    float idleWaveY = mix(-110.0, 925.0, idleCycle);

    float idleWidth = mix(72.0, 420.0, idleCycle);
    float idleThickness = mix(19.0, 42.0, idleCycle);

    float idleDx = p.x - 187.5;

    float idleArcY =
        idleWaveY +
        (idleDx * idleDx) / max(idleWidth * 1.72, 1.0);

    float idleWaveDist = p.y - idleArcY;

    float idleMainWave =
        exp(-pow(idleWaveDist / idleThickness, 2.0)) *
        exp(-pow(idleDx / idleWidth, 2.0));

    float idleSecondWave =
        exp(-pow((idleWaveDist + 72.0) / (idleThickness * 1.35), 2.0)) *
        exp(-pow(idleDx / (idleWidth * 1.18), 2.0)) *
        0.42;

    float idleThirdWave =
        exp(-pow((idleWaveDist + 132.0) / (idleThickness * 1.75), 2.0)) *
        exp(-pow(idleDx / (idleWidth * 1.32), 2.0)) *
        0.20;

    float idleConeGlow =
        exp(-pow((p.y - idleWaveY) / 180.0, 2.0)) *
        exp(-pow(idleDx / max(idleWidth * 1.18, 1.0), 2.0)) *
        0.18;

    float idleWaveEnergy =
        clamp(
            idleMainWave +
            idleSecondWave +
            idleThirdWave +
            idleConeGlow,
            0.0,
            1.0
        ) *
        idleWaveVisibility *
        waveStrength;

    // --------------------------------------------------
    // Continuous upward motion
    // --------------------------------------------------

    // Use the original gradient motion curve for every palette and theme.
    float baseRise = progress * (0.42 + 0.58 * progress);
    float smoothRise = smootherLiquid(progress);
    float rise = mix(baseRise, smoothRise, 0.34);
    float finalLiftBoost = segmentEase(progress, 0.74, 1.00);
    float lateLiftBoost = segmentEase(progress, 0.88, 1.00);

    float circleGrowth = smootherLiquid(progress);

    float2 center = float2(187.5, 406.0);
    float circleAppear = smoothstep(0.025, 0.12, progress * (0.70 + progressSpeed * 3.0));
    float circleRadius = mix(74.0, 178.0, circleGrowth) * mix(0.92, 1.08, waveSpread - 0.5);

    float bottomCleanProgress = segmentEase(progress, 0.42, 1.00);
    float topCapProgress = segmentEase(progress, 0.82, 1.00);
    float topReservoirProgress = segmentEase(progress, 0.58, 1.00);

    float completionBloom = segmentEase(progress, 0.96, 1.00);
    float completed = smoothstep(0.995, 1.0, progress);

    float globalLift =
        mix(0.0, 1380.0, rise) +
        260.0 * finalLiftBoost +
        540.0 * lateLiftBoost;

    float initialDrop = 350.0 * (1.0 - rise);

    float finalBlur = segmentEase(progress, 0.70, 1.00);
    float completionMistProgress = segmentEase(progress, 0.84, 1.00);

    float completionFlash = 0.0;

    // Позже начинаем растворять градиент.
    float lateTransparency = segmentEase(progress, 0.90, 1.00);

    float mainFinalFade = mix(1.0, 0.62, lateTransparency);
    float rimFinalFade = mix(1.0, 0.44, lateTransparency);
    float finalFade = mainFinalFade;

    // Делаем градиент более вытянутым в первой половине
    // и чуть компактнее к финалу, но мягче, чем раньше.
    float shrinkAfterHalf = segmentEase(progress, 0.64, 1.00);

    float stretchFactor = mix(
        0.30,
        0.64,
        shrinkAfterHalf
    );

    float2 pStretched = float2(
        p.x,
        406.0 + (p.y - 406.0) * stretchFactor
    );

    // --------------------------------------------------
    // Bottom clearing mask
    // --------------------------------------------------

    float clearEdgeY = mix(1060.0, 225.0, bottomCleanProgress);
    float clearFeather = mix(205.0, 360.0, bottomCleanProgress);

    float clearWave =
        24.0 * sin(p.x * 0.018 + time * 0.50 + rise * 2.0) +
        15.0 * sin(p.x * 0.041 - time * 0.36 + rise * 4.0) +
        8.0  * sin((p.x + p.y) * 0.020 + time * 0.22);

    float bottomClear = smoothstep(
        clearEdgeY - clearFeather,
        clearEdgeY + clearFeather,
        p.y + clearWave
    );

    float bottomOnly = smoothstep(0.38, 1.0, uv.y);
    bottomClear *= bottomOnly;

    // --------------------------------------------------
    // Organic liquid reveal edge
    // --------------------------------------------------

    float revealEdgeY = mix(910.0, -1450.0, rise);

    // Граница сверху и снизу мягче.
    float revealFeather = mix(
        140.0,
        360.0 + 340.0 * finalBlur,
        rise
    );

    float revealWaveA =
        34.0 * sin(p.x * 0.013 + time * 0.42 + rise * 2.1);

    float revealWaveB =
        18.0 * sin(p.x * 0.031 - time * 0.56 + rise * 3.4);

    float revealWaveC =
        9.0 * sin(p.x * 0.071 + time * 0.33 - rise * 1.6);

    float domainWarp =
        13.0 * sin((p.x + p.y) * 0.018 + time * 0.28) +
        7.0  * sin((p.x - p.y) * 0.026 - time * 0.31);

    float blob1 =
        42.0 *
        exp(-pow((p.x - 86.0) / 72.0, 2.0)) *
        sin(time * 0.37 + rise * 2.4);

    float blob2 =
        36.0 *
        exp(-pow((p.x - 206.0) / 88.0, 2.0)) *
        sin(time * 0.29 + 1.7 + rise * 2.9);

    float blob3 =
        30.0 *
        exp(-pow((p.x - 318.0) / 76.0, 2.0)) *
        sin(time * 0.34 + 3.1 + rise * 2.2);

    float revealWave =
        revealWaveA +
        revealWaveB +
        revealWaveC +
        domainWarp +
        blob1 +
        blob2 +
        blob3;

    float edgeChaos = mix(
        0.72,
        1.0,
        smoothstep(0.12, 0.65, progress)
    );

    float liquidEdgeY = revealEdgeY - revealWave * edgeChaos;

    float bottomReveal = smoothstep(
        liquidEdgeY - revealFeather,
        liquidEdgeY + revealFeather,
        p.y
    );

    float revealEdgeDist = abs(p.y - liquidEdgeY);

    float revealEdgeGlow =
        exp(-revealEdgeDist / 38.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.22 *
        finalFade;

    float tensionCore =
        exp(-revealEdgeDist / 15.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.18 *
        finalFade;

    float tensionShadow =
        exp(-abs((p.y - liquidEdgeY) - 26.0) / 28.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.10 *
        finalFade;

    float liquidRimLine =
        exp(-revealEdgeDist / 8.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        finalFade;

    // --------------------------------------------------
    // Idle / completion breathing
    // --------------------------------------------------

    float idleEnergy = 1.0 - smoothstep(0.02, 0.22, progress);

    float idleVertical =
        idleEnergy *
        (
            18.0 * sin(time * 0.46) +
            9.0  * sin(time * 0.83)
        );

    float horizontalDrift = 0.0;

    float baseShiftY = globalLift - initialDrop + idleVertical;

    float2 pGlobal = pStretched + float2(horizontalDrift, baseShiftY);

    // --------------------------------------------------
    // Refraction + tap push + flow pull
    // --------------------------------------------------

    float lensDist = distance(p, center);

    float refractionZone =
        exp(-pow((lensDist - circleRadius) / 42.0, 2.0)) *
        circleAppear;

    float2 refractDir = normalize(p - center + float2(0.001, 0.001));
    float2 refractionWarp = refractDir * refractionZone * 10.0;

    float2 tapPxDesign = float2(
        tapPoint.x * design.x,
        tapPoint.y * design.y
    );

    float2 touchDeltaDesign = p - tapPxDesign;
    float tapDistDesign = length(touchDeltaDesign);
    float shockActive = smoothstep(0.04, 1.0, dragWave) * waveStrength * shockStrength;
    float shockAge = clamp((1.0 - tapPulse) / max(shockTrail, 0.30), 0.0, 1.0);
    float shockSide = touchDeltaDesign.x >= 0.0 ? 1.0 : -1.0;
    float travelingPhase = time * (3.8 + 1.4 * shockInteraction);

    float rippleAmplitude = 38.0 * shockStrength;
    float rippleEnvelope = smoothstep(0.01, 0.46, dragWave);
    float waveProgress = clamp(1.0 - tapPulse, 0.0, 1.0);
    float safeWaveSpread = max(waveSpread, 0.001);
    float safeShockTrail = max(shockTrail, 0.001);
    float waveFrontRadius = 24.0 + waveProgress * 250.0 * shockTrail;
    float ringSpacing = 46.0 * waveSpread;
    float ringWidth = max(25.0 * waveSpread, 1.0);
    float finiteRipple = 0.0;

    // Fixed upper bound keeps this predictable on the GPU while allowing 0...10 waves.
    for (int waveIndex = 0; waveIndex < 10; waveIndex++) {
        float index = float(waveIndex);
        float ringRadius = waveFrontRadius - ringSpacing * index;
        float ringEnabled = step(index + 0.5, waveCount) * smoothstep(2.0, 16.0, ringRadius);
        float ring =
            exp(-pow((tapDistDesign - ringRadius) / ringWidth, 2.0)) -
            0.34 * exp(-pow((tapDistDesign - ringRadius + ringWidth * 0.72) / (ringWidth * 1.28), 2.0));
        finiteRipple += ring * ringEnabled * (1.0 - index * 0.075);
    }
    float rippleFade = exp(-waveProgress * 1.35 / max(shockTrail, 0.30));
    float rippleAmount =
        rippleAmplitude *
        finiteRipple *
        rippleEnvelope *
        rippleFade;
    float2 rippleDir = normalize(touchDeltaDesign + float2(0.001, 0.001));
    float2 shadertoyRippleWarp = rippleAmount * rippleDir;
    float shadertoyRippleLight = rippleAmount / max(rippleAmplitude, 1.0);

    // A continuous, soft water response that remains visible while the finger moves.
    float localWaterPressure =
        exp(-pow(tapDistDesign / max(92.0 * waveSpread, 1.0), 2.0)) *
        rippleEnvelope;
    float localWaterWave =
        finiteRipple *
        rippleEnvelope *
        rippleFade;
    float2 localWaterWarp =
        rippleDir *
        (
            localWaterWave * (5.2 + 2.0 * shockStrength) +
            localWaterPressure * 2.8
        );

    float frontNoise =
        12.0 * sin(p.y * 0.018 + time * 2.1) +
        7.0 * sin(p.y * 0.034 - time * 1.4);

    float frontDist = abs(p.x - tapPxDesign.x + frontNoise);
    float primaryFront =
        exp(-pow(frontDist / max(mix(46.0, 82.0, waveSpread), 1.0), 2.0)) *
        shockActive;

    float secondaryFront =
        exp(-pow((frontDist - mix(42.0, 128.0 * shockTrail, shockAge)) / max(mix(104.0, 162.0, waveSpread), 1.0), 2.0)) *
        shockActive *
        (0.72 - 0.26 * shockAge);

    float screenRing =
        exp(-pow((tapDistDesign - mix(42.0, 310.0 * shockTrail, shockAge)) / max(172.0 * safeWaveSpread, 1.0), 2.0)) *
        shockActive *
        (0.38 + 0.62 * tapPulse);

    float diagonalAxis =
        dot(touchDeltaDesign, normalize(float2(0.58 * shockSide, 0.82))) +
        18.0 * sin(p.y * 0.020 + time * 1.9);

    float diagonalWake =
        exp(-pow(diagonalAxis / max(150.0 * safeWaveSpread, 1.0), 2.0)) *
        exp(-pow(touchDeltaDesign.x / max(420.0 * safeShockTrail, 1.0), 2.0)) *
        shockActive *
        (0.46 + 0.36 * tapPulse);

    float causticPulse =
        (0.5 + 0.5 * sin(tapDistDesign * 0.050 - travelingPhase * 1.7 + shockAge * 8.2)) *
        screenRing *
        shockActive *
        (0.64 + 0.36 * shockInteraction);

    float crossingFront =
        primaryFront * secondaryFront +
        screenRing * diagonalWake;

    float interferenceField =
        (0.5 + 0.5 * sin(tapDistDesign * 0.042 - travelingPhase * 1.35)) *
        (0.5 + 0.5 * sin((touchDeltaDesign.x * shockSide + touchDeltaDesign.y * 0.54) * 0.034 + travelingPhase)) *
        shockActive *
        shockInteraction;

    float selfCoupling =
        clamp(crossingFront * (0.72 + 0.46 * shockInteraction) + interferenceField * 0.44, 0.0, 1.8);

    float compositeShock =
        primaryFront * 0.54 +
        secondaryFront * 0.38 +
        screenRing * 0.34 +
        diagonalWake * 0.28 +
        causticPulse * 0.16 +
        selfCoupling * 0.30;

    float touchPush =
        exp(-pow(tapDistDesign * 0.0052, 2.0)) *
        tapPulse *
        shockActive;

    float2 tapDir = normalize(p - tapPxDesign + float2(0.001, 0.001));
    float2 frontDir = normalize(float2(shockSide, 0.16 * sin(p.y * 0.021 + time * 1.7)));
    float2 diagonalDir = normalize(float2(0.46 * shockSide, 0.72));
    float2 tapWarp =
        shadertoyRippleWarp * (0.58 + 0.16 * waveStrength) +
        localWaterWarp +
        tapDir * touchPush * 6.0 +
        frontDir * compositeShock * 7.0 +
        diagonalDir * (diagonalWake + selfCoupling * 0.38) * 3.5 +
        float2(0.0, -1.0) * (causticPulse + interferenceField * 0.24) * 2.0;

    float centerPull =
        exp(-pow((p.x - 187.5) / 140.0, 2.0));

    float verticalFlowPull =
        centerPull *
        segmentEase(progress, 0.18, 0.92) *
        34.0 *
        waveStrength;

    float2 flowWarp = refractionWarp + tapWarp;
    float2 liquidFlowWarp = float2(0.0, flowWarp.y);

    pGlobal += liquidFlowWarp * 0.82;
    pGlobal.y += verticalFlowPull;

    float backSpeed = mix(0.70, 0.78, completed);
    float mainSpeed = mix(1.00, 0.92, completed);
    float rimSpeed = mix(1.30, 1.10, completed);

    float2 pShape1Back = pStretched + float2(horizontalDrift * 0.30, baseShiftY * backSpeed * 0.82);
    float2 pShape2Back = pStretched + float2(horizontalDrift * 0.40, baseShiftY * backSpeed * 0.96);
    float2 pWave1Back  = pStretched + float2(horizontalDrift * 0.48, baseShiftY * backSpeed * 0.92);
    float2 pWave2Back  = pStretched + float2(horizontalDrift * 0.50, baseShiftY * backSpeed * 1.04);

    float2 pShape1 = pStretched + float2(horizontalDrift * 0.55, baseShiftY * mainSpeed * 0.95);
    float2 pShape2 = pStretched + float2(horizontalDrift * 0.80, baseShiftY * mainSpeed * 1.12);
    float2 pBgUp   = pStretched + float2(horizontalDrift * 0.30, baseShiftY * mainSpeed * 0.34);
    float2 pWave1  = pStretched + float2(horizontalDrift * 1.05, baseShiftY * mainSpeed * 1.00);
    float2 pWave2  = pStretched + float2(horizontalDrift * 0.95, baseShiftY * mainSpeed * 1.16);

    float2 pRim1 = pStretched + float2(horizontalDrift * 1.28, baseShiftY * rimSpeed * 1.22);
    float2 pRim2 = pStretched + float2(horizontalDrift * 1.10, baseShiftY * rimSpeed * 1.30);

    pShape1Back += liquidFlowWarp * 0.18;
    pShape2Back += liquidFlowWarp * 0.24;
    pWave1Back += liquidFlowWarp * 0.28;
    pWave2Back += liquidFlowWarp * 0.30;

    pShape1 += liquidFlowWarp * 0.50;
    pShape2 += liquidFlowWarp * 0.58;
    pWave1 += liquidFlowWarp * 0.72;
    pWave2 += liquidFlowWarp * 0.68;

    pRim1 += liquidFlowWarp * 0.95;
    pRim2 += liquidFlowWarp * 0.88;

    float2 deepWarp = float2(
        0.0,
        cos(p.x * 0.010 + time * 0.32) * 8.0
    );

    pShape1Back += deepWarp * 0.22;
    pShape2Back += deepWarp * 0.28;
    pWave1Back += deepWarp * 0.34;
    pWave2Back += deepWarp * 0.36;

    pShape1 += deepWarp * 0.52;
    pShape2 += deepWarp * 0.60;
    pWave1 += deepWarp * 0.78;
    pWave2 += deepWarp * 0.72;

    pRim1 += deepWarp * 1.05;
    pRim2 += deepWarp * 0.96;

    // --------------------------------------------------
    // States from specs
    // --------------------------------------------------

    LayerState anim_wave_1 = makeState(
        float2(-38.0, 647.0),
        float2(-238.0, 476.0),
        float2(-121.0, 411.0),
        float2(-117.0, 151.0),

        float2(454.0, 300.0),
        float2(851.0, 562.0),
        float2(619.0, 409.0),
        float2(611.0, 405.0),

        1.00, 0.70, 1.00, 1.00,
        64.0, 64.0, 120.0, 160.0,
        progress
    );

    LayerState anim_wave_2 = makeState(
        float2(-99.0, 364.0),
        float2(-99.0, 442.0),
        float2(-218.0, 197.0),
        float2(-106.0, -107.0),

        float2(556.0, 298.0),
        float2(573.0, 307.0),
        float2(875.0, 466.0),
        float2(589.0, 316.0),

        1.00, 1.00, 1.00, 1.00,
        128.0, 160.0, 120.0, 88.0,
        progress
    );

    LayerState bg_up_02 = makeState(
        float2(-50.0, 37.0),
        float2(-32.0, 37.0),
        float2(-50.0, 37.0),
        float2(-50.0, 37.0),

        float2(475.0, 787.0),
        float2(440.0, 787.0),
        float2(475.0, 787.0),
        float2(475.0, 787.0),

        0.10, 1.00, 1.00, 1.00,
        64.0, 120.0, 64.0, 64.0,
        progress
    );

    LayerState shape_2 = makeState(
        float2(0.0, 705.0),
        float2(-44.0, 856.0),
        float2(-67.0, 663.0),
        float2(-50.0, 702.0),

        float2(375.0, 251.0),
        float2(463.0, 309.0),
        float2(509.0, 340.0),
        float2(475.0, 317.0),

        0.60, 0.70, 0.20, 1.00,
        88.0, 88.0, 88.0, 88.0,
        progress
    );

    LayerState shape_1 = makeState(
        float2(-50.0, 308.0),
        float2(-24.0, 351.0),
        float2(11.0, 78.0),
        float2(-50.0, 308.0),

        float2(475.0, 787.0),
        float2(423.0, 701.0),
        float2(353.0, 585.0),
        float2(475.0, 787.0),

        1.00, 1.00, 0.40, 1.00,
        64.0, 64.0, 146.0, 65.0,
        progress
    );

    // --------------------------------------------------
    // Back liquid layer
    // --------------------------------------------------

    float backShape1 = blueTrapField(
        pShape1Back,
        shape_1,
        87.3259 / 475.0,
        379.735 / 475.0,
        0.0,
        1.0,
        709.291 / 787.0,
        17.4917 / 787.0,
        0.72 * blueDepth
    );

    float backShape2 = blueTrapField(
        pShape2Back,
        shape_2,
        68.9415 / 375.0,
        299.791 / 375.0,
        0.0,
        1.0,
        226.216 / 251.0,
        5.57866 / 251.0,
        0.62 * blueDepth
    );

    float backWave1 = blueTrapField(
        pWave1Back,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        0.72 * blueDepth
    );

    float backWave2 = blueTrapField(
        pWave2Back,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        0.78 * blueDepth
    );

    float backMass = backShape1 + backShape2 + backWave1 + backWave2;
    float backAlpha = 1.0 - exp(-backMass * 0.86);
    backAlpha = clamp(backAlpha * bottomReveal * finalFade, 0.0, 1.0);

    // --------------------------------------------------
    // Main liquid layer
    // --------------------------------------------------

    float shape1Field = blueTrapField(
        pShape1,
        shape_1,
        87.3259 / 475.0,
        379.735 / 475.0,
        0.0,
        1.0,
        709.291 / 787.0,
        17.4917 / 787.0,
        1.08 * blueDepth
    );

    float shape2Field = blueTrapField(
        pShape2,
        shape_2,
        68.9415 / 375.0,
        299.791 / 375.0,
        0.0,
        1.0,
        226.216 / 251.0,
        5.57866 / 251.0,
        0.96 * blueDepth
    );

    float bgUpField = blueTrapField(
        pBgUp,
        bg_up_02,
        0.0,
        1.0,
        87.3259 / 475.0,
        379.735 / 475.0,
        77.709 / 787.0,
        769.508 / 787.0,
        1.03 * blueDepth
    );

    float wave2Field = blueTrapField(
        pWave2,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        1.25 * blueDepth
    );

    float wave1Field = blueTrapField(
        pWave1,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        1.18 * blueDepth
    );

    float svgBlueMass =
        shape1Field +
        shape2Field +
        bgUpField +
        wave1Field +
        wave2Field;

    float mainAlpha = 1.0 - exp(-svgBlueMass * 1.28);
    mainAlpha = clamp(mainAlpha * bottomReveal * finalFade, 0.0, 1.0);

    // --------------------------------------------------
    // Front rim liquid layer
    // --------------------------------------------------

    float rimWave1 = blueTrapField(
        pRim1,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        1.05
    );

    float rimWave2 = blueTrapField(
        pRim2,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        0.98
    );

    float rimAlpha = clamp((rimWave1 + rimWave2) * bottomReveal * rimFinalFade, 0.0, 1.0);
    rimAlpha = smoothstep(0.22, 0.88, rimAlpha);

    float massBreath =
        1.0 +
        0.025 * sin(time * 0.72) +
        0.014 * sin(time * 1.13);

    mainAlpha = clamp(mainAlpha * massBreath, 0.0, 1.0);
    backAlpha = clamp(backAlpha * (1.0 + 0.018 * sin(time * 0.55 + 1.2)), 0.0, 1.0);
    rimAlpha = clamp(rimAlpha * (1.0 + 0.016 * sin(time * 0.80 + 2.1)), 0.0, 1.0);

    float lateAlphaFade = lateTransparency;

    mainAlpha *= mix(1.0, 0.54, lateAlphaFade);
    backAlpha *= mix(1.0, 0.48, lateAlphaFade);
    rimAlpha *= mix(1.0, 0.36, lateAlphaFade);

    // --------------------------------------------------
    // Liquid color model
    // --------------------------------------------------

    float flow =
        0.023 * sin(pGlobal.x * 0.030 + time * 0.75 + rise * 2.2) +
        0.016 * sin(pGlobal.x * 0.070 - time * 0.55 + rise * 3.7) +
        0.011 * sin((pGlobal.x + pGlobal.y) * 0.035 + time * 0.45);

    float liquidY = clamp(
        uv.y * 0.74 + 0.14 + flow - rise * 0.14,
        0.0,
        1.0
    );

    // --------------------------------------------------
    // Delayed blue color ramp
    // --------------------------------------------------

    float blueEmergence = segmentEase(progress, 0.40, 0.56);
    float deepBlueEmergence = segmentEase(progress, 0.54, 0.78);
    float earlySoftness = 1.0 - blueEmergence;

    float targetBluePhase =
        segmentEase(progress, 0.50, 0.62) *
        (1.0 - segmentEase(progress, 0.80, 0.94));

    float3 softAqua = mix(
        cyan,
        aqua,
        0.62
    );

    float3 softBlue = mix(
        aqua,
        targetBlue,
        0.46
    );

    float3 backColor = mix(
        softAqua,
        softBlue,
        smoothstep(0.16, 0.88, liquidY) * blueEmergence
    );

    backColor = mix(
        backColor,
        targetBlue,
        targetBluePhase * 0.72
    );

    backColor = mix(
        backColor,
        mix(targetBlue, deepBlue, 0.26),
        smoothstep(0.78, 1.0, liquidY) * deepBlueEmergence * 0.38
    );

    float3 mainColor = mix(
        cyan,
        aqua,
        smoothstep(0.02, 0.48, liquidY)
    );

    mainColor = mix(
        mainColor,
        softBlue,
        smoothstep(0.34, 0.78, liquidY) * blueEmergence
    );

    mainColor = mix(
        mainColor,
        targetBlue,
        smoothstep(0.44, 0.88, liquidY) * blueEmergence * 0.78
    );

    mainColor = mix(
        mainColor,
        targetBlue,
        targetBluePhase * 0.86
    );

    mainColor = mix(
        mainColor,
        mix(targetBlue, deepBlue, 0.22),
        smoothstep(0.78, 1.0, liquidY) * deepBlueEmergence * 0.42
    );

    mainColor = mix(
        mainColor,
        mix(cyan, aqua, 0.54),
        earlySoftness * 0.38
    );

    backColor = mix(
        backColor,
        mix(cyan, aqua, 0.46),
        earlySoftness * 0.32
    );

    float3 rimColor = mix(
        electric,
        cyan,
        smoothstep(0.0, 1.0, liquidY)
    );

    rimColor = mix(
        rimColor,
        mix(cyan, aqua, 0.52),
        earlySoftness * 0.28
    );

    rimColor = mix(
        rimColor,
        mix(targetBlue, cyan, 0.22),
        targetBluePhase * 0.56
    );

    float3 result = white;

    result = plusDarkerApprox(
        result,
        backColor,
        backAlpha * 0.72
    );

    result = plusDarkerApprox(
        result,
        mainColor,
        mainAlpha
    );

    result += rimColor * rimAlpha * 0.035;

    // --------------------------------------------------
    // Idle wave render
    // --------------------------------------------------

    float idleLuminanceBefore = dot(result, float3(0.299, 0.587, 0.114));

    float idleBlueOnWhite =
        idleWaveEnergy *
        smoothstep(0.56, 1.0, idleLuminanceBefore);

    float idleWhiteOnBlue =
        idleWaveEnergy *
        (1.0 - smoothstep(0.35, 0.88, idleLuminanceBefore));

    result = mix(
        result,
        min(result, waveMid),
        idleBlueOnWhite * 0.22
    );

    result += idleBlueOnWhite * waveDeep * 0.08;
    result += idleWhiteOnBlue * waveGlass * 0.14;
    result += idleWaveEnergy * waveEdge * 0.10;

    // --------------------------------------------------
    // Organic reveal edge glow + surface tension
    // --------------------------------------------------

    result += revealEdgeGlow * float3(0.25, 0.82, 1.0);
    result += revealEdgeGlow * float3(0.75, 1.00, 1.0) * 0.32;

    result += tensionCore * float3(0.56, 1.00, 1.0) * 0.34;

    result += liquidRimLine * float3(0.75, 1.0, 1.0) * 0.18;
    result += liquidRimLine * float3(0.10, 0.55, 1.0) * 0.08;

    result = plusDarkerApprox(
        result,
        deepBlue,
        tensionShadow * 0.18
    );

    // --------------------------------------------------
    // Surface glow
    // --------------------------------------------------

    float liquidAlpha = clamp(mainAlpha + backAlpha * 0.52, 0.0, 1.0);
    float surfaceEnergy = liquidAlpha * (1.0 - liquidAlpha);

    float surfaceGlow = smoothstep(0.08, 0.25, surfaceEnergy);

    result += surfaceGlow * float3(0.10, 0.56, 1.0) * 0.10 * finalFade;
    result += surfaceGlow * float3(0.56, 1.00, 1.0) * 0.045 * finalFade;

    // --------------------------------------------------
    // Bottom clearing
    // --------------------------------------------------

    float bottomClearPower = mix(
        0.38,
        0.68,
        bottomCleanProgress
    );

    result = plusLighterApprox(
        result,
        white,
        min(bottomClear * bottomClearPower, 0.68)
    );

    liquidAlpha *= (1.0 - bottomClear * 0.82);

    // --------------------------------------------------
    // Central white glass lens
    // --------------------------------------------------

    float circleSoftness = mix(
        38.0,
        92.0,
        circleGrowth
    );

    float angle = atan2(
        p.y - center.y,
        p.x - center.x
    );

    float circleNoiseFade = 1.0 - segmentEase(progress, 0.88, 1.00);

    float circleNoise =
        (
            4.2 * sin(angle * 3.0 + time * 0.50) +
            2.6 * sin(angle * 7.0 - time * 0.38)
        ) * circleNoiseFade;

    float circleDist =
        distance(p, center) -
        circleRadius +
        circleNoise;

    float circleFill = 1.0 - smoothstep(
        -circleSoftness * 0.52,
        circleSoftness,
        circleDist
    );

    float circleVisibility = mix(
        0.68,
        0.98,
        smoothstep(0.0, 0.75, progress)
    );

    float visibleCircleFill = circleFill * circleAppear;

    result += visibleCircleFill * circleVisibility * float3(0.12, 0.74, 1.0) * 0.030;

    float circleEdge = exp(-abs(circleDist) / 30.0);
    float tightCircleRim = exp(-abs(circleDist) / 10.0);

    float innerRim = circleEdge * visibleCircleFill * 0.20;

    result += innerRim * float3(0.35, 0.88, 1.0);

    float lensLowerShadow =
        visibleCircleFill *
        smoothstep(center.y - circleRadius * 0.10, center.y + circleRadius * 0.72, p.y) *
        0.055;

    result = mix(
        result,
        result * float3(0.965, 0.985, 1.0),
        lensLowerShadow
    );

    float contactGlow =
        circleEdge *
        liquidAlpha *
        circleAppear *
        (1.0 - circleFill * 0.38);

    float contactTightRim =
        tightCircleRim *
        liquidAlpha *
        circleAppear *
        (1.0 - circleFill * 0.22);

    float magneticPull = segmentEase(progress, 0.35, 0.85);

    float chromaticEdge =
        tightCircleRim *
        liquidAlpha *
        circleAppear *
        (0.35 + 0.65 * magneticPull);

    // Лёгкая хроматическая аберрация при столкновении с центральной маской.
    float2 dirFromCenter = normalize(p - center + float2(0.0001, 0.0001));
    float2 chromaAxis = normalize(float2(0.86, -0.34));

    float chromaDot = dot(dirFromCenter, chromaAxis);
    float redSide = smoothstep(-0.15, 1.0, chromaDot);
    float cyanSide = smoothstep(-0.15, 1.0, -chromaDot);

    result.r += chromaticEdge * redSide * 0.010 * finalFade;
    result.g += chromaticEdge * cyanSide * 0.010 * finalFade;
    result.b += chromaticEdge * cyanSide * 0.022 * finalFade;

    result += contactGlow * float3(0.12, 0.68, 1.0) * (0.76 + magneticPull * 0.18) * finalFade;
    result += contactGlow * float3(0.68, 1.00, 1.0) * (0.30 + magneticPull * 0.12) * finalFade;
    result += contactTightRim * float3(0.72, 1.00, 1.0) * (0.22 + magneticPull * 0.10) * finalFade;

    float innerHalo = exp(
        -max(distance(p, center) - circleRadius * 0.54, 0.0) / 78.0
    );

    result = mix(
        result,
        white,
        innerHalo * 0.11 * circleVisibility * circleAppear
    );

    // --------------------------------------------------
    // Tap blob / residual trail
    // --------------------------------------------------

    float2 tapPx = tapPoint * size;
    float tapDist = distance(position, tapPx);

    float tapTrail =
        exp(-pow(tapDist * 0.010, 2.0)) *
        tapPulse *
        mainAlpha *
        0.10;

    float tapBlobNoise =
        sin(position.x * 0.035 + time * 1.8) *
        sin(position.y * 0.026 - time * 1.3);

    tapTrail *= smoothstep(-0.15, 0.75, tapBlobNoise);

    result += tapTrail * white * finalFade;

    float screenTrailNoise =
        20.0 * sin(uv.y * 13.0 + time * 1.85) +
        12.0 * sin(uv.y * 27.0 - time * 1.10);

    float2 touchDeltaPx = position - tapPx;
    float touchSide = touchDeltaPx.x >= 0.0 ? 1.0 : -1.0;
    float visualShock = dragWave * shockStrength;
    float screenTrailDist = abs(touchDeltaPx.x + screenTrailNoise);
    float screenTrail =
        exp(-pow(screenTrailDist / max(62.0 * waveSpread * shockTrail, 1.0), 2.0)) *
        visualShock *
        mainAlpha *
        finalFade *
        0.22;

    float secondaryTrail =
        exp(-pow((screenTrailDist - mix(70.0, 178.0 * shockTrail, 1.0 - tapPulse)) / max(104.0 * waveSpread, 1.0), 2.0)) *
        visualShock *
        (0.64 + 0.36 * tapPulse) *
        mainAlpha *
        finalFade *
        0.20;

    float diagonalTrailAxis =
        dot(touchDeltaPx, normalize(float2(0.55 * touchSide, 0.83))) +
        22.0 * sin(uv.y * 16.0 + time * 1.6);

    float diagonalTrail =
        exp(-pow(diagonalTrailAxis / max(170.0 * waveSpread, 1.0), 2.0)) *
        exp(-pow(touchDeltaPx.x / max(size.x * 0.82 * shockTrail, 1.0), 2.0)) *
        visualShock *
        mainAlpha *
        finalFade *
        0.18;

    float screenRipple =
        exp(-pow((tapDist - mix(96.0, max(size.x, size.y) * 0.76 * shockTrail, 1.0 - tapPulse)) / max(124.0 * waveSpread, 1.0), 2.0)) *
        visualShock *
        (0.35 + 0.65 * tapPulse) *
        mainAlpha *
        finalFade;

    float causticLines =
        (0.5 + 0.5 * sin(tapDist * 0.062 - time * (6.2 + 1.8 * shockInteraction) + (1.0 - tapPulse) * 7.8)) *
        screenRipple *
        visualShock *
        (0.62 + 0.38 * shockInteraction);

    float wakeCrossing =
        (screenTrail * secondaryTrail + diagonalTrail * screenRipple) *
        (0.76 + 0.44 * shockInteraction);

    float wakeInterference =
        (0.5 + 0.5 * sin(tapDist * 0.040 - time * 5.1)) *
        (0.5 + 0.5 * sin((touchDeltaPx.x * touchSide + touchDeltaPx.y * 0.42) * 0.032 + time * 4.2)) *
        visualShock *
        shockInteraction *
        mainAlpha *
        finalFade;

    float compositeWake =
        screenTrail * 0.48 +
        secondaryTrail * 0.36 +
        diagonalTrail * 0.30 +
        screenRipple * 0.28 +
        causticLines * 0.18 +
        wakeCrossing * 0.42 +
        wakeInterference * 0.16;

    result += screenTrail * white * 0.040;
    result += secondaryTrail * white * 0.032;
    result += diagonalTrail * white * 0.034;
    result += screenRipple * white * 0.044;
    result += causticLines * white * 0.026;
    result += wakeCrossing * white * 0.035;
    result += wakeInterference * white * 0.024;

    // --------------------------------------------------
    // Top reservoir + cinematic finish
    // --------------------------------------------------

    float3 stableFinishColor = mix(
        targetBlue,
        cyan,
        0.18
    );

    float3 initialBottomLikeColor = stableFinishColor;

    float topBreath =
        1.0 +
        completed *
        (
            0.08 * sin(time * 1.55) +
            0.035 * sin(time * 2.25)
        );

    float finalCoreSoft = 1.0 - 0.50 * finalBlur;
    float finalMistBoost = 1.0 + 1.25 * finalBlur;

    float topReservoir =
        exp(-uv.y * 3.20) *
        topReservoirProgress *
        0.38 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topReservoirCore =
        exp(-uv.y * 7.00) *
        topReservoirProgress *
        0.30 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topReservoirGlow =
        exp(-pow((uv.y - 0.125) / 0.26, 2.0)) *
        topReservoirProgress *
        0.13 *
        topBreath *
        finalFade *
        finalMistBoost;

    result = plusDarkerApprox(
        result,
        initialBottomLikeColor,
        topReservoir
    );

    result = plusDarkerApprox(
        result,
        mix(targetBlue, deepBlue, 0.18),
        topReservoirCore
    );

    result += topReservoirGlow * float3(0.22, 0.80, 1.0);

    float finish = topCapProgress;

    float topCapAlpha =
        exp(-uv.y * 4.8) *
        finish *
        0.34 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topCapMist =
        exp(-uv.y * 1.22) *
        finish *
        0.13 *
        topBreath *
        finalFade *
        finalMistBoost;

    result = plusDarkerApprox(
        result,
        initialBottomLikeColor,
        topCapAlpha
    );

    result = plusDarkerApprox(
        result,
        mix(targetBlue, deepBlue, 0.14),
        topCapMist
    );

    result += topCapAlpha * float3(0.10, 0.46, 1.0) * 0.10;
    result += topCapMist * float3(0.42, 0.95, 1.0) * 0.045;

    float3 completionMistColor = mix(
        targetBlue,
        cyan,
        0.22
    );

    float completionMist =
        exp(-uv.y * 1.05) *
        completionMistProgress *
        0.12 *
        finalFade *
        finalMistBoost;

    float trailingGlow =
        exp(-pow((uv.y - 0.18) / 0.22, 2.0)) *
        finalBlur *
        0.10 *
        finalFade;

    result += completionMist * completionMistColor;
    result += trailingGlow * float3(0.30, 0.92, 1.0);

    result += completionFlash * float3(0.45, 0.95, 1.0) * 0.08;

    float completionPulse =
        completionBloom *
        (1.0 - 0.35 * sin(time * 2.4));

    float completionTopGlow =
        exp(-uv.y * 4.2) *
        completionPulse *
        0.06 *
        finalFade;

    result += completionTopGlow * float3(0.30, 0.82, 1.0);
    result = mix(result, white, completionBloom * bottomClear * 0.025);

    // --------------------------------------------------
    // Adaptive tap shockwave
    // --------------------------------------------------

    float rippleRadius = (1.0 - tapPulse) * mix(92.0, 310.0, dragWave);

    float rippleRing =
        exp(-pow((tapDist - rippleRadius) * 0.0064, 2.0)) *
        dragWave *
        (0.28 + 0.72 * tapPulse) *
        mix(0.7, 1.15, waveStrength);

    float rippleCore =
        exp(-pow(tapDist * 0.010, 2.0)) *
        dragWave *
        0.10 *
        waveStrength;

    float luminance = dot(result, float3(0.299, 0.587, 0.114));

    float blueRingStrength = rippleRing * smoothstep(0.60, 1.0, luminance);
    float whiteRingStrength = rippleRing * (1.0 - smoothstep(0.40, 0.90, luminance));

    float frontBand =
        localWaterPressure * 0.34 +
        abs(localWaterWave) * 0.30 +
        compositeWake * 0.24;

    float glassSheen =
        smoothstep(0.42, 1.0, compositeWake + frontBand) *
        (0.5 + 0.5 * sin(position.y * 0.030 - time * 4.5 + tapDist * 0.015)) *
        visualShock;

    result = mix(
        result,
        white,
        blueRingStrength * 0.08 + frontBand * 0.035
    );

    result += blueRingStrength * white * 0.035;

    result += whiteRingStrength * white * 0.10;
    result += rippleCore * white * 0.08;
    result += frontBand * white * 0.045;
    result += glassSheen * white * 0.026;
    result += max(localWaterWave, 0.0) * white * 0.16;
    result = mix(
        result,
        white,
        max(-localWaterWave, 0.0) * 0.030
    );

    // --------------------------------------------------
    // Keyframe-matched hero wash
    // --------------------------------------------------

    float keyProgress = clamp(progress, 0.0, 0.82);
    float keyPresence = smoothstep(0.02, 0.18, keyProgress) * fillGain;

    float keyedEdgeY = interpKeys(
        0.86,
        0.62,
        0.38,
        -0.10,
        keyProgress
    );

    float keyedFeather = interpKeys(
        0.16,
        0.22,
        0.31,
        0.27,
        keyProgress
    );

    float keyDx = uv.x - 0.5;

    float keyedSag =
        keyDx * keyDx *
        interpKeys(0.26, 0.32, 0.24, -0.30, keyProgress);

    float keyedEdgeNoise =
        0.012 * sin(uv.x * 9.0 + time * 0.24 + keyProgress * 4.0) +
        0.007 * sin(uv.x * 21.0 - time * 0.16 + keyProgress * 7.0) +
        dragWave * 0.018 * sin(uv.x * 13.0 + time * 0.36);

    float keyedLowerMass = smoothstep(
        keyedEdgeY - keyedFeather,
        keyedEdgeY + keyedFeather,
        uv.y + keyedSag + keyedEdgeNoise
    );

    float lowerFade = 1.0 - segmentEase(keyProgress, 0.62, 0.90);
    keyedLowerMass *= keyPresence * lowerFade;

    float keyedBottomWeight = smoothstep(0.28, 0.96, uv.y);
    float keyedLowerCore = keyedLowerMass * keyedBottomWeight * 0.88;

    float keyedCyanBand =
        exp(-pow((uv.y - keyedEdgeY) / max(keyedFeather * 1.18, 0.01), 2.0)) *
        exp(-pow(keyDx / 0.62, 2.0)) *
        keyPresence *
        lowerFade;

    float3 keyedBlueColor = mix(
        targetBlue,
        blue,
        0.10 + 0.18 * smoothstep(0.20, 0.46, keyProgress)
    );

    keyedBlueColor = mix(
        keyedBlueColor,
        mix(targetBlue, deepBlue, 0.12),
        smoothstep(0.50, 0.74, keyProgress) * smoothstep(0.58, 1.0, uv.y)
    );

    float3 keyedLowerColor = mix(
        mix(cyan, aqua, 0.50),
        keyedBlueColor,
        smoothstep(0.48, 1.0, uv.y)
    );

    result = plusDarkerApprox(
        result,
        keyedLowerColor,
        keyedLowerCore * 0.42 * fillGain
    );

    result += keyedCyanBand * float3(0.38, 0.88, 1.0) * 0.045 * waveStrength;

    float lensY = interpKeys(
        0.74,
        0.56,
        0.59,
        0.31,
        keyProgress
    );

    float lensRX = interpKeys(
        0.55,
        0.62,
        0.60,
        0.57,
        keyProgress
    );

    float lensRY = interpKeys(
        0.21,
        0.19,
        0.20,
        0.19,
        keyProgress
    );

    float lensTopFade =
        smoothstep(0.08, 0.24, keyProgress) *
        (1.0 - segmentEase(keyProgress, 0.88, 1.0));

    float lensD =
        pow((uv.x - 0.5) / max(lensRX, 0.01), 2.0) +
        pow((uv.y - lensY) / max(lensRY, 0.01), 2.0);

    float keyedWhiteLens =
        (1.0 - smoothstep(0.56, 1.48, lensD)) *
        lensTopFade;

    float keyedLensHalo =
        exp(-pow((sqrt(max(lensD, 0.0)) - 0.88) / 0.46, 2.0)) *
        lensTopFade;

    result += keyedWhiteLens * float3(0.18, 0.74, 1.0) * 0.030 * whiteCore;
    result += keyedLensHalo * float3(0.44, 0.92, 1.0) * 0.055 * whiteCore;

    float topPhase =
        segmentEase(keyProgress, 0.58, 0.84) *
        (1.0 - segmentEase(keyProgress, 0.94, 1.0));

    float topCurve =
        0.24 +
        keyDx * keyDx * 0.62 +
        0.011 * sin(uv.x * 8.0 + time * 0.20);

    float topCap =
        (1.0 - smoothstep(topCurve - 0.16, topCurve + 0.24, uv.y)) *
        topPhase;

    float topCore =
        exp(-uv.y * 3.1) *
        topPhase;

    float topMistBand =
        exp(-pow((uv.y - topCurve) / 0.26, 2.0)) *
        exp(-pow(keyDx / 0.78, 2.0)) *
        topPhase;

    float3 topKeyColor = mix(
        targetBlue,
        blue,
        0.16 * topBloom
    );

    result = plusDarkerApprox(
        result,
        topKeyColor,
        clamp(topCap * 0.46 + topCore * 0.12, 0.0, 1.0)
    );

    result += topMistBand * float3(0.56, 1.0, 1.0) * 0.13 * topBloom;

    float topWhiteBowl =
        (1.0 - smoothstep(0.62, 1.30, lensD)) *
        topPhase *
        0.70 * whiteCore;

    result += topWhiteBowl * float3(0.14, 0.62, 1.0) * 0.025;

    float2 swipeNow = float2((tapPoint.x - 0.5) * (safeSize.x / safeSize.y) + 0.5, tapPoint.y);
    float2 swipePrevious = float2((previousTouchPoint.x - 0.5) * (safeSize.x / safeSize.y) + 0.5, previousTouchPoint.y);
    float2 swipeUv = float2((uv.x - 0.5) * (safeSize.x / safeSize.y) + 0.5, uv.y);
    float2 swipePath = swipeNow - swipePrevious;
    float swipePathLength = length(swipePath);
    float swipeMovement = smootherLiquid(smoothstep(0.002, 0.030, swipePathLength));
    float swipeEnergy = swipePulse * swipeMovement * smoothstep(0.010, 0.16, swipeStrength);
    float2 swipeDir = swipePath / max(swipePathLength, 0.0001);
    float2 swipeNormal = float2(-swipeDir.y, swipeDir.x);
    float2 swipeCenter = mix(swipePrevious, swipeNow, 0.54);
    float2 swipeDelta = swipeUv - swipeCenter;
    float swipeAlong = dot(swipeDelta, swipeDir);
    float swipeLateral = dot(swipeDelta, swipeNormal);
    float swipeLength = mix(0.26, 0.48, smoothstep(0.004, 0.070, swipePathLength));
    float swipeWidth = mix(0.105, 0.172, smoothstep(0.012, 0.30, swipeStrength));
    float swipeBody =
        (1.0 - smoothstep(swipeLength * 0.42, swipeLength * 0.64, abs(swipeAlong))) *
        exp(-pow(swipeLateral / max(swipeWidth, 0.001), 2.0));
    float swipeCore =
        (1.0 - smoothstep(swipeLength * 0.18, swipeLength * 0.46, abs(swipeAlong))) *
        exp(-pow(swipeLateral / max(swipeWidth * 0.52, 0.001), 2.0));
    float swipeTail =
        smoothstep(-swipeLength * 0.62, -swipeLength * 0.08, swipeAlong) *
        (1.0 - smoothstep(swipeLength * 0.08, swipeLength * 0.60, swipeAlong)) *
        exp(-pow(swipeLateral / max(swipeWidth * 1.28, 0.001), 2.0));
    float swipeRipple =
        0.5 + 0.5 * sin(swipeAlong * 34.0 - swipeLateral * 13.0 + time * 1.8);
    float swipeSmear = clamp((swipeBody * 0.72 + swipeCore * 0.34 + swipeTail * 0.42) * swipeEnergy, 0.0, 1.0);
    float swipeGlassEdge =
        exp(-pow((abs(swipeLateral) - swipeWidth * 0.72) / max(swipeWidth * 0.36, 0.001), 2.0)) *
        (1.0 - smoothstep(swipeLength * 0.38, swipeLength * 0.66, abs(swipeAlong))) *
        swipeEnergy;
    float swipeAura =
        exp(-pow(swipeLateral / max(swipeWidth * 1.72, 0.001), 2.0)) *
        (1.0 - smoothstep(swipeLength * 0.48, swipeLength * 0.82, abs(swipeAlong))) *
        swipeEnergy;
    float swipeFlow =
        (0.5 + 0.5 * sin(swipeAlong * 13.0 - time * 2.2)) *
        exp(-pow(swipeLateral / max(swipeWidth * 1.08, 0.001), 2.0)) *
        swipeEnergy;

    result = mix(
        result,
        white,
        clamp(swipeSmear * (0.66 + swipeCore * 0.28), 0.0, 0.82)
    );
    result = plusDarkerApprox(
        result,
        white,
        clamp(swipeAura * 0.18 + swipeFlow * 0.08, 0.0, 0.24)
    );
    result += swipeSmear * white * 0.050;
    result += swipeGlassEdge * white * (0.044 + swipeRipple * 0.024);

    float grainMask = clamp(
        liquidAlpha +
        backAlpha * 0.55 +
        mainAlpha * 0.35 +
        topReservoirProgress * 0.30 +
        idleWaveEnergy * 0.30,
        0.0,
        1.0
    );

    float grain = (hashLiquid(position + float2(time * 0.37)) - 0.5);

    result += grain * mix(0.0012, 0.0052, grainMask) * finalFade;

    float rippleShade = clamp(shadertoyRippleLight, -1.0, 1.0) * rippleEnvelope;
    result += rippleShade * white * 0.14;
    result = mix(
        result,
        white,
        max(-rippleShade, 0.0) * 0.035
    );

    float3 lightResult = clamp(result, 0.0, 1.0);

    float3 preThemeMotionResult = lightResult;
    float3 darkSourceLightResult = lightResult;

    float motionColorRestore = clamp(
        tapTrail * 2.10 +
        screenTrail * 2.40 +
        secondaryTrail * 2.00 +
        diagonalTrail * 1.85 +
        screenRipple * 1.65 +
        compositeWake * 1.45 +
        frontBand * 1.55 +
        swipeSmear * 1.95 +
        swipeAura * 1.35 +
        swipeGlassEdge * 1.70 +
        abs(rippleShade) * 1.40,
        0.0,
        1.0
    );
    motionColorRestore = smootherLiquid(motionColorRestore);

    float yellowColoredPresence =
        smoothstep(0.018, 0.27, distance(lightResult, white)) *
        (1.0 - motionColorRestore * 0.98);
    float yellowProgressPresence = smoothstep(0.025, 0.16, progress);
    float yellowWarmDepth = smoothstep(0.46, 1.0, uv.y);
    float yellowTopGlow = 1.0 - smoothstep(0.16, 0.58, uv.y);
    float yellowBottomGlow = smoothstep(0.55, 1.0, uv.y);

    float3 yellowLemon = float3(1.0, 0.975, 0.035);
    float3 yellowSoft = float3(1.0, 0.955, 0.24);
    float3 yellowAmber = float3(1.0, 0.635, 0.060);
    float3 yellowTarget = mix(yellowLemon, yellowAmber, smootherLiquid(yellowWarmDepth));
    yellowTarget = mix(yellowTarget, yellowSoft, yellowTopGlow * 0.24);
    yellowTarget = mix(yellowTarget, yellowAmber, yellowBottomGlow * 0.20);

    float yellowWhiteCenterY =
        0.515 +
        0.020 * sin(time * 0.18 + progress * 4.2);

    float yellowWhiteCenterD =
        pow((uv.x - 0.50) / 0.73, 2.0) +
        pow((uv.y - yellowWhiteCenterY) / 0.205, 2.0);

    float yellowWhiteCenter =
        (1.0 - smoothstep(0.58, 1.34, yellowWhiteCenterD)) *
        yellowProgressPresence *
        (1.0 - segmentEase(progress, 0.94, 1.0) * 0.16);

    float yellowTopWash =
        exp(-pow((uv.y - 0.145) / 0.34, 2.0)) *
        yellowColoredPresence *
        0.18;

    float yellowBottomWash =
        exp(-pow((uv.y - 0.955) / 0.30, 2.0)) *
        yellowColoredPresence *
        0.26;

    lightResult = mix(
        lightResult,
        yellowTarget,
        isYellowPreset * clamp(yellowColoredPresence * 0.92, 0.0, 0.92)
    );

    lightResult = mix(
        lightResult,
        white,
        isYellowPreset * clamp(yellowWhiteCenter * 0.84, 0.0, 0.86)
    );

    lightResult += isYellowPreset * yellowTopWash * float3(1.0, 0.96, 0.08);
    lightResult += isYellowPreset * yellowBottomWash * float3(1.0, 0.53, 0.03);
    lightResult = clamp(lightResult, 0.0, 1.0);
    lightResult = mix(
        lightResult,
        preThemeMotionResult,
        isYellowPreset * motionColorRestore
    );

    // Shared travelling-band timing; each light preset applies its own palette below.
    float referenceBandCenter;
    float referenceBandWidth;
    if (progress <= 0.50) {
        float phase = smootherLiquid(progress / 0.50);
        referenceBandCenter = bandMotion(1.105, 0.855, 0.0, -0.838028, progress / 0.50, 0.50);
        referenceBandWidth = mix(0.205, 0.315, phase);
    } else if (progress <= 0.70) {
        float phase = smootherLiquid((progress - 0.50) / 0.20);
        referenceBandCenter = bandMotion(0.855, 0.515, -0.838028, -1.676693, (progress - 0.50) / 0.20, 0.20);
        referenceBandWidth = mix(0.315, 0.285, phase);
    } else {
        float phase = smootherLiquid((progress - 0.70) / 0.30);
        referenceBandCenter = bandMotion(0.515, 0.020, -1.676693, 0.0, (progress - 0.70) / 0.30, 0.30);
        referenceBandWidth = mix(0.285, 0.235, phase);
    }

    // Yellow follows the established Blue entry; Blue geometry stays unchanged.
    referenceBandCenter -= clamp(isBluePreset + isYellowPreset, 0.0, 1.0) * 0.065 * smoothstep(0.0, 0.05, progress) *
        (1.0 - segmentEase(progress, 0.26, 0.45));
    // Continue the shared mass upward after 90%, without changing the clock.
    referenceBandCenter -= 0.075 * segmentEase(progress, 0.90, 1.0);

    float referenceWarp =
        sin(uv.x * 5.7 + time * 0.11) * 0.018 +
        sin(uv.x * 10.4 - time * 0.08 + 1.2) * 0.008;
    float referenceDistance = uv.y + referenceWarp - referenceBandCenter;
    float referenceOuter = exp(-pow(referenceDistance / referenceBandWidth, 2.0));
    float referenceBody = exp(-pow(referenceDistance / (referenceBandWidth * 0.70), 2.0));
    float referenceCore = exp(-pow(referenceDistance / (referenceBandWidth * 0.34), 2.0));
    float referenceEntry = smoothstep(0.002, 0.020, progress);
    referenceOuter *= referenceEntry;
    referenceBody *= referenceEntry;
    referenceCore *= referenceEntry;

    float3 referenceCyan = float3(0.380, 0.910, 1.000);
    float3 referenceBlue = float3(0.259, 0.545, 0.976); // #428BF9
    float3 referenceBlueAccent = float3(0.000, 0.424, 1.000); // #006CFF
    // One broad pigment profile avoids the narrow accent stripe produced by
    // compositing several differently sized blue cores over one another.
    float blueLightDensity = exp(-pow(referenceDistance / (referenceBandWidth * 0.82), 2.0)) * referenceEntry;
    float3 blueLightPigment = mix(referenceCyan, mix(referenceBlue, referenceBlueAccent, 0.36),
        blueLightDensity * blueLightDensity * 0.85);
    float3 referenceBlueResult = mix(white, blueLightPigment,
        referenceOuter * (0.82 + 0.16 * blueLightDensity));

    // Match Blue Light's monotonic depth profile: orange in the dense body,
    // #FFDD2D in the shoulder, then yellow coverage dissolving into white.
    float yellowOrangeWeight = pow(blueLightDensity, 4.0) * 0.60;
    float3 yellowLightOrange = mix(yellowMidColor.rgb, yellowHotColor.rgb, 0.25);
    float3 yellowLightPigment = mix(yellowLightAccent, yellowLightOrange, yellowOrangeWeight);
    float3 referenceYellowResult = mix(white, yellowLightPigment,
        referenceOuter * (0.82 + 0.16 * blueLightDensity));

    lightResult = mix(lightResult, referenceBlueResult, isBluePreset);
    lightResult = mix(lightResult, referenceYellowResult, isYellowPreset);

    float liquidPresence = clamp(distance(darkSourceLightResult, white) * 1.38, 0.0, 1.0);
    float glowPresence = clamp(
        liquidPresence +
        rimAlpha * 0.32 +
        revealEdgeGlow * 0.50 +
        surfaceGlow * 0.22,
        0.0,
        1.0
    );
    float finishLift = segmentEase(progress, 0.76, 1.00);
    float bottomWeightDark = smoothstep(0.32, 1.0, uv.y);
    float topWeightDark = 1.0 - smoothstep(0.10, 0.46, uv.y);
    float finishTopPush =
        finishLift *
        (1.0 - smoothstep(0.11, 0.48, uv.y)) *
        (0.78 + 0.22 * exp(-pow((uv.y - 0.08) / 0.17, 2.0)));
    float sideGlowDark =
        exp(-pow(uv.x / 0.13, 2.0)) +
        exp(-pow((1.0 - uv.x) / 0.13, 2.0));

    float darkLowerField = clamp(
        glowPresence * (0.56 + bottomWeightDark * 0.42) +
        keyedLowerCore * 0.92 +
        keyedCyanBand * 0.44 +
        liquidAlpha * bottomWeightDark * 0.54 +
        surfaceGlow * 0.22,
        0.0,
        1.0
    );
    darkLowerField *= mix(1.0, 0.015, finishLift);

    float darkTopField = clamp(
        topPhase * (topCap * 0.80 + topCore * 0.34 + topMistBand * 0.72) +
        topReservoir * 0.72 +
        topReservoirCore * 0.54 +
        topReservoirGlow * 0.80 +
        completionMist * 0.82 +
        trailingGlow * 0.70 +
        completionTopGlow * 0.80 +
        finishLift * topWeightDark * 1.04 +
        finishTopPush * 0.42,
        0.0,
        1.0
    );

    // The dark palette always starts on a true black canvas. The selected color is
    // revealed only by the progressing field, never inherited from the light result.
    float darkColorReveal = smoothstep(0.015, 0.24, progress);
    darkLowerField *= darkColorReveal;
    darkTopField *= darkColorReveal;

    float cyanWashDark = clamp(
        keyedCyanBand * 0.70 +
        keyedLensHalo * 0.30 +
        revealEdgeGlow * 0.72 +
        rimAlpha * 0.24,
        0.0,
        1.0
    ) * darkColorReveal;

    // One soft, asymmetric reduction of light behind the digits; no ring or
    // constant-radius plateau. Coordinates match the existing counter region.
    float counterDrift = sin(time * 0.16) * 0.006;
    float2 counterDelta = float2(
        (uv.x - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.29,
        (uv.y - 0.475 + sin(uv.x * 8.0 + 0.8) * 0.016 + counterDrift) / 0.090
    );
    float2 counterLobe = float2((uv.x - 0.57) / 0.23, (uv.y - 0.45 + counterDrift) / 0.105);
    float counterProtection = 0.76 * exp(-dot(counterDelta, counterDelta)) +
        0.24 * exp(-dot(counterLobe, counterLobe));
    // A diffuse light pocket restores the clean light-theme counter area
    // without the former circular stroke or stacked glass-lens masks.
    lightResult = mix(lightResult, white, counterProtection * 0.32);

    float centerVoidD =
        pow((uv.x - 0.5 + sin(uv.y * 11.0 + time * 0.12) * 0.018) / 0.354, 2.0) +
        pow((uv.y - 0.475 + sin(uv.x * 8.0 + 0.8) * 0.014) / 0.150, 2.0);
    float centerVoid = (1.0 - smoothstep(0.36, 1.68, centerVoidD)) *
        mix(0.56, 0.82, smoothstep(0.02, 0.58, progress));
    float centerVoidSoft = (1.0 - smoothstep(0.58, 2.55, centerVoidD)) *
        mix(0.18, 0.32, smoothstep(0.10, 0.72, progress));
    float centerReduction = clamp(centerVoid * 0.58 + centerVoidSoft * 0.18, 0.0, 0.70);

    float topBlackShelf =
        (1.0 - smoothstep(0.20, 0.52, uv.y)) *
        (1.0 - smoothstep(0.0, 0.18, progress)) *
        0.38;

    float3 darkBase = float3(0.0, 0.0, 0.0);
    float3 darkNavy = float3(0.004, 0.010, 0.024);
    float3 darkBlueGlow = mix(
        float3(0.045, 0.230, 0.780),
        float3(0.820, 0.405, 0.018),
        isYellowPreset
    );
    float3 darkElectric = mix(
        float3(0.100, 0.430, 1.000),
        float3(1.000, 0.720, 0.030),
        isYellowPreset
    );
    float3 darkCyan = mix(
        float3(0.520, 0.960, 1.000),
        float3(1.000, 0.925, 0.210),
        isYellowPreset
    );
    float3 darkMintCyan = mix(
        float3(0.650, 1.000, 0.900),
        float3(1.000, 0.970, 0.560),
        isYellowPreset
    );

    float lowerIntensity = smootherLiquid(darkLowerField);
    float topIntensity = smootherLiquid(darkTopField);
    float edgeIntensity = clamp(sideGlowDark * (darkLowerField * 0.30 + darkTopField * 0.34), 0.0, 1.0);

    float3 darkResult = darkBase;
    darkResult = mix(darkResult, darkNavy, clamp(darkLowerField * 0.52 + darkTopField * 0.38, 0.0, 1.0));
    darkResult += mix(darkBlueGlow, darkElectric, smoothstep(0.22, 0.92, lowerIntensity)) * lowerIntensity * 0.82;
    darkResult += darkCyan * cyanWashDark * 0.24;
    darkResult += darkMintCyan * keyedWhiteLens * 0.10 * darkColorReveal;
    darkResult += mix(darkBlueGlow, darkElectric, 0.52) * topIntensity * 0.86;
    darkResult += darkCyan * topMistBand * 0.22 * darkColorReveal;
    darkResult += darkElectric * edgeIntensity * 0.42;
    darkResult += mix(darkBlueGlow, darkElectric, 0.72) * finishTopPush * 0.34;

    darkResult = mix(darkResult, darkBase, clamp(centerVoidSoft, 0.0, 0.34));
    darkResult = mix(darkResult, darkBase, clamp(centerVoid, 0.0, 0.86));
    darkResult = mix(darkResult, darkBase, finishLift * smoothstep(0.30, 0.72, uv.y) * 0.64);
    darkResult = mix(darkResult, darkBase, topBlackShelf);
    float blueIdleAccent = isBluePreset * idleWaveEnergy * (1.0 - motionColorRestore * 0.85);
    darkResult += float3(0.000, 0.423529, 1.000) * blueIdleAccent * 0.74;
    darkResult += float3(0.540, 0.900, 1.000) * blueIdleAccent * 0.24;
    float yellowIdleAccent = isYellowPreset * idleWaveEnergy * (1.0 - motionColorRestore * 0.85);
    darkResult += float3(1.000, 0.780, 0.075) * yellowIdleAccent * 0.62;
    darkResult += float3(1.000, 0.956, 0.365) * yellowIdleAccent * 0.24;

    // Dark mode uses the same travelling band as the light reference. Only the
    // canvas changes to black; no accumulated color remains below the band.
    float3 darkBandOuterColor = mix(targetBlue, cyan, 0.30);
    float3 darkBandBodyColor = mix(targetBlue, electric, 0.34);
    float3 darkBandCoreColor = mix(targetBlue, electric, 0.72);
    if (isYellowPreset > 0.5) {
        // Carry Blue Dark's dominant-channel light field through the shared
        // masks first. Apply Yellow's palette after them, not before dimming.
        darkBandOuterColor = darkBandBodyColor = darkBandCoreColor = float3(1.0);
    }
    float darkBandEntry = smoothstep(0.002, 0.020, progress);
    float darkBandOuter = referenceOuter * darkBandEntry;
    float darkBandBody = referenceBody * darkBandEntry;
    float darkBandCore = referenceCore * darkBandEntry;
    float3 travellingDarkResult = darkBase;
    travellingDarkResult += darkBandOuterColor * darkBandOuter * 0.20;
    travellingDarkResult += darkBandBodyColor * darkBandBody * 0.58;
    travellingDarkResult += darkBandCoreColor * darkBandCore * 0.54;
    travellingDarkResult = mix(
        travellingDarkResult,
        darkBase,
        centerReduction
    );
    darkResult = travellingDarkResult;
    // Clear behind the moving mass, not through its bright core at 70–85%.
    // Rejoin the original completion fade before the explicit endpoint gate.
    float completionBlackout =
        segmentEase(progress, 0.58, 0.98) *
        smoothstep(0.06, 0.38, uv.y) *
        mix(smoothstep(0.04, 0.32, referenceDistance),
            1.0, segmentEase(progress, 0.85, 0.98));
    darkResult = mix(darkResult, darkBase, completionBlackout);
    // Hard safety gate: no color is allowed to leak into a dark-theme canvas at 0%.
    // This is intentionally applied after every dark effect contribution.
    float darkCanvasReveal = smoothstep(0.0, 0.10, progress);
    darkResult = mix(darkBase, darkResult, darkCanvasReveal);

    float finishSync = segmentEase(progress, 0.94, 1.0);
    float endpointCoverage = referenceOuter * (0.82 + 0.16 * blueLightDensity) *
        (1.0 - counterProtection * 0.32);
    float3 endpointColor = isYellowPreset > 0.5 ? float3(1.0) : darkBandCoreColor;
    darkResult = mix(darkResult, endpointColor * endpointCoverage, finishSync);
    // Blue Dark's unbounded density is the only spatial input to palette
    // mapping. A second, narrower body mask made the other palettes read as
    // stripes even though their outer coverage matched Blue.
    float sharedLightField = max(darkResult.r, max(darkResult.g, darkResult.b));
    // REGRESSION LOCK: geometry is resolved ONCE before any of the four palettes.
    // Main/front/free-wave fields contain no theme or color coefficients.
    float idleDensity = idleActivity > 0.0
        ? idleWaveDensity(position, size, idleActivity, idleTime, waveStrength) : 0.0;
    float preservedGrain=grain*mix(0.0010,0.0035,grainMask)*
        (1.0-completionBlackout)*darkCanvasReveal;
    return float4(sharedLightField,idleDensity,counterProtection,preservedGrain);
}


namespace YellowDarkMAIN {
// Yellow-only review overlay. Compile with the immutable accepted Blue source.
// Production Yellow colour stops; Yellow-only readout/contact corrections.
float3 yellowReviewSubstratePalette(float sharedLightField,float progress) {
    // The accepted MAIN pose already settles before p=1. Production's old
    // endpoint hue/exposure compensation must not fire over this frozen pose.
    float3 blueDarkReference=float3(0.10,0.55,1.0)*sharedLightField;
    float warmth = clamp(sharedLightField / (0.20 + 0.58 + 0.54), 0.0, 1.0);
    float3 warmColor = mix(yellowDeepColor.rgb, yellowHotColor.rgb, warmth);
    float3 luminanceWeights = float3(0.2126, 0.7152, 0.0722);
    float referenceLuminance = dot(pow(clamp(blueDarkReference, 0.0, 1.0),
        float3(2.2)), luminanceWeights);
    float warmLuminance = dot(pow(warmColor, float3(2.2)), luminanceWeights);
    // Lift only the low-density colour toe. The existing bright maxima and
    // colour ratios remain pinned; no field, Gaussian or spatial blur changes.
    float toe=1.0-clamp(sharedLightField/(0.20+0.58+0.54),0.0,1.0);
    float late=segmentEase(progress,0.78,0.86);
    float lowDensity=1.0-segmentEase(sharedLightField,0.20,0.50);
    float colourFeather=1.0+0.35*toe*toe*toe;
    if(progress>0.78 && sharedLightField<0.50) colourFeather+=0.40*late*lowDensity*toe*toe*toe;
    float paletteExposure=1.12*pow(colourFeather,2.2);
    #if 0
    // Comparison B only: production's density-to-colour curve; same MAIN field.
    return yellowDarkDensityPalette(sharedLightField);
#else
    float3 mapped=warmColor * pow(referenceLuminance * paletteExposure /
        max(warmLuminance, 0.00001), 1.0 / 2.2);
    // Same bounded cap as Blue's saturated channel; only the late R shoulder.
    if(progress>0.78) mapped.r=mix(mapped.r,qaNativeBlueCap(mapped.r),late);
    return mapped;
#endif
}
// Authorized Yellow-only removal of the restored outer residual.
// Exact accepted pose/clock/profiles. Only the restored outer term respects
// its EXISTING completion mask, as it already does in the Light readout.
// The immutable Blue implementation and physical CONTACT fields stay intact.
float yellowReviewDarkMainAtPose(float2 uv,float progress,float time) {
    if(progress<=0.76) return qaMainAtPose(uv,progress,time,true);
    uv.y+=(102.0/844.0)*segmentEase(progress,0.85,1.0);
    float p=qaMainPoseProgress(progress),t=qaMainPoseTime(progress,time);
    float center,width;qaMainPoseBand(p,center,width);
    float L=qaAcceptedLightShapeDensityImpl(uv,p,t,center,width,true,true,progress);
    float D=qaAcceptedDarkShapeDensity(uv,p,t,center,width);
    float transfer=segmentEase(p,.70,.76)*(1.0-segmentEase(p,.94,1.0));
    float x=uv.x,mx=1.0-x;
    float w=sin(x*5.7+t*.11)*.018+sin(x*10.4-t*.08+1.2)*.008;
    float mw=sin(mx*5.7+t*.11)*.018+sin(mx*10.4-t*.08+1.2)*.008;
    w=mix(w,(w+mw)*.5,segmentEase(p,.50,.76));
    return qaDarkLateFade(mix(D,L,transfer),(uv.y+w-center)/width,progress);
}
// Both Dark alternatives use ONE scalar exposure. Only chroma stops differ.
// No per-channel clipping, progress-dependent toe boost or alternate density curve.
float3 yellowReviewDarkPalette(float M,float progress) {
    float q=clamp(M/1.32,0.0,1.0);
    float3 current=mix(yellowDeepColor.rgb,yellowHotColor.rgb,q);
    float3 hue=current;
#ifdef QA_CONFIG_PALETTE
    // Configured chroma follows exposure: dark orange shadows, gold crest.
    // The former density exponential reached Accent while still in shadow.
    float exposurePosition=clamp(M/1.32,0.0,1.0);
    float lower=segmentEase(exposurePosition,0.0,0.50);
    float upper=segmentEase(exposurePosition,0.50,1.0);
    hue=mix(mix(yellowDeepColor.rgb,yellowHotColor.rgb,lower),yellowLightAccent,upper);
#endif
    float3 w=float3(0.2126,0.7152,0.0722);
    // Unclipped Blue reference avoids the B=1 derivative corner at M=1.
    // A common smooth peak cap preserves colour ratios and bright maxima.
    float reference=dot(pow(float3(.10,.55,1.0)*max(M,0.0),float3(2.2)),w);
    float amplitude=pow(reference*1.12/max(dot(pow(current,float3(2.2)),w),.00001),1.0/2.2);
    float commonAmplitude=qaNativeBlueCap(amplitude);
    // Use the common exposure without re-darkening configured gold to the
    // CURRENT palette's luminance. Chroma brightness remains palette-specific.
    return hue*commonAmplitude;
}
float3 yellowReviewTransmission() {
    float3 yellowLightOrange=mix(yellowMidColor.rgb,yellowHotColor.rgb,0.25);
    return float3(yellowLightOrange.r,mix(yellowMidColor.g,yellowHotColor.g,0.75),
        pow(yellowLightAccent.b,2.5));
}
// Colour partition of the EXISTING idleWaveDensity profiles. Geometry is
// copied verbatim only to recover primary / (primary+secondary+halo); W and I
// still come from the immutable physical field, including its exact clamps.
float yellowReviewPrimaryShare(float2 position,float2 size,float idleTime) {
    float2 p=position/max(size,float2(1.0))*float2(375.0,812.0);
    float cycle=smootherLiquid(fract(idleTime/3.0));
    float waveY=mix(-110.0,925.0,cycle);
    float width=mix(72.0,420.0,cycle);
    float thickness=mix(19.0,42.0,cycle);
    float dx=p.x-187.5;
    float arcY=waveY+(dx*dx)/max(width*1.72,1.0);
    float distanceToArc=p.y-arcY;
    float primary=exp(-pow(distanceToArc/thickness,2.0))*exp(-pow(dx/width,2.0));
    float secondary=exp(-pow((distanceToArc+72.0)/(thickness*1.35),2.0))*
        exp(-pow(dx/(width*1.18),2.0))*0.32;
    float halo=exp(-pow((p.y-waveY)/180.0,2.0))*
        exp(-pow(dx/max(width*1.18,1.0),2.0))*0.12;
    return primary/max(primary+secondary+halo,0.000001);
}
// Light-only colour metadata from the exact existing primary/secondary/halo.
// Keep the scalar function and all Dark calls unchanged for pixel identity.
float3 yellowReviewWaveShares(float2 position,float2 size,float idleTime) {
    float2 p=position/max(size,float2(1.0))*float2(375.0,812.0);
    float cycle=smootherLiquid(fract(idleTime/3.0));
    float waveY=mix(-110.0,925.0,cycle);
    float width=mix(72.0,420.0,cycle);
    float thickness=mix(19.0,42.0,cycle);
    float dx=p.x-187.5;
    float arcY=waveY+(dx*dx)/max(width*1.72,1.0);
    float distanceToArc=p.y-arcY;
    float primary=exp(-pow(distanceToArc/thickness,2.0))*exp(-pow(dx/width,2.0));
    float secondary=exp(-pow((distanceToArc+72.0)/(thickness*1.35),2.0))*
        exp(-pow(dx/(width*1.18),2.0))*0.32;
    float halo=exp(-pow((p.y-waveY)/180.0,2.0))*
        exp(-pow(dx/max(width*1.18,1.0),2.0))*0.12;
    return float3(primary,secondary,halo)/max(primary+secondary+halo,0.000001);
}
// Match the accepted Blue channel response, exchanging its blue energy
// axis for Yellow's red axis. Same W/I and same positive relief increment.
// Blue source (.14,.48,1), peak (.24,1,1): Yellow (1,.48,.14), (1,1,.24).
// Constants come from the protected response, not a new spatial light layer.
float3 yellowReviewLightSource(float3 shares,float W) {
    return float3(1.0,0.48,0.14);
}
float3 yellowReviewLightPeak(float3 shares) {
    return float3(1.0,1.0,0.24);
}
// Hue-only warm gamut readout. The unchanged caption backdrop can make
// pure R=G yellow look olive. Preserve HSV V and S, unlike the previous
// OKLab/max-linear normalization that suppressed the luminous crest.
float3 yellowReviewHSV(float3 rgb) {
    float hi=max(rgb.r,max(rgb.g,rgb.b)),lo=min(rgb.r,min(rgb.g,rgb.b));
    float d=hi-lo,h=0.0;
    if(d>0.000001) {
        if(hi==rgb.r)h=(rgb.g-rgb.b)/d;
        else if(hi==rgb.g)h=2.0+(rgb.b-rgb.r)/d;
        else h=4.0+(rgb.r-rgb.g)/d;
        h=fract(h/6.0+1.0);
    }
    return float3(h,hi>0.000001 ? d/hi:0.0,hi);
}
float3 yellowReviewGoldenHue(float3 rgb,float counterProtection) {
    float3 hsv=yellowReviewHSV(rgb);
    // Existing configured Accent to the bright yellow endpoint. Only the
    // upper yellow hue shoulder changes, never V/S or an independent channel.
    // Keep configured golden hue when the protected UI darkens the crest.
    // The former added lemon endpoint became olive under the caption shade.
    float brightGold=yellowReviewHSV(yellowLightAccent).x;
    // Existing Dark counter protection predicts the protected UI shade.
    // Warm only that shaded contact hue; unshaded luminous crest stays yellow.
    float shadedOrange=yellowReviewHSV(float3(1.0,140.0/255.0,0.0)).x;
    float limit=mix(brightGold,shadedOrange,
        // Reuse the existing readability field and the prior accepted colour shoulder.
        segmentEase(sqrt(clamp(counterProtection,0.0,1.0)),0.06,0.36));
    if(hsv.x<0.25) {
        float excess=max(hsv.x-limit,0.0);
        hsv.x=hsv.x-excess+0.002*(1.0-exp(-excess/0.002));
    }
    float3 p=abs(fract(hsv.x+float3(0.0,2.0/3.0,1.0/3.0))*6.0-3.0);
    return hsv.z*mix(float3(1.0),clamp(p-1.0,0.0,1.0),hsv.y);
}
float3 yellowReviewDarkContact(float3 base,IdleContact contact,float physicalMain,float displayMain) {
    // The reference's additive contact response, with the energy axes exchanged.
    // Positive low-channel increment restores relief; source G=.48 leaves
    // room for the I-driven G=1 crest instead of saturating the entire halo.
    // Free emitter anchor: #FF8C00. Overlap peak and W/I are preserved.
    float3 source=float3(1.0,140.0/255.0,0.0),peak=float3(1.0,1.0,.24);
    return clamp(base+peak*contact.frontReaction+
        idleContactLight(source,peak,contact),0.0,1.0);
}


half4 liquidYellowReviewBackground(
    float2 position,
    half4 color,
    float2 size,
    float progress,
    float tapPulse,
    float2 tapPoint,
    float2 previousTouchPoint,
    float swipePulse,
    float swipeStrength,
    float time,
    float progressSpeed,
    float fillGain,
    float waveStrength,
    float waveSpread,
    float topBloom,
    float whiteCore,
    float blueDepth,
    float dragWave,
    float shockStrength,
    float shockInteraction,
    float shockTrail,
    float waveCount,
    float themeStrength,
    float gradientColorIndex,
    float idleActivity,
    float idleTime,
    device const float *interactionSegments,
    int interactionFloatCount
) {
    if(abs(round(gradientColorIndex)-3.0)>0.5) {
        return liquidSpecBackground(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,themeStrength,gradientColorIndex,idleActivity,idleTime,interactionSegments,interactionFloatCount);
    }
    float2 safeSize=max(size,float2(1.0)),uv=position/safeSize;
    float4 physical=yellowReferenceContactFields(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,1.0,0.0,idleActivity,idleTime,interactionSegments,interactionFloatCount);
    float physicalMain=physical.x;
    float W=float(half(physical.y));
    IdleContact contact=sharedIdleContact(physicalMain,W);
    float primaryShare=yellowReviewPrimaryShare(position,size,idleTime);
    float3 transmission=yellowReviewTransmission();
    bool dark=themeStrength>0.5;
    // Query, do not rewrite, the exact accepted Blue MAIN display fields.
    float M=dark ? yellowReviewDarkMainAtPose(uv,progress,time) : qaMainAtPose(uv,progress,time,false);
    float3 mainBase=dark ? clamp(yellowReviewDarkPalette(M,progress)+physical.w,0.0,1.0)
        : correctedLightPigment(M,3.0,transmission);
    // Reuse Blue's original diffuse counter-protection pocket, with the same
    // field and 0.32 weight. Keep the production percentage/UI untouched.
    if(!dark) mainBase=mix(mainBase,float3(1.0),clamp(physical.z,0.0,1.0)*0.32);
    float3 result=mainBase;
    float counterProtection=physical.z;
    float darkTheme=step(0.5,themeStrength);
    float isYellowPreset=1.0;
    float3 white=float3(1.0),targetBlue=float3(0.10,0.55,1.0);
    float3 referenceCyan = float3(0.380, 0.910, 1.000);
    float3 yellowLightOrange=mix(yellowMidColor.rgb,yellowHotColor.rgb,0.25);
    float3 blueDarkReference=clamp(float3(.10,.55,1.0)*physicalMain,0.0,1.0);
    if (interactionFloatCount > 0) {
        float trail = interactionLightField(uv, safeSize.x / safeSize.y, interactionSegments, interactionFloatCount);
        float readability = 1.0 - 0.88 * counterProtection;
        // Exposure depends on local interaction accumulation, so a first pass
        // cannot start white merely because it crosses a bright progress band.
        float heat = trail;
        float brighter = 1.0 - exp(-max(heat - 0.35, 0.0) * 0.95);
        float excessHeat = max(heat - 1.45, 0.0);
        float exposure = 1.0 - exp(-excessHeat * excessHeat / 3.0);
        float3 trailColor;
        if (isYellowPreset > 0.5) {
            // Channel-wise exponential exposure used to push R and G towards
            // equality, leaving olive on black. Keep warm hue while light grows.
            float3 warm = darkTheme > 0.5
                ? mix(yellowDeepColor.rgb, min(yellowHotColor.rgb * 1.18, 1.0), brighter)
                : mix(yellowHotColor.rgb, yellowLightAccent, 0.48 + brighter * 0.52);
            float cream = smoothstep(0.70, 3.0, heat) * 0.75;
            if (darkTheme < 0.5) {
                // A broad orange interval separates yellow pigment from light,
                // making the trail readable even over a saturated yellow base.
                float orange = exp(-pow((heat - 0.85) / 0.90, 2.0)) *
                    (1.0 - exp(-heat * 2.0)) * 0.75;
                warm = mix(yellowLightAccent, yellowLightOrange, orange);
                cream = smoothstep(1.55, 3.50, heat) * 0.75;
                float accumulatedHeat = max(heat - 2.0, 0.0);
                exposure = 1.0 - exp(-accumulatedHeat * accumulatedHeat / 2.8);
            }
            warm = mix(warm, mix(yellowHotColor.rgb, white, 0.82), cream);
            trailColor = mix(warm, mix(yellowHotColor.rgb, white, 0.94), exposure);
        } else {
            // Reuse the cyan produced by the existing additive idle overlap.
            float3 overlapCyan = clamp(targetBlue + float3(0.14, 0.48, 1.0), 0.0, 1.0);
            float3 lightBlue = mix(targetBlue, mix(referenceCyan, overlapCyan, darkTheme), brighter);
            trailColor = mix(lightBlue, float3(0.91, 0.98, 1.0), exposure);
        }
        // Protect text through coverage, not heat: the mask must not turn a
        // hot white/cyan/cream trail into a different, muddy color at its edge.
        float opacity = (0.78 + 0.22 * exposure) * (1.0 - exp(-trail * 0.95)) * readability;
        if (darkTheme > 0.5) {
            float3 backdrop = result;
            result = 1.0 - (1.0 - result) * (1.0 - trailColor * opacity);
            if (isYellowPreset > 0.5) {
                // Same trail field, alpha and screen blending as Blue Dark;
                // only reduce color energy if the warm overlap is brighter.
                float3 blueTrail = mix(mix(float3(0.10, 0.55, 1.0),
                    float3(0.24, 1.0, 1.0), brighter), float3(0.91, 0.98, 1.0), exposure);
                float3 blueOverlap = 1.0 - (1.0 - blueDarkReference) * (1.0 - blueTrail * opacity);
                // Balance only added trail light: a history buffer must never
                // darken the untouched backdrop, even when its samples faded.
                result = backdrop + balanceYellowDarkLight(max(result - backdrop, 0.0),
                    max(blueOverlap - blueDarkReference, 0.0));
            }
        } else {
            // Keep the old Blue Light screen-pass character, driven by local
            // overlap rather than separate offset strokes. First passes stay colored.
            float pigmentOpacity = opacity * (0.76 + 0.24 * exposure);
            result = mix(result, trailColor, pigmentOpacity);
            float3 screenLight = isYellowPreset > 0.5
                ? mix(yellowLightAccent, white, 0.80)
                : float3(0.80, 0.9059, 1.0); // Original Blue Light screen color.
            result = 1.0 - (1.0 - result) * (1.0 - screenLight * exposure * opacity * 0.42);
        }
    }

    float3 trailDelta=result-mainBase;
    if(dark) {
        // Same core/secondary/halo W and contact partition as accepted Dark.
        if(W>0.0) result=yellowReviewDarkContact(result,contact,physicalMain,M);
        if(contact.intersection>0.0)result=mix(result,yellowReviewGoldenHue(result,counterProtection),1.0-exp(-12.0*contact.intersection));
        return half4(half3(clamp(result,0.0,1.0)),1.0);
    }
    // Blue SUBSTRATE FIX algebra, colour-adapted using production Yellow only.
    float3 LightBase=correctedLightPigment(physicalMain,3.0,transmission);
    float3 shares=yellowReviewWaveShares(position,size,idleTime);
    float3 waveSource=yellowReviewLightSource(shares,W);
    // Same W/I/a response. Primary stays bright Yellow, existing secondary
    // and halo retain their warm colour progression instead of merging.
    float3 lightContactColor=yellowReviewLightPeak(shares);
    float3 appearance=LightBase*(1.0-contact.idle)
        +waveSource*(contact.idle-contact.intersection)
        +lightContactColor*contact.intersection;
    float a=1.0-exp(-4.0*contact.intersection);
    appearance=mix(clamp(appearance,0.0,1.0),lightContactColor,a);
    if(contact.intersection>0.0) {
        // Keep the accepted Light substrate colour reference; Dark late-MAIN
        // feathering must not propagate into this protected contact term.
        // Exact Blue substrate channel response in Yellow channel order.
        // Keep the SUBSTRATE FIX composition and its fields untouched.
        float3 DarkBase=float3(LightBase.r,blueDarkReference.g,blueDarkReference.r);
        float3 source=yellowReviewLightSource(shares,W);
        float3 DarkContact=clamp(DarkBase+lightContactColor*contact.frontReaction+
            idleContactLight(source,lightContactColor,contact),0.0,1.0);
        float3 beforeDark=appearance;
        float3 pigment=correctedLightPigment(1.0,3.0,transmission);
        float peripheral=(1.0-contact.coverage)*(1.0-contact.coverage);
        float3 substrateDelta=a*peripheral*max(min(beforeDark,pigment)-DarkBase,0.0);
        appearance=mix(appearance,DarkContact,a);
        appearance+=substrateDelta;
    }
    appearance+=(mainBase-LightBase)*(1.0-contact.idle)*(1.0-a);
    if(contact.intersection>0.0)appearance=mix(appearance,yellowReviewGoldenHue(clamp(appearance,0.0,1.0),0.0),a);
    appearance+=trailDelta;

    return half4(half3(clamp(appearance,0.0,1.0)),1.0);
}

}

namespace YellowLightMAIN {
// Yellow-only review overlay. Compile with the immutable accepted Blue source.
// Production Yellow colour stops; Yellow-only readout/contact corrections.
float3 yellowReviewDarkPalette(float sharedLightField,float progress) {
    // The accepted MAIN pose already settles before p=1. Production's old
    // endpoint hue/exposure compensation must not fire over this frozen pose.
    float3 blueDarkReference=float3(0.10,0.55,1.0)*sharedLightField;
    float warmth = clamp(sharedLightField / (0.20 + 0.58 + 0.54), 0.0, 1.0);
    float3 warmColor = mix(yellowDeepColor.rgb, yellowHotColor.rgb, warmth);
    float3 luminanceWeights = float3(0.2126, 0.7152, 0.0722);
    float referenceLuminance = dot(pow(clamp(blueDarkReference, 0.0, 1.0),
        float3(2.2)), luminanceWeights);
    float warmLuminance = dot(pow(warmColor, float3(2.2)), luminanceWeights);
    // Lift only the low-density colour toe. The existing bright maxima and
    // colour ratios remain pinned; no field, Gaussian or spatial blur changes.
    float toe=1.0-clamp(sharedLightField/(0.20+0.58+0.54),0.0,1.0);
    float late=segmentEase(progress,0.78,0.86);
    float lowDensity=1.0-segmentEase(sharedLightField,0.20,0.50);
    float colourFeather=1.0+0.35*toe*toe*toe;
    if(progress>0.78 && sharedLightField<0.50) colourFeather+=0.40*late*lowDensity*toe*toe*toe;
    float paletteExposure=1.12*pow(colourFeather,2.2);
    #ifdef QA_CONFIG_PALETTE
    // Comparison B only: production's density-to-colour curve; same MAIN field.
    return yellowDarkDensityPalette(sharedLightField);
#else
    float3 mapped=warmColor * pow(referenceLuminance * paletteExposure /
        max(warmLuminance, 0.00001), 1.0 / 2.2);
    // Same bounded cap as Blue's saturated channel; only the late R shoulder.
    if(progress>0.78) mapped.r=mix(mapped.r,qaNativeBlueCap(mapped.r),late);
    return mapped;
#endif
}
float3 yellowReviewTransmission() {
    float3 yellowLightOrange=mix(yellowMidColor.rgb,yellowHotColor.rgb,0.25);
    return float3(yellowLightOrange.r,mix(yellowMidColor.g,yellowHotColor.g,0.75),
        pow(yellowLightAccent.b,2.5));
}
// Colour partition of the EXISTING idleWaveDensity profiles. Geometry is
// copied verbatim only to recover primary / (primary+secondary+halo); W and I
// still come from the immutable physical field, including its exact clamps.
float yellowReviewPrimaryShare(float2 position,float2 size,float idleTime) {
    float2 p=position/max(size,float2(1.0))*float2(375.0,812.0);
    float cycle=smootherLiquid(fract(idleTime/3.0));
    float waveY=mix(-110.0,925.0,cycle);
    float width=mix(72.0,420.0,cycle);
    float thickness=mix(19.0,42.0,cycle);
    float dx=p.x-187.5;
    float arcY=waveY+(dx*dx)/max(width*1.72,1.0);
    float distanceToArc=p.y-arcY;
    float primary=exp(-pow(distanceToArc/thickness,2.0))*exp(-pow(dx/width,2.0));
    float secondary=exp(-pow((distanceToArc+72.0)/(thickness*1.35),2.0))*
        exp(-pow(dx/(width*1.18),2.0))*0.32;
    float halo=exp(-pow((p.y-waveY)/180.0,2.0))*
        exp(-pow(dx/max(width*1.18,1.0),2.0))*0.12;
    return primary/max(primary+secondary+halo,0.000001);
}
// Light-only colour metadata from the exact existing primary/secondary/halo.
// Keep the scalar function and all Dark calls unchanged for pixel identity.
float3 yellowReviewWaveShares(float2 position,float2 size,float idleTime) {
    float2 p=position/max(size,float2(1.0))*float2(375.0,812.0);
    float cycle=smootherLiquid(fract(idleTime/3.0));
    float waveY=mix(-110.0,925.0,cycle);
    float width=mix(72.0,420.0,cycle);
    float thickness=mix(19.0,42.0,cycle);
    float dx=p.x-187.5;
    float arcY=waveY+(dx*dx)/max(width*1.72,1.0);
    float distanceToArc=p.y-arcY;
    float primary=exp(-pow(distanceToArc/thickness,2.0))*exp(-pow(dx/width,2.0));
    float secondary=exp(-pow((distanceToArc+72.0)/(thickness*1.35),2.0))*
        exp(-pow(dx/(width*1.18),2.0))*0.32;
    float halo=exp(-pow((p.y-waveY)/180.0,2.0))*
        exp(-pow(dx/max(width*1.18,1.0),2.0))*0.12;
    return float3(primary,secondary,halo)/max(primary+secondary+halo,0.000001);
}
float3 yellowReviewLightSource(float3 shares,float W) {
    float3 primary=float3(yellowLightAccent.r,yellowLightAccent.g,0.0);
    // Only the existing primary colour response: a bright Yellow crest,
    // warmer gold mid-density shoulders. W and its spatial shape are exact.
    float primaryEnergy=clamp(W*shares.x/0.84,0.0,1.0);
    primary.g=mix(yellowMidColor.g,1.0,primaryEnergy);
    float3 secondary=yellowLightAccent;
    float3 halo=mix(yellowHotColor.rgb,float3(1.0),0.82);
    // The secondary formerly shared the almost-white .82 cream with halo;
    // it lost chroma against the Light background. Preserve its own gold.
    return primary*shares.x+secondary*shares.y+halo*shares.z;
}
float3 yellowReviewLightPeak(float3 shares) {
    // At full coverage I=W, the free-wave source cancels. The secondary
    // needs its own existing warm light maximum here as well; otherwise it
    // loses the B relief again inside MAIN despite a correct free pigment.
    float3 warmLight=mix(yellowHotColor.rgb,float3(1.0),0.82);
    // Reduce only the secondary's cream dilution, retaining the same
    // smooth secondary field and fully covered I=W response.
    float3 secondaryPeak=yellowLightAccent;
    return float3(1.0,1.0,0.0)*shares.x+secondaryPeak*shares.y+warmLight*shares.z;
}

float3 yellowReviewWaveSource(float primaryShare,bool light) {
    // Configured Yellow stops: a saturated gold primary with the existing
    // warm low-energy surround. No new support, wave, Gaussian or glow layer.
    float3 primary=light ? float3(yellowLightAccent.r,yellowLightAccent.g,0.0)
        : yellowLightAccent;
    float3 surround=light ? mix(yellowHotColor.rgb,float3(1.0),0.82)
        : float3(qaHistoricalYellowDarkWave(1.0).rgb);
    return mix(surround,primary,primaryShare);
}
float3 yellowReviewDarkContact(float3 base,IdleContact contact,float primaryShare,float counterProtection) {
    float3 source=yellowReviewWaveSource(primaryShare,false);
    // Yellow darkened by the existing counter backdrop reads olive. Warm
    // only that pre-existing shaded contact region; the unshaded peak stays Yellow.
    float3 contactColor=mix(float3(1.0,1.0,0.0),yellowLightAccent,
        clamp(counterProtection,0.0,1.0));
    float3 reactedMain=base+contactColor*contact.frontReaction;
    float3 light=idleContactLight(source,contactColor,contact);
    // Match Blue's additive union and ONLY its final RGB clamp. The old
    // component-wise orange bound clipped G to .70/.55 and erased the core.
    float3 composite=clamp(reactedMain+light,0.0,1.0);
    // Saturation can erase the pre-clamp warm tint (R=G=1). Reuse the
    // existing counter shadow and I response to adapt only that hue after
    // clipping; no geometry, independent light, new contour or G-channel cut.
    float ratio=composite.g/max(composite.r,0.000001);
    float shadedContact=segmentEase(sqrt(clamp(counterProtection,0.0,1.0)),0.06,0.36)*
        segmentEase(contact.intersection,0.0,0.12);
    float3 shadedGold=mix(yellowHotColor.rgb,yellowLightAccent,0.5);
    float3 warm=composite;
    // Monotone shoulder, like Blue's saturation cap: avoid a hue-selector
    // inversion that could leave a thin green rim between two warm regions.
    warm.g=composite.r*shadedGold.g*qaNativeBlueCap(ratio/shadedGold.g);
    warm.b=mix(composite.b,max(composite.b,composite.r*shadedGold.b),
        segmentEase(ratio,yellowMidColor.g,1.0));
    return mix(composite,warm,shadedContact);
}


half4 liquidYellowReviewBackground(
    float2 position,
    half4 color,
    float2 size,
    float progress,
    float tapPulse,
    float2 tapPoint,
    float2 previousTouchPoint,
    float swipePulse,
    float swipeStrength,
    float time,
    float progressSpeed,
    float fillGain,
    float waveStrength,
    float waveSpread,
    float topBloom,
    float whiteCore,
    float blueDepth,
    float dragWave,
    float shockStrength,
    float shockInteraction,
    float shockTrail,
    float waveCount,
    float themeStrength,
    float gradientColorIndex,
    float idleActivity,
    float idleTime,
    device const float *interactionSegments,
    int interactionFloatCount
) {
    if(abs(round(gradientColorIndex)-3.0)>0.5) {
        return liquidSpecBackground(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,themeStrength,gradientColorIndex,idleActivity,idleTime,interactionSegments,interactionFloatCount);
    }
    float2 safeSize=max(size,float2(1.0)),uv=position/safeSize;
    float4 physical=yellowReferenceContactFields(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,1.0,0.0,idleActivity,idleTime,interactionSegments,interactionFloatCount);
    float physicalMain=physical.x;
    float W=float(half(physical.y));
    IdleContact contact=sharedIdleContact(physicalMain,W);
    float primaryShare=yellowReviewPrimaryShare(position,size,idleTime);
    float3 transmission=yellowReviewTransmission();
    bool dark=themeStrength>0.5;
    // Query, do not rewrite, the exact accepted Blue MAIN display fields.
    float M=qaMainAtPose(uv,progress,time,dark);
    float3 mainBase=dark ? clamp(yellowReviewDarkPalette(M,progress)+physical.w,0.0,1.0)
        : correctedLightPigment(M,3.0,transmission);
    // Reuse Blue's original diffuse counter-protection pocket, with the same
    // field and 0.32 weight. Keep the production percentage/UI untouched.
    if(!dark) mainBase=mix(mainBase,float3(1.0),clamp(physical.z,0.0,1.0)*0.32);
    float3 result=mainBase;
    float counterProtection=physical.z;
    float darkTheme=step(0.5,themeStrength);
    float isYellowPreset=1.0;
    float3 white=float3(1.0),targetBlue=float3(0.10,0.55,1.0);
    float3 referenceCyan = float3(0.380, 0.910, 1.000);
    float3 yellowLightOrange=mix(yellowMidColor.rgb,yellowHotColor.rgb,0.25);
    float3 blueDarkReference=clamp(float3(.10,.55,1.0)*physicalMain,0.0,1.0);
    if (interactionFloatCount > 0) {
        float trail = interactionLightField(uv, safeSize.x / safeSize.y, interactionSegments, interactionFloatCount);
        float readability = 1.0 - 0.88 * counterProtection;
        // Exposure depends on local interaction accumulation, so a first pass
        // cannot start white merely because it crosses a bright progress band.
        float heat = trail;
        float brighter = 1.0 - exp(-max(heat - 0.35, 0.0) * 0.95);
        float excessHeat = max(heat - 1.45, 0.0);
        float exposure = 1.0 - exp(-excessHeat * excessHeat / 3.0);
        float3 trailColor;
        if (isYellowPreset > 0.5) {
            // Channel-wise exponential exposure used to push R and G towards
            // equality, leaving olive on black. Keep warm hue while light grows.
            float3 warm = darkTheme > 0.5
                ? mix(yellowDeepColor.rgb, min(yellowHotColor.rgb * 1.18, 1.0), brighter)
                : mix(yellowHotColor.rgb, yellowLightAccent, 0.48 + brighter * 0.52);
            float cream = smoothstep(0.70, 3.0, heat) * 0.75;
            if (darkTheme < 0.5) {
                // A broad orange interval separates yellow pigment from light,
                // making the trail readable even over a saturated yellow base.
                float orange = exp(-pow((heat - 0.85) / 0.90, 2.0)) *
                    (1.0 - exp(-heat * 2.0)) * 0.75;
                warm = mix(yellowLightAccent, yellowLightOrange, orange);
                cream = smoothstep(1.55, 3.50, heat) * 0.75;
                float accumulatedHeat = max(heat - 2.0, 0.0);
                exposure = 1.0 - exp(-accumulatedHeat * accumulatedHeat / 2.8);
            }
            warm = mix(warm, mix(yellowHotColor.rgb, white, 0.82), cream);
            trailColor = mix(warm, mix(yellowHotColor.rgb, white, 0.94), exposure);
        } else {
            // Reuse the cyan produced by the existing additive idle overlap.
            float3 overlapCyan = clamp(targetBlue + float3(0.14, 0.48, 1.0), 0.0, 1.0);
            float3 lightBlue = mix(targetBlue, mix(referenceCyan, overlapCyan, darkTheme), brighter);
            trailColor = mix(lightBlue, float3(0.91, 0.98, 1.0), exposure);
        }
        // Protect text through coverage, not heat: the mask must not turn a
        // hot white/cyan/cream trail into a different, muddy color at its edge.
        float opacity = (0.78 + 0.22 * exposure) * (1.0 - exp(-trail * 0.95)) * readability;
        if (darkTheme > 0.5) {
            float3 backdrop = result;
            result = 1.0 - (1.0 - result) * (1.0 - trailColor * opacity);
            if (isYellowPreset > 0.5) {
                // Same trail field, alpha and screen blending as Blue Dark;
                // only reduce color energy if the warm overlap is brighter.
                float3 blueTrail = mix(mix(float3(0.10, 0.55, 1.0),
                    float3(0.24, 1.0, 1.0), brighter), float3(0.91, 0.98, 1.0), exposure);
                float3 blueOverlap = 1.0 - (1.0 - blueDarkReference) * (1.0 - blueTrail * opacity);
                // Balance only added trail light: a history buffer must never
                // darken the untouched backdrop, even when its samples faded.
                result = backdrop + balanceYellowDarkLight(max(result - backdrop, 0.0),
                    max(blueOverlap - blueDarkReference, 0.0));
            }
        } else {
            // Keep the old Blue Light screen-pass character, driven by local
            // overlap rather than separate offset strokes. First passes stay colored.
            float pigmentOpacity = opacity * (0.76 + 0.24 * exposure);
            result = mix(result, trailColor, pigmentOpacity);
            float3 screenLight = isYellowPreset > 0.5
                ? mix(yellowLightAccent, white, 0.80)
                : float3(0.80, 0.9059, 1.0); // Original Blue Light screen color.
            result = 1.0 - (1.0 - result) * (1.0 - screenLight * exposure * opacity * 0.42);
        }
    }

    float3 trailDelta=result-mainBase;
    if(dark) {
        // Same core/secondary/halo W and contact partition as accepted Dark.
        if(W>0.0) result=yellowReviewDarkContact(result,contact,primaryShare,counterProtection);
        return half4(half3(clamp(result,0.0,1.0)),1.0);
    }
    // Blue SUBSTRATE FIX algebra, colour-adapted using production Yellow only.
    float3 LightBase=correctedLightPigment(physicalMain,3.0,transmission);
    float3 shares=yellowReviewWaveShares(position,size,idleTime);
    float3 waveSource=yellowReviewLightSource(shares,W);
    // Same W/I/a response. Primary stays bright Yellow, existing secondary
    // and halo retain their warm colour progression instead of merging.
    float3 lightContactColor=yellowReviewLightPeak(shares);
    float3 appearance=LightBase*(1.0-contact.idle)
        +waveSource*(contact.idle-contact.intersection)
        +lightContactColor*contact.intersection;
    float a=1.0-exp(-4.0*contact.intersection);
    appearance=mix(clamp(appearance,0.0,1.0),lightContactColor,a);
    if(contact.intersection>0.0) {
        // Keep the accepted Light substrate colour reference; Dark late-MAIN
        // feathering must not propagate into this protected contact term.
        float3 DarkBase=clamp(yellowReviewDarkPalette(physicalMain,0.0)+physical.w,0.0,1.0);
        // Yellow Light is an R=1 pigment. Importing DarkBase.r creates an
        // achromatic R trough (olive/brown), not useful yellow depth.
        DarkBase.r=LightBase.r;
        float3 source=yellowReviewWaveSource(primaryShare,false);
        // Preserve the current G energy/profile. Restore the existing soft
        // B progression of secondary/halo lost in the Dark reference tint.
        source.r=LightBase.r;
        // Free-wave G used to consume the same headroom as the I-driven
        // Yellow maximum. Use the existing Hot stop only in the primary
        // reference source; I/peak energy stays intact and secondary is free.
        source.g=mix(source.g,yellowHotColor.g,shares.x);
        source.b=waveSource.b;
        float3 DarkContact=clamp(DarkBase+lightContactColor*contact.frontReaction+
            idleContactLight(source,lightContactColor,contact),0.0,1.0);
        float3 beforeDark=appearance;
        float3 pigment=correctedLightPigment(1.0,3.0,transmission);
        float peripheral=(1.0-contact.coverage)*(1.0-contact.coverage);
        float3 substrateDelta=a*peripheral*max(min(beforeDark,pigment)-DarkBase,0.0);
        appearance=mix(appearance,DarkContact,a);
        appearance+=substrateDelta;
    }
    appearance+=(mainBase-LightBase)*(1.0-contact.idle)*(1.0-a);
    appearance+=trailDelta;
    return half4(half3(clamp(appearance,0.0,1.0)),1.0);
}

}

namespace YellowDarkContact {
// Yellow-only review overlay. Compile with the immutable accepted Blue source.
// Production Yellow colour stops; Yellow-only readout/contact corrections.
float3 yellowReviewSubstratePalette(float sharedLightField,float progress) {
    // The accepted MAIN pose already settles before p=1. Production's old
    // endpoint hue/exposure compensation must not fire over this frozen pose.
    float3 blueDarkReference=float3(0.10,0.55,1.0)*sharedLightField;
    float warmth = clamp(sharedLightField / (0.20 + 0.58 + 0.54), 0.0, 1.0);
    float3 warmColor = mix(yellowDeepColor.rgb, yellowHotColor.rgb, warmth);
    float3 luminanceWeights = float3(0.2126, 0.7152, 0.0722);
    float referenceLuminance = dot(pow(clamp(blueDarkReference, 0.0, 1.0),
        float3(2.2)), luminanceWeights);
    float warmLuminance = dot(pow(warmColor, float3(2.2)), luminanceWeights);
    // Lift only the low-density colour toe. The existing bright maxima and
    // colour ratios remain pinned; no field, Gaussian or spatial blur changes.
    float toe=1.0-clamp(sharedLightField/(0.20+0.58+0.54),0.0,1.0);
    float late=segmentEase(progress,0.78,0.86);
    float lowDensity=1.0-segmentEase(sharedLightField,0.20,0.50);
    float colourFeather=1.0+0.35*toe*toe*toe;
    if(progress>0.78 && sharedLightField<0.50) colourFeather+=0.40*late*lowDensity*toe*toe*toe;
    float paletteExposure=1.12*pow(colourFeather,2.2);
    #if 0
    // Comparison B only: production's density-to-colour curve; same MAIN field.
    return yellowDarkDensityPalette(sharedLightField);
#else
    float3 mapped=warmColor * pow(referenceLuminance * paletteExposure /
        max(warmLuminance, 0.00001), 1.0 / 2.2);
    // Same bounded cap as Blue's saturated channel; only the late R shoulder.
    if(progress>0.78) mapped.r=mix(mapped.r,qaNativeBlueCap(mapped.r),late);
    return mapped;
#endif
}
// Authorized Yellow-only removal of the restored outer residual.
// Exact accepted pose/clock/profiles. Only the restored outer term respects
// its EXISTING completion mask, as it already does in the Light readout.
// The immutable Blue implementation and physical CONTACT fields stay intact.
float yellowReviewDarkMainAtPose(float2 uv,float progress,float time) {
    if(progress<=0.76) return qaMainAtPose(uv,progress,time,true);
    uv.y+=(102.0/844.0)*segmentEase(progress,0.85,1.0);
    float p=qaMainPoseProgress(progress),t=qaMainPoseTime(progress,time);
    float center,width;qaMainPoseBand(p,center,width);
    float L=qaAcceptedLightShapeDensityImpl(uv,p,t,center,width,true,true,progress);
    float D=qaAcceptedDarkShapeDensity(uv,p,t,center,width);
    float transfer=segmentEase(p,.70,.76)*(1.0-segmentEase(p,.94,1.0));
    float x=uv.x,mx=1.0-x;
    float w=sin(x*5.7+t*.11)*.018+sin(x*10.4-t*.08+1.2)*.008;
    float mw=sin(mx*5.7+t*.11)*.018+sin(mx*10.4-t*.08+1.2)*.008;
    w=mix(w,(w+mw)*.5,segmentEase(p,.50,.76));
    return qaDarkLateFade(mix(D,L,transfer),(uv.y+w-center)/width,progress);
}
// Both Dark alternatives use ONE scalar exposure. Only chroma stops differ.
// No per-channel clipping, progress-dependent toe boost or alternate density curve.
float3 yellowReviewDarkPalette(float M,float progress) {
    float q=clamp(M/1.32,0.0,1.0);
    float3 current=mix(yellowDeepColor.rgb,yellowHotColor.rgb,q);
    float3 hue=current;
#ifdef QA_CONFIG_PALETTE
    // Configured chroma follows exposure: dark orange shadows, gold crest.
    // The former density exponential reached Accent while still in shadow.
    float exposurePosition=clamp(M/1.32,0.0,1.0);
    float lower=segmentEase(exposurePosition,0.0,0.50);
    float upper=segmentEase(exposurePosition,0.50,1.0);
    hue=mix(mix(yellowDeepColor.rgb,yellowHotColor.rgb,lower),yellowLightAccent,upper);
#endif
    float3 w=float3(0.2126,0.7152,0.0722);
    // Unclipped Blue reference avoids the B=1 derivative corner at M=1.
    // A common smooth peak cap preserves colour ratios and bright maxima.
    float reference=dot(pow(float3(.10,.55,1.0)*max(M,0.0),float3(2.2)),w);
    float amplitude=pow(reference*1.12/max(dot(pow(current,float3(2.2)),w),.00001),1.0/2.2);
    float commonAmplitude=qaNativeBlueCap(amplitude);
    // Use the common exposure without re-darkening configured gold to the
    // CURRENT palette's luminance. Chroma brightness remains palette-specific.
    return hue*commonAmplitude;
}
float3 yellowReviewTransmission() {
    float3 yellowLightOrange=mix(yellowMidColor.rgb,yellowHotColor.rgb,0.25);
    return float3(yellowLightOrange.r,mix(yellowMidColor.g,yellowHotColor.g,0.75),
        pow(yellowLightAccent.b,2.5));
}
// Colour partition of the EXISTING idleWaveDensity profiles. Geometry is
// copied verbatim only to recover primary / (primary+secondary+halo); W and I
// still come from the immutable physical field, including its exact clamps.
float yellowReviewPrimaryShare(float2 position,float2 size,float idleTime) {
    float2 p=position/max(size,float2(1.0))*float2(375.0,812.0);
    float cycle=smootherLiquid(fract(idleTime/3.0));
    float waveY=mix(-110.0,925.0,cycle);
    float width=mix(72.0,420.0,cycle);
    float thickness=mix(19.0,42.0,cycle);
    float dx=p.x-187.5;
    float arcY=waveY+(dx*dx)/max(width*1.72,1.0);
    float distanceToArc=p.y-arcY;
    float primary=exp(-pow(distanceToArc/thickness,2.0))*exp(-pow(dx/width,2.0));
    float secondary=exp(-pow((distanceToArc+72.0)/(thickness*1.35),2.0))*
        exp(-pow(dx/(width*1.18),2.0))*0.32;
    float halo=exp(-pow((p.y-waveY)/180.0,2.0))*
        exp(-pow(dx/max(width*1.18,1.0),2.0))*0.12;
    return primary/max(primary+secondary+halo,0.000001);
}
// Light-only colour metadata from the exact existing primary/secondary/halo.
// Keep the scalar function and all Dark calls unchanged for pixel identity.
float3 yellowReviewWaveShares(float2 position,float2 size,float idleTime) {
    float2 p=position/max(size,float2(1.0))*float2(375.0,812.0);
    float cycle=smootherLiquid(fract(idleTime/3.0));
    float waveY=mix(-110.0,925.0,cycle);
    float width=mix(72.0,420.0,cycle);
    float thickness=mix(19.0,42.0,cycle);
    float dx=p.x-187.5;
    float arcY=waveY+(dx*dx)/max(width*1.72,1.0);
    float distanceToArc=p.y-arcY;
    float primary=exp(-pow(distanceToArc/thickness,2.0))*exp(-pow(dx/width,2.0));
    float secondary=exp(-pow((distanceToArc+72.0)/(thickness*1.35),2.0))*
        exp(-pow(dx/(width*1.18),2.0))*0.32;
    float halo=exp(-pow((p.y-waveY)/180.0,2.0))*
        exp(-pow(dx/max(width*1.18,1.0),2.0))*0.12;
    return float3(primary,secondary,halo)/max(primary+secondary+halo,0.000001);
}
// Match the accepted Blue channel response, exchanging its blue energy
// axis for Yellow's red axis. Same W/I and same positive relief increment.
// Blue source (.14,.48,1), peak (.24,1,1): Yellow (1,.48,.14), (1,1,.24).
// Constants come from the protected response, not a new spatial light layer.
float3 yellowReviewLightSource(float3 shares,float W) {
    return float3(1.0,0.48,0.14);
}
float3 yellowReviewLightPeak(float3 shares) {
    return float3(1.0,1.0,0.24);
}
// Hue-only warm gamut readout. The unchanged caption backdrop can make
// pure R=G yellow look olive. Preserve HSV V and S, unlike the previous
// OKLab/max-linear normalization that suppressed the luminous crest.
float3 yellowReviewHSV(float3 rgb) {
    float hi=max(rgb.r,max(rgb.g,rgb.b)),lo=min(rgb.r,min(rgb.g,rgb.b));
    float d=hi-lo,h=0.0;
    if(d>0.000001) {
        if(hi==rgb.r)h=(rgb.g-rgb.b)/d;
        else if(hi==rgb.g)h=2.0+(rgb.b-rgb.r)/d;
        else h=4.0+(rgb.r-rgb.g)/d;
        h=fract(h/6.0+1.0);
    }
    return float3(h,hi>0.000001 ? d/hi:0.0,hi);
}
float3 yellowReviewGoldenHue(float3 rgb,float counterProtection) {
    float3 hsv=yellowReviewHSV(rgb);
    // Existing configured Accent to the bright yellow endpoint. Only the
    // upper yellow hue shoulder changes, never V/S or an independent channel.
    // Keep configured golden hue when the protected UI darkens the crest.
    // The former added lemon endpoint became olive under the caption shade.
    float brightGold=yellowReviewHSV(float3(1.0,0.82,0.0)).x;
    // Existing Dark counter protection predicts the protected UI shade.
    // Warm only that shaded contact hue; unshaded luminous crest stays yellow.
    float shadedOrange=yellowReviewHSV(float3(1.0,0.72,0.0)).x;
    float limit=mix(brightGold,shadedOrange,
        // Reuse the existing readability field and the prior accepted colour shoulder.
        segmentEase(sqrt(clamp(counterProtection,0.0,1.0)),0.06,0.36));
    if(hsv.x<0.25) {
        float excess=max(hsv.x-limit,0.0);
        hsv.x=hsv.x-excess+0.002*(1.0-exp(-excess/0.002));
    }
    float3 p=abs(fract(hsv.x+float3(0.0,2.0/3.0,1.0/3.0))*6.0-3.0);
    return hsv.z*mix(float3(1.0),clamp(p-1.0,0.0,1.0),hsv.y);
}
float3 yellowReviewDarkContact(float3 base,IdleContact contact,float physicalMain,float displayMain) {
    // The reference's additive contact response, with the energy axes exchanged.
    // Positive low-channel increment restores relief; source G=.48 leaves
    // room for the I-driven G=1 crest instead of saturating the entire halo.
    // Free emitter anchor: #FF8C00. Overlap peak and W/I are preserved.
    float3 source=float3(1.0,140.0/255.0,0.0),peak=float3(1.0,1.0,.24);
    return clamp(base+peak*contact.frontReaction+
        idleContactLight(source,peak,contact),0.0,1.0);
}


half4 liquidYellowReviewBackground(
    float2 position,
    half4 color,
    float2 size,
    float progress,
    float tapPulse,
    float2 tapPoint,
    float2 previousTouchPoint,
    float swipePulse,
    float swipeStrength,
    float time,
    float progressSpeed,
    float fillGain,
    float waveStrength,
    float waveSpread,
    float topBloom,
    float whiteCore,
    float blueDepth,
    float dragWave,
    float shockStrength,
    float shockInteraction,
    float shockTrail,
    float waveCount,
    float themeStrength,
    float gradientColorIndex,
    float idleActivity,
    float idleTime,
    device const float *interactionSegments,
    int interactionFloatCount
) {
    if(abs(round(gradientColorIndex)-3.0)>0.5) {
        return liquidSpecBackground(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,themeStrength,gradientColorIndex,idleActivity,idleTime,interactionSegments,interactionFloatCount);
    }
    float2 safeSize=max(size,float2(1.0)),uv=position/safeSize;
    float4 physical=yellowReferenceContactFields(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,1.0,0.0,idleActivity,idleTime,interactionSegments,interactionFloatCount);
    float physicalMain=physical.x;
    float W=float(half(physical.y));
    IdleContact contact=sharedIdleContact(physicalMain,W);
    float primaryShare=yellowReviewPrimaryShare(position,size,idleTime);
    float3 transmission=yellowReviewTransmission();
    bool dark=themeStrength>0.5;
    // Query, do not rewrite, the exact accepted Blue MAIN display fields.
    float M=dark ? yellowReviewDarkMainAtPose(uv,progress,time) : qaMainAtPose(uv,progress,time,false);
    float3 mainBase=dark ? clamp(yellowReviewDarkPalette(M,progress)+physical.w,0.0,1.0)
        : correctedLightPigment(M,3.0,transmission);
    // Reuse Blue's original diffuse counter-protection pocket, with the same
    // field and 0.32 weight. Keep the production percentage/UI untouched.
    if(!dark) mainBase=mix(mainBase,float3(1.0),clamp(physical.z,0.0,1.0)*0.32);
    float3 result=mainBase;
    float counterProtection=physical.z;
    float darkTheme=step(0.5,themeStrength);
    float isYellowPreset=1.0;
    float3 white=float3(1.0),targetBlue=float3(0.10,0.55,1.0);
    float3 referenceCyan = float3(0.380, 0.910, 1.000);
    float3 yellowLightOrange=mix(yellowMidColor.rgb,yellowHotColor.rgb,0.25);
    float3 blueDarkReference=clamp(float3(.10,.55,1.0)*physicalMain,0.0,1.0);
    if (interactionFloatCount > 0) {
        float trail = interactionLightField(uv, safeSize.x / safeSize.y, interactionSegments, interactionFloatCount);
        float readability = 1.0 - 0.88 * counterProtection;
        // Exposure depends on local interaction accumulation, so a first pass
        // cannot start white merely because it crosses a bright progress band.
        float heat = trail;
        float brighter = 1.0 - exp(-max(heat - 0.35, 0.0) * 0.95);
        float excessHeat = max(heat - 1.45, 0.0);
        float exposure = 1.0 - exp(-excessHeat * excessHeat / 3.0);
        float3 trailColor;
        if (isYellowPreset > 0.5) {
            // Channel-wise exponential exposure used to push R and G towards
            // equality, leaving olive on black. Keep warm hue while light grows.
            float3 warm = darkTheme > 0.5
                ? mix(yellowDeepColor.rgb, min(yellowHotColor.rgb * 1.18, 1.0), brighter)
                : mix(yellowHotColor.rgb, yellowLightAccent, 0.48 + brighter * 0.52);
            float cream = smoothstep(0.70, 3.0, heat) * 0.75;
            if (darkTheme < 0.5) {
                // A broad orange interval separates yellow pigment from light,
                // making the trail readable even over a saturated yellow base.
                float orange = exp(-pow((heat - 0.85) / 0.90, 2.0)) *
                    (1.0 - exp(-heat * 2.0)) * 0.75;
                warm = mix(yellowLightAccent, yellowLightOrange, orange);
                cream = smoothstep(1.55, 3.50, heat) * 0.75;
                float accumulatedHeat = max(heat - 2.0, 0.0);
                exposure = 1.0 - exp(-accumulatedHeat * accumulatedHeat / 2.8);
            }
            warm = mix(warm, mix(yellowHotColor.rgb, white, 0.82), cream);
            trailColor = mix(warm, mix(yellowHotColor.rgb, white, 0.94), exposure);
        } else {
            // Reuse the cyan produced by the existing additive idle overlap.
            float3 overlapCyan = clamp(targetBlue + float3(0.14, 0.48, 1.0), 0.0, 1.0);
            float3 lightBlue = mix(targetBlue, mix(referenceCyan, overlapCyan, darkTheme), brighter);
            trailColor = mix(lightBlue, float3(0.91, 0.98, 1.0), exposure);
        }
        // Protect text through coverage, not heat: the mask must not turn a
        // hot white/cyan/cream trail into a different, muddy color at its edge.
        float opacity = (0.78 + 0.22 * exposure) * (1.0 - exp(-trail * 0.95)) * readability;
        if (darkTheme > 0.5) {
            float3 backdrop = result;
            result = 1.0 - (1.0 - result) * (1.0 - trailColor * opacity);
            if (isYellowPreset > 0.5) {
                // Same trail field, alpha and screen blending as Blue Dark;
                // only reduce color energy if the warm overlap is brighter.
                float3 blueTrail = mix(mix(float3(0.10, 0.55, 1.0),
                    float3(0.24, 1.0, 1.0), brighter), float3(0.91, 0.98, 1.0), exposure);
                float3 blueOverlap = 1.0 - (1.0 - blueDarkReference) * (1.0 - blueTrail * opacity);
                // Balance only added trail light: a history buffer must never
                // darken the untouched backdrop, even when its samples faded.
                result = backdrop + balanceYellowDarkLight(max(result - backdrop, 0.0),
                    max(blueOverlap - blueDarkReference, 0.0));
            }
        } else {
            // Keep the old Blue Light screen-pass character, driven by local
            // overlap rather than separate offset strokes. First passes stay colored.
            float pigmentOpacity = opacity * (0.76 + 0.24 * exposure);
            result = mix(result, trailColor, pigmentOpacity);
            float3 screenLight = isYellowPreset > 0.5
                ? mix(yellowLightAccent, white, 0.80)
                : float3(0.80, 0.9059, 1.0); // Original Blue Light screen color.
            result = 1.0 - (1.0 - result) * (1.0 - screenLight * exposure * opacity * 0.42);
        }
    }

    float3 trailDelta=result-mainBase;
    if(dark) {
        if(W<=0.0)return half4(half3(result),1.0);
        // Local CONTACT colour only. Frozen MAIN and additive/gamut algebra
        // remain intact; no text protection or new light layer is introduced.
        const float3 freeCore=float3(1.0,140.0/255.0,0.0); // #FF8C00
        const float3 overlapCore=float3(1.0,221.0/255.0,45.0/255.0); // #FFDD2D
        float colourContact=segmentEase(contact.coverage,0.0,0.12);
        float3 source=mix(freeCore,overlapCore,colourContact);
        float3 composite=clamp(mainBase+source*W,0.0,1.0);
        // Interpolate the existing additive G ramp all the way to its fixed
        // Gold endpoint, with a horizontal tangent there. R/B are untouched.
        // Unlike a narrow soft-min, this removes the abrupt hue plateau.
        float capG=overlapCore.g*composite.r;
        float baseG=min(mainBase.g,capG);
        float gap=max(capG-baseG,0.000001);
        float t=clamp((composite.g-baseG)/gap,0.0,1.0);
        float joined=t+t*t-t*t*t;
        composite=min(composite,overlapCore*composite.r);
        float joinedG=baseG+gap*joined;
        float feather=0.20*clamp(W,0.0,1.0)*(1.0-segmentEase(W,0.60,0.95))*composite.r;
        float h=max(feather-abs(clamp(mainBase.g+source.g*W,0.0,1.0)-capG),0.0)/max(feather,.000001);
        float originalG=min(clamp(mainBase.g+source.g*W,0.0,1.0),capG)-h*h*feather*.25;
        float shoulder=(1.0-segmentEase(W,0.78,0.839))*segmentEase(composite.r,0.85,0.98)*segmentEase(contact.intersection,0.04,0.18);
        composite.g=mix(originalG,joinedG,shoulder);
        float3 blueProfile=float3(liquidSpecBackground(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,1.0,0.0,idleActivity,idleTime,interactionSegments,0).rgb);
        // Match the frozen Blue CONTACT intensity only where its existing
        // W/I response is present. One scalar preserves every RGB ratio;
        // accepted fully exposed gold pixels (V=1) cannot change.
        float oldValue=max(composite.r,max(composite.g,composite.b));
        float targetValue=max(blueProfile.r,max(blueProfile.g,blueProfile.b));
        float weight=1.0-(1.0-W)*exp(-4.0*contact.intersection);
        float newValue=mix(oldValue,max(oldValue,targetValue),weight);
        composite*=newValue/max(oldValue,.000001);
        return half4(half3(clamp(composite+trailDelta,0.0,1.0)),1.0);
    }
    // Blue SUBSTRATE FIX algebra, colour-adapted using production Yellow only.
    float3 LightBase=correctedLightPigment(physicalMain,3.0,transmission);
    float3 shares=yellowReviewWaveShares(position,size,idleTime);
    float3 waveSource=yellowReviewLightSource(shares,W);
    // Same W/I/a response. Primary stays bright Yellow, existing secondary
    // and halo retain their warm colour progression instead of merging.
    float3 lightContactColor=yellowReviewLightPeak(shares);
    float3 appearance=LightBase*(1.0-contact.idle)
        +waveSource*(contact.idle-contact.intersection)
        +lightContactColor*contact.intersection;
    float a=1.0-exp(-4.0*contact.intersection);
    appearance=mix(clamp(appearance,0.0,1.0),lightContactColor,a);
    if(contact.intersection>0.0) {
        // Keep the accepted Light substrate colour reference; Dark late-MAIN
        // feathering must not propagate into this protected contact term.
        // Exact Blue substrate channel response in Yellow channel order.
        // Keep the SUBSTRATE FIX composition and its fields untouched.
        float3 DarkBase=float3(LightBase.r,blueDarkReference.g,blueDarkReference.r);
        float3 source=yellowReviewLightSource(shares,W);
        float3 DarkContact=clamp(DarkBase+lightContactColor*contact.frontReaction+
            idleContactLight(source,lightContactColor,contact),0.0,1.0);
        float3 beforeDark=appearance;
        float3 pigment=correctedLightPigment(1.0,3.0,transmission);
        float peripheral=(1.0-contact.coverage)*(1.0-contact.coverage);
        float3 substrateDelta=a*peripheral*max(min(beforeDark,pigment)-DarkBase,0.0);
        appearance=mix(appearance,DarkContact,a);
        appearance+=substrateDelta;
    }
    appearance+=(mainBase-LightBase)*(1.0-contact.idle)*(1.0-a);
    if(contact.intersection>0.0)appearance=mix(appearance,yellowReviewGoldenHue(clamp(appearance,0.0,1.0),0.0),a);
    appearance+=trailDelta;

    return half4(half3(clamp(appearance,0.0,1.0)),1.0);
}

}

namespace YellowLightContact {
// New independent Yellow QA. All scalar geometry, timing and interaction fields are immutable.
// Authorized Yellow-only removal of the restored outer residual.
// Exact accepted pose/clock/profiles. Only the restored outer term respects
// its EXISTING completion mask, as it already does in the Light readout.
// The immutable Blue implementation and physical CONTACT fields stay intact.
float yellowReviewDarkMainAtPose(float2 uv,float progress,float time) {
    if(progress<=0.76) return qaMainAtPose(uv,progress,time,true);
    uv.y+=(102.0/844.0)*segmentEase(progress,0.85,1.0);
    float p=qaMainPoseProgress(progress),t=qaMainPoseTime(progress,time);
    float center,width;qaMainPoseBand(p,center,width);
    float L=qaAcceptedLightShapeDensityImpl(uv,p,t,center,width,true,true,progress);
    float D=qaAcceptedDarkShapeDensity(uv,p,t,center,width);
    float transfer=segmentEase(p,.70,.76)*(1.0-segmentEase(p,.94,1.0));
    float x=uv.x,mx=1.0-x;
    float w=sin(x*5.7+t*.11)*.018+sin(x*10.4-t*.08+1.2)*.008;
    float mw=sin(mx*5.7+t*.11)*.018+sin(mx*10.4-t*.08+1.2)*.008;
    w=mix(w,(w+mw)*.5,segmentEase(p,.50,.76));
    return qaDarkLateFade(mix(D,L,transfer),(uv.y+w-center)/width,progress);
}
// QA-only perceptual warm readout of the accepted Blue radiance.
// IEC sRGB transfer. Gamut compression reduces chroma at constant OKLab L;
// no HSV V substitution, RGB hue clipping, exposure renormalization or blur.
float3 amberDecode(float3 c) {
    c=max(c,float3(0));
    return select(pow((c+0.055)/1.055,float3(2.4)),c/12.92,c<=0.04045);
}
float3 amberEncode(float3 c) {
    c=max(c,float3(0));
    return select(1.055*pow(c,float3(1.0/2.4))-0.055,c*12.92,c<=0.0031308);
}
float3 amberLab(float3 rgb) {
    float3 c=amberDecode(rgb);
    float3 lms=float3(dot(c,float3(.4122214708,.5363325363,.0514459929)),
        dot(c,float3(.2119034982,.6806995451,.1073969566)),
        dot(c,float3(.0883024619,.2817188376,.6299787005)));
    lms=pow(max(lms,float3(0)),float3(1.0/3.0));
    return float3(dot(lms,float3(.2104542553,.7936177850,-.0040720468)),
        dot(lms,float3(1.9779984951,-2.4285922050,.4505937099)),
        dot(lms,float3(.0259040371,.7827717662,-.8086757660)));
}
float3 amberLinear(float3 lab) {
    float3 v=float3(lab.x+.3963377774*lab.y+.2158037573*lab.z,
        lab.x-.1055613458*lab.y-.0638541728*lab.z,
        lab.x-.0894841775*lab.y-1.2914855480*lab.z);v=v*v*v;
    return float3(dot(v,float3(4.0767416621,-3.3077115913,.2309699292)),
        dot(v,float3(-1.2684380046,2.6097574011,-.3413193965)),
        dot(v,float3(-.0041960863,-.7034186147,1.7076147010)));
}
float amberHue(float3 rgb){float3 l=amberLab(rgb);return atan2(l.z,l.y);}
float3 amberGamut(float3 lab) {
    float L=clamp(lab.x,0.0,1.0),C=length(lab.yz);
    if(C<0.000001)return amberEncode(float3(L*L*L));
    float2 direction=lab.yz/C;
    float lo=0.0,hi=0.5;
    for(int i=0;i<16;i++) {
        float mid=(lo+hi)*0.5;
        float3 rgb=amberLinear(float3(L,direction*mid));
        if(all(rgb>=0.0)&&all(rgb<=1.0))lo=mid;else hi=mid;
    }
    float safeC=max(lo,0.000001);
    // Idempotent gamut projection: retain every already-displayable colour.
    // Only out-of-gamut chroma is reduced; re-evaluation cannot bleach it.
    float mappedC=min(C,safeC);
    return clamp(amberEncode(amberLinear(float3(L,direction*mappedC))),0.0,1.0);
}
float amberTargetHue(float L,bool contact) {
    float deep=amberHue(yellowDeepColor.rgb),mid=amberHue(yellowMidColor.rgb),hot=amberHue(yellowHotColor.rgb);
    // T-Pay samples: shadow 49-52 degrees, orange body ~58, gold maxima ~80.
    // Existing Deep/Mid/Hot are 43.49 / 58.40 / 77.69 degrees in OKLCH.
#ifdef QA_CONFIG_PALETTE
    float h=mix(deep,mid,segmentEase(L,.15,.70));
    return mix(h,hot,segmentEase(L,.70,.87));
#else
    return mix(mid,hot,segmentEase(L,.70,.87));
#endif
}
float3 amberTargetLab(float3 reference,bool contact) {
    float3 lab=amberLab(clamp(reference,0.0,1.0));
    float C=length(lab.yz),h=amberTargetHue(lab.x,contact);
    return float3(lab.x,C*cos(h),C*sin(h));
}
// Linear change of the accepted Blue emitter basis. Black and white are fixed,
// and the native Blue core/halo channel ramps retain their full dynamic range.
// Hot.g is the production Yellow warm anchor, not an output-channel clamp.
float3 amberContactReadout(float3 c,bool light=false) {
    float gold=segmentEase(c.g,.60,1.0);
    float warmth=light ? mix(yellowHotColor.g,yellowLightAccent.g,gold) : yellowHotColor.g;
    return float3(c.b,mix(c.r,c.g,warmth),c.r);
}
float3 amberReadout(float3 reference,bool contact) {
    return amberGamut(amberTargetLab(reference,contact));
}
float3 amberBlueMain(float M,float grain) {
    return clamp(float3(.10*M,.55*M,qaNativeBlueCap(M))+grain,0.0,1.0);
}
float3 yellowReviewDarkPalette(float M,float progress) {
    return amberReadout(amberBlueMain(M,0.0),false);
}
float3 yellowReviewTransmission() {
    return float3(1.0,mix(yellowMidColor.g,yellowHotColor.g,0.75),pow(yellowLightAccent.b,2.5));
}

half4 liquidYellowReviewBackground(
    float2 position,
    half4 color,
    float2 size,
    float progress,
    float tapPulse,
    float2 tapPoint,
    float2 previousTouchPoint,
    float swipePulse,
    float swipeStrength,
    float time,
    float progressSpeed,
    float fillGain,
    float waveStrength,
    float waveSpread,
    float topBloom,
    float whiteCore,
    float blueDepth,
    float dragWave,
    float shockStrength,
    float shockInteraction,
    float shockTrail,
    float waveCount,
    float themeStrength,
    float gradientColorIndex,
    float idleActivity,
    float idleTime,
    device const float *interactionSegments,
    int interactionFloatCount
) {
    if(abs(round(gradientColorIndex)-3.0)>0.5) {
        return liquidSpecBackground(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,themeStrength,gradientColorIndex,idleActivity,idleTime,interactionSegments,interactionFloatCount);
    }
    float2 safeSize=max(size,float2(1.0)),uv=position/safeSize;
    float4 physical=yellowReferenceContactFields(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,1.0,0.0,idleActivity,idleTime,interactionSegments,interactionFloatCount);
    float physicalMain=physical.x;
    float W=float(half(physical.y));
    IdleContact contact=sharedIdleContact(physicalMain,W);
    float3 transmission=yellowReviewTransmission();
    bool dark=themeStrength>0.5;
    // Query, do not rewrite, the exact accepted Blue MAIN display fields.
    float M=dark ? yellowReviewDarkMainAtPose(uv,progress,time) : qaMainAtPose(uv,progress,time,false);
    float3 mainBase=dark ? amberReadout(amberBlueMain(M,physical.w),false)
        : correctedLightPigment(M,3.0,transmission);
    // Reuse Blue's original diffuse counter-protection pocket, with the same
    // field and 0.32 weight. Keep the production percentage/UI untouched.
    if(!dark) mainBase=mix(mainBase,float3(1.0),clamp(physical.z,0.0,1.0)*0.32);
    float3 result=mainBase;
    float counterProtection=physical.z;
    float darkTheme=step(0.5,themeStrength);
    float isYellowPreset=1.0;
    float3 white=float3(1.0),targetBlue=float3(0.10,0.55,1.0);
    float3 referenceCyan = float3(0.380, 0.910, 1.000);
    float3 yellowLightOrange=mix(yellowMidColor.rgb,yellowHotColor.rgb,0.25);
    float3 blueDarkReference=clamp(float3(.10,.55,1.0)*physicalMain,0.0,1.0);
    if (interactionFloatCount > 0) {
        float trail = interactionLightField(uv, safeSize.x / safeSize.y, interactionSegments, interactionFloatCount);
        float readability = 1.0 - 0.88 * counterProtection;
        // Exposure depends on local interaction accumulation, so a first pass
        // cannot start white merely because it crosses a bright progress band.
        float heat = trail;
        float brighter = 1.0 - exp(-max(heat - 0.35, 0.0) * 0.95);
        float excessHeat = max(heat - 1.45, 0.0);
        float exposure = 1.0 - exp(-excessHeat * excessHeat / 3.0);
        float3 trailColor;
        if (isYellowPreset > 0.5) {
            // Channel-wise exponential exposure used to push R and G towards
            // equality, leaving olive on black. Keep warm hue while light grows.
            float3 warm = darkTheme > 0.5
                ? mix(yellowDeepColor.rgb, min(yellowHotColor.rgb * 1.18, 1.0), brighter)
                : mix(yellowHotColor.rgb, yellowLightAccent, 0.48 + brighter * 0.52);
            float cream = smoothstep(0.70, 3.0, heat) * 0.75;
            if (darkTheme < 0.5) {
                // A broad orange interval separates yellow pigment from light,
                // making the trail readable even over a saturated yellow base.
                float orange = exp(-pow((heat - 0.85) / 0.90, 2.0)) *
                    (1.0 - exp(-heat * 2.0)) * 0.75;
                warm = mix(yellowLightAccent, yellowLightOrange, orange);
                cream = smoothstep(1.55, 3.50, heat) * 0.75;
                float accumulatedHeat = max(heat - 2.0, 0.0);
                exposure = 1.0 - exp(-accumulatedHeat * accumulatedHeat / 2.8);
            }
            warm = mix(warm, mix(yellowHotColor.rgb, white, 0.82), cream);
            trailColor = mix(warm, mix(yellowHotColor.rgb, white, 0.94), exposure);
        } else {
            // Reuse the cyan produced by the existing additive idle overlap.
            float3 overlapCyan = clamp(targetBlue + float3(0.14, 0.48, 1.0), 0.0, 1.0);
            float3 lightBlue = mix(targetBlue, mix(referenceCyan, overlapCyan, darkTheme), brighter);
            trailColor = mix(lightBlue, float3(0.91, 0.98, 1.0), exposure);
        }
        // Protect text through coverage, not heat: the mask must not turn a
        // hot white/cyan/cream trail into a different, muddy color at its edge.
        float opacity = (0.78 + 0.22 * exposure) * (1.0 - exp(-trail * 0.95)) * readability;
        if (darkTheme > 0.5) {
            float3 backdrop = result;
            result = 1.0 - (1.0 - result) * (1.0 - trailColor * opacity);
            if (isYellowPreset > 0.5) {
                // Same trail field, alpha and screen blending as Blue Dark;
                // only reduce color energy if the warm overlap is brighter.
                float3 blueTrail = mix(mix(float3(0.10, 0.55, 1.0),
                    float3(0.24, 1.0, 1.0), brighter), float3(0.91, 0.98, 1.0), exposure);
                float3 blueOverlap = 1.0 - (1.0 - blueDarkReference) * (1.0 - blueTrail * opacity);
                // Balance only added trail light: a history buffer must never
                // darken the untouched backdrop, even when its samples faded.
                result = backdrop + balanceYellowDarkLight(max(result - backdrop, 0.0),
                    max(blueOverlap - blueDarkReference, 0.0));
            }
        } else {
            // Keep the old Blue Light screen-pass character, driven by local
            // overlap rather than separate offset strokes. First passes stay colored.
            float pigmentOpacity = opacity * (0.76 + 0.24 * exposure);
            result = mix(result, trailColor, pigmentOpacity);
            float3 screenLight = isYellowPreset > 0.5
                ? mix(yellowLightAccent, white, 0.80)
                : float3(0.80, 0.9059, 1.0); // Original Blue Light screen color.
            result = 1.0 - (1.0 - result) * (1.0 - screenLight * exposure * opacity * 0.42);
        }
    }

    float3 trailDelta=result-mainBase;
    if(W<=0.0)return half4(half3(result),1.0);
    if(dark) {
        float3 referenceMain=amberBlueMain(M,physical.w);
        float3 source=float3(.14,.48,1.0),peak=float3(.24,1.0,1.0);
        float3 referenceContact=clamp(referenceMain+peak*contact.frontReaction+
            idleContactLight(source,peak,contact),0.0,1.0);
        // Evaluate the complete accepted additive response before converting
        // emitter colour; keep the MAIN display correction on its exact native
        // remaining-coverage coefficient, never normalize the summed light.
        float a=1.0-exp(-4.0*contact.intersection);
        float remaining=(1.0-contact.idle)*(1.0-a);
        float3 warm=amberContactReadout(referenceContact)+remaining*(mainBase-amberContactReadout(referenceMain));
        return half4(half3(clamp(warm+trailDelta,0.0,1.0)),1.0);
    }
    // Restore the earlier direct CONTACT composition, before RGB clipping.
    // Identical Blue W/I/remaining/substrate operators; only spectral operands
    // are Yellow. No wave-share hue response or post-clipped RGB matrix.
    // Palette anchors: free #FF8C00, overlap core #FFDD2D.
    float3 LightBase=correctedLightPigment(physicalMain,3.0,transmission);
    float3 waveSource=float3(1.0,140.0/255.0,0.0);
    // Same W/I/a response. Primary stays bright Yellow, existing secondary
    // and halo retain their warm colour progression instead of merging.
    float3 lightContactColor=float3(1.0,221.0/255.0,45.0/255.0);
    float3 appearance=LightBase*(1.0-contact.idle)
        +waveSource*(contact.idle-contact.intersection)
        +lightContactColor*contact.intersection;
    float a=1.0-exp(-4.0*contact.intersection);
    appearance=mix(clamp(appearance,0.0,1.0),lightContactColor,a);
    if(contact.intersection>0.0) {
        // Keep the accepted Light substrate colour reference; Dark late-MAIN
        // feathering must not propagate into this protected contact term.
        // Exact Blue substrate channel response in Yellow channel order.
        // Keep the SUBSTRATE FIX composition and its fields untouched.
        float3 DarkBase=float3(LightBase.r,blueDarkReference.g,blueDarkReference.r);
        float3 source=waveSource;
        float3 DarkContact=clamp(DarkBase+lightContactColor*contact.frontReaction+
            idleContactLight(source,lightContactColor,contact),0.0,1.0);
        float3 beforeDark=appearance;
        float3 pigment=correctedLightPigment(1.0,3.0,transmission);
        float peripheral=(1.0-contact.coverage)*(1.0-contact.coverage);
        float3 substrateDelta=a*peripheral*max(min(beforeDark,pigment)-DarkBase,0.0);
        appearance=mix(appearance,DarkContact,a);
        appearance+=substrateDelta;
    }
    appearance+=(mainBase-LightBase)*(1.0-contact.idle)*(1.0-a);
    // Core-only contrast gain from the existing W/I; Gaussian widths unchanged.
    float coreResponse=pow(clamp(W,0.0,1.0),4.0)*contact.coverage;
    float coreBlue=appearance.b;
    appearance=mainBase+(appearance-mainBase)*(1.0+0.24*coreResponse);
    // Keep the brighter core saturated: do not amplify its neutral B carrier.
    appearance.b=coreBlue/(1.0+0.12*coreResponse);
    appearance+=trailDelta;

    return half4(half3(clamp(appearance,0.0,1.0)),1.0);
}

}

half4 v2ComposeBackground(
    float2 position,
    half4 color,
    float2 size,
    float progress,
    float tapPulse,
    float2 tapPoint,
    float2 previousTouchPoint,
    float swipePulse,
    float swipeStrength,
    float time,
    float progressSpeed,
    float fillGain,
    float waveStrength,
    float waveSpread,
    float topBloom,
    float whiteCore,
    float blueDepth,
    float dragWave,
    float shockStrength,
    float shockInteraction,
    float shockTrail,
    float waveCount,
    float themeStrength,
    float gradientColorIndex,
    float idleActivity,
    float idleTime,
    device const float *interactionSegments,
    int interactionFloatCount
) {
 if(abs(round(gradientColorIndex)-3.0)>0.5) return liquidSpecBackground(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,themeStrength,gradientColorIndex,idleActivity,idleTime,interactionSegments,interactionFloatCount);
 if(idleActivity<=0.0) {
 if(themeStrength>0.5) return YellowDarkMAIN::liquidYellowReviewBackground(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,themeStrength,gradientColorIndex,idleActivity,idleTime,interactionSegments,interactionFloatCount);
 return YellowLightMAIN::liquidYellowReviewBackground(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,themeStrength,gradientColorIndex,idleActivity,idleTime,interactionSegments,interactionFloatCount);
 }
 if(themeStrength>0.5) return YellowDarkContact::liquidYellowReviewBackground(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,themeStrength,gradientColorIndex,idleActivity,idleTime,interactionSegments,interactionFloatCount);
 return YellowLightContact::liquidYellowReviewBackground(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,themeStrength,gradientColorIndex,idleActivity,idleTime,interactionSegments,interactionFloatCount);
}

[[ stitchable ]]
half4 gradientsV2Background(
    float2 position,
    half4 color,
    float2 size,
    float progress,
    float tapPulse,
    float2 tapPoint,
    float2 previousTouchPoint,
    float swipePulse,
    float swipeStrength,
    float time,
    float progressSpeed,
    float fillGain,
    float waveStrength,
    float waveSpread,
    float topBloom,
    float whiteCore,
    float blueDepth,
    float dragWave,
    float shockStrength,
    float shockInteraction,
    float shockTrail,
    float waveCount,
    float themeStrength,
    float gradientColorIndex,
    float idleActivity,
    float idleTime,
    device const float *interactionSegments,
    int interactionFloatCount
) { return v2ComposeBackground(position,color,size,progress,tapPulse,tapPoint,previousTouchPoint,swipePulse,swipeStrength,time,progressSpeed,fillGain,waveStrength,waveSpread,topBloom,whiteCore,blueDepth,dragWave,shockStrength,shockInteraction,shockTrail,waveCount,themeStrength,gradientColorIndex,idleActivity,idleTime,interactionSegments,interactionFloatCount); }

[[ stitchable ]] half4 v2ReadabilityMask(float2 position,half4 colour,float2 origin,float2 scale,device const float *u,int count) {
 if(count<28 || u[25]<=0)return half4(1);
 float2 p=origin+position*scale;
 float4 f=yellowReferenceContactFields(p,half4(1),float2(u[0],u[1]),u[2],u[3],float2(u[4],u[5]),float2(u[6],u[7]),u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15],u[16],u[17],u[18],u[19],u[20],u[21],u[22],1.0,0.0,u[25],u[26],u,0);
 float W=float(half(f.y));
 float keep=1.0-0.98*segmentEase(W,0.015,0.40)*(1.0-0.28*segmentEase(f.z,0.42,0.84));
 return half4(1,1,1,half(keep));
}
float v2Linear(float x) {return x<=.04045 ? x/12.92:pow((x+.055)/1.055,2.4);}
float v2Luma(float3 c) {return .2126*v2Linear(c.r)+.7152*v2Linear(c.g)+.0722*v2Linear(c.b);}
kernel void v2CaptionProbe(constant float *input [[buffer(0)]],device const float *history [[buffer(1)]],device float4 *output [[buffer(2)]],uint id [[thread_position_in_grid]]) {
 if(id>=360)return;
 device const float *u=history+256;
 // Parameters are also copied to a device address-space buffer for the shared helpers.
 float2 p=float2(mix(input[28],input[30],(float(id%40)+.5)/40.0),mix(input[29],input[31],(float(id/40)+.5)/9.0));
 float3 c=float3(v2ComposeBackground(p,half4(1),float2(u[0],u[1]),u[2],u[3],float2(u[4],u[5]),float2(u[6],u[7]),u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15],u[16],u[17],u[18],u[19],u[20],u[21],u[22],u[23],u[24],u[25],u[26],history,int(u[27])).rgb);
 float4 f=yellowReferenceContactFields(p,half4(1),float2(u[0],u[1]),u[2],u[3],float2(u[4],u[5]),float2(u[6],u[7]),u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15],u[16],u[17],u[18],u[19],u[20],u[21],u[22],1.0,0.0,u[25],u[26],u,0);
 float3 main=float3(v2ComposeBackground(p,half4(1),float2(u[0],u[1]),u[2],u[3],float2(u[4],u[5]),float2(u[6],u[7]),u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15],u[16],u[17],u[18],u[19],u[20],u[21],u[22],u[23],u[24],0.0,u[26],history,0).rgb);
 output[id]=float4(v2Luma(c),f.y,max(v2Luma(c)-v2Luma(main),0.0),(max(c.r,max(c.g,c.b))-min(c.r,min(c.g,c.b)))/max(max(c.r,max(c.g,c.b)),0.000001));
}
