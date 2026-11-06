            // Experimental Dark touch only: replace the two white chromatic stops.
            // Original heat, cream/exposure curves, opacity and screen composition stay intact.
            const float3 touchYellow = float3(1.0, 221.0 / 255.0, 45.0 / 255.0); // #FFDD2D
            warm = mix(warm, mix(yellowHotColor.rgb, touchYellow, 0.82), cream);
            trailColor = mix(warm, touchYellow, exposure);
