#!/usr/bin/env python3
"""Generate only A/B Demo telemetry; no SDK or source Demo modifications."""
import argparse
from pathlib import Path
HERE=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
s=(HERE.parent/'UIKitDemo/AppDelegate.swift').read_text()
old='let duration=min(max(Double(environment["GRADIENTS_BENCHMARK_DURATION"] ?? "20") ?? 20,20),90)'
assert s.count(old)==1
s=s.replace(old,'let duration=min(max(Double(environment["GRADIENTS_BENCHMARK_DURATION"] ?? "20") ?? 20,12),20)')
old='        NSLog("GradientsUIKit: %@",gradient.engineDescription)'
assert s.count(old)==1
s=s.replace(old,'        PhysicalRunMonitor.install(gradient,environment)\n'+old)
old='func sceneDidBecomeActive(_ scene:UIScene) {(window?.rootViewController as? DemoController)?.gradient.resumeRendering()}'
assert s.count(old)==1
s=s.replace(old,'func sceneDidBecomeActive(_ scene:UIScene) {if let gradient=(window?.rootViewController as? DemoController)?.gradient {PhysicalRunMonitor.sceneActivated(gradient)}}')
for name,data in [('AppDelegate.swift',s.encode()),('PhysicalRunMonitor.swift',(HERE/'PhysicalRunMonitor.swift').read_bytes())]:
 path=a.output/name
 if not path.exists() or path.read_bytes()!=data:path.write_bytes(data)
