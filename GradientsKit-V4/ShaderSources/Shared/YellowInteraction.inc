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
