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
