#!/usr/bin/env python3
"""Repeatedly launch the existing UIKit app; check live render heartbeats and crashes.
No image capture, extra bundle IDs, or benchmark input injection. Requires a booted
validation Simulator and a previously built Release app. Output is numerical JSON.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

UID = os.environ.get('GRADIENTS_SIMULATOR', 'E7D1D0C6-5730-4444-948D-E7B52DB2C30A')
BUNDLE = 'com.local.gradients.v4.uikit'
REPORTS = Path.home() / 'Library/Logs/DiagnosticReports'


def sim(*args, check=True, env=None):
    return subprocess.run(['xcrun', 'simctl', *args], check=check,
                          capture_output=True, text=True, timeout=40, env=env)


def crash_reports():
    return {str(p) for p in REPORTS.rglob('GradientsUIKit*.ips')}


def main():
    output = Path(sys.argv[1])
    app = os.environ['GRADIENTS_PROFILE_APP']
    existing = crash_reports()
    results = []
    sim('terminate', UID, BUNDLE, check=False)
    sim('install', UID, app)
    data = Path(sim('get_app_container', UID, BUNDLE, 'data').stdout.strip())
    state_path = data / 'Documents/renderer-state.json'
    try:
        for progress in [0.3, 0.6, 0.8]:
            for theme, color in [('dark', 'blue'), ('dark', 'yellow'),
                                 ('light', 'blue'), ('light', 'yellow')]:
                sim('terminate', UID, BUNDLE, check=False)
                state_path.unlink(missing_ok=True)
                env = {k: v for k, v in os.environ.items()
                       if not k.startswith('SIMCTL_CHILD_GRADIENTS_')}
                env.update(SIMCTL_CHILD_GRADIENTS_THEME=theme,
                           SIMCTL_CHILD_GRADIENTS_COLOR=color,
                           SIMCTL_CHILD_GRADIENTS_PROGRESS=str(progress),
                           SIMCTL_CHILD_GRADIENTS_DIAGNOSTICS='1',
                           SIMCTL_CHILD_GRADIENTS_BENCHMARK='0')
                launch = sim('launch', UID, BUNDLE, env=env)
                pid = int(launch.stdout.strip().rsplit(':', 1)[1])
                deadline = time.monotonic() + 20
                first = None
                while time.monotonic() < deadline:
                    os.kill(pid, 0)
                    if state_path.exists():
                        state = json.loads(state_path.read_text())
                        assert state['theme'] == theme and state['color'] == color
                        assert abs(state['progress'] - progress) < 1e-6
                        assert 'UIKit + Metal / GradientsKit' in state['engine']
                        submitted = state['statistics']['submitted']
                        if first is None:
                            first = submitted
                        if submitted - first >= 90:
                            break
                    time.sleep(0.25)
                else:
                    raise RuntimeError(f'Render heartbeat stalled: {theme}/{color}/{progress}')
                new_reports = crash_reports() - existing
                if new_reports:
                    raise RuntimeError(f'New crash reports: {sorted(new_reports)}')
                result = dict(theme=theme, color=color, progress=progress, pid=pid,
                              advancingFrames=submitted-first, statistics=state['statistics'])
                results.append(result)
                output.write_text(json.dumps(dict(launches=results, newCrashReports=[]), indent=2))
                print(f'{theme}/{color} {progress:.0%}: PID {pid}, {submitted-first:.0f} advancing frames', flush=True)
        # ReportCrash can write the .ips after the process exits; retain a short grace period.
        sim('terminate', UID, BUNDLE, check=False)
        time.sleep(3)
        new_reports = crash_reports() - existing
        if new_reports:
            raise RuntimeError(f'New crash reports: {sorted(new_reports)}')
        print(f'PASS: {len(results)} launches; no new GradientsUIKit crash reports', flush=True)
    finally:
        sim('terminate', UID, BUNDLE, check=False)


if __name__ == '__main__':
    main()
