// New pipeline adapters only. The composed V2 functions above are unchanged.
struct PrototypeVertex {float4 position [[position]];};
vertex PrototypeVertex prototypeVertex(uint id [[vertex_id]]) {
 const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
 return {float4(p[id],0,1)};
}
fragment half4 prototypeBackground(PrototypeVertex in [[stage_in]],device const float *u [[buffer(0)]],device const float *h [[buffer(1)]],constant float &scale [[buffer(2)]]) {
 float2 p=in.position.xy/scale;
 return v2ComposeBackground(p,half4(1),float2(u[0],u[1]),u[2],u[3],float2(u[4],u[5]),float2(u[6],u[7]),u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15],u[16],u[17],u[18],u[19],u[20],u[21],u[22],u[23],u[24],u[25],u[26],h,int(u[27]));
}
fragment half4 prototypeDistortion(PrototypeVertex in [[stage_in]],texture2d<half> image [[texture(0)]],device const float *u [[buffer(0)]],constant float4 &params [[buffer(1)]]) {
 constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
 float2 p=in.position.xy/params.w;
 float2 source=gradientTrailDistortion(p,params.xy,float2(u[4],u[5]),float2(u[6],u[7]),params.z,u[10]);
 return image.sample(s,source/float2(u[0],u[1]));
}
fragment half4 prototypeComposite(PrototypeVertex in [[stage_in]],texture2d<half> image [[texture(0)]],texture2d<half> m0 [[texture(1)]],texture2d<half> m1 [[texture(2)]],texture2d<half> m2 [[texture(3)]],device const float *u [[buffer(0)]],constant float4 &params [[buffer(1)]]) {
 constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
 float2 uv=in.position.xy/float2(image.get_width(),image.get_height());
 float4 c=float4(image.sample(s,uv));
 // Original Dark UI backing is above background/distortion, below counter masks.
 // This is UI composition only; no V2 shader formula is edited.
 if(params.z>0.5) {
  float alpha=0.30*clamp((in.position.y/params.x-u[1]*0.70)/(u[1]*0.30),0.0,1.0);
  c.rgb*=1.0-alpha;
 }
 if(params.y>0.5 && u[23]>.5) {
  float keep=u[24]>2.5 ? float(v2ReadabilityMask(in.position.xy/params.x,half4(1),float2(0),float2(1),u,28).a):1;
  float4 a=float4(m0.sample(s,uv))*keep,b=float4(m1.sample(s,uv))*keep,d=float4(m2.sample(s,uv))*keep;
  c.rgb=a.rgb+c.rgb*(1-a.a);
  c.rgb=b.rgb*c.rgb+c.rgb*(1-b.a);
  c.rgb=d.rgb+c.rgb-d.rgb*c.rgb;
 }
 return half4(c);
}
// Compute-first adapter. The experimental scale specialization was rejected.
kernel void prototypeComputeBackground(texture2d<half,access::write> image [[texture(0)]],constant float *u [[buffer(0)]],device const float *h [[buffer(1)]],constant float &scale [[buffer(2)]],uint2 id [[thread_position_in_grid]]) {
 if(id.x>=image.get_width()||id.y>=image.get_height())return;
 float2 p=(float2(id)+0.5)/scale;
 half4 c=v2ComposeBackground(p,half4(1),float2(u[0],u[1]),u[2],u[3],float2(u[4],u[5]),float2(u[6],u[7]),u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15],u[16],u[17],u[18],u[19],u[20],u[21],u[22],u[23],u[24],u[25],u[26],h,int(u[27]));
 image.write(c,id);
}
