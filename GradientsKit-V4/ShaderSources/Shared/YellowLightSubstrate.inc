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
