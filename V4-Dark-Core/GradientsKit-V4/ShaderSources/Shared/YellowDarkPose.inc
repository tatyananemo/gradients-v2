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
