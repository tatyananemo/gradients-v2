#!/usr/bin/env python3
"""Build-only adapters. Never edits the app or canonical Metal modules."""
import hashlib, importlib.util, json, re, shutil, subprocess, sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = HERE / 'Build'
BUILD.mkdir(exist_ok=True)
lock = HERE/'baseline.json'
if lock.exists():
    for path,digest in json.loads(lock.read_text())['source']['files'].items():
        if hashlib.sha256((ROOT/path).read_bytes()).hexdigest()!=digest:
            raise SystemExit('Frozen V2 source changed: '+path)
sys.dont_write_bytecode=True
sys.path.insert(0,str(ROOT/'Validation'))
spec = importlib.util.spec_from_file_location('validation', ROOT/'Validation/validate.py')
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
source = (ROOT/'GradientInstallView.swift').read_text()
reference = source.replace('struct GradientInstallView: View {', 'struct GradientInstallView: View {\n    private let migrationFixture = MigrationEnvironment.frame').replace('@AppStorage("gradientsV2.theme")', '@State')
a = reference.index('    init() {'); b = reference.index('\n    var body:', a)
reference = reference[:a] + '''    init() {
        let f = MigrationEnvironment.frame
        launchPreviewProgress = nil
        launchPreviewTheme = nil
        launchPreviewColor = nil
        _appTheme = State(initialValue: f.dark ? .dark : .light)
        _gradientColor = State(initialValue: f.yellow ? .yellow : .blue)
        _progress = State(initialValue: f.replay.progress)
        _progressIncrements = State(initialValue: f.replay.progressIncrements)
        _startTime = State(initialValue: f.replay.startTime)
        _waterTouchPoint = State(initialValue: f.replay.waterTouchPoint)
        _waterTouchPreviousPoint = State(initialValue: f.replay.waterTouchPreviousPoint)
        _waterTouchLastMove = State(initialValue: f.replay.waterTouchLastMove)
        _waterTouchIsActive = State(initialValue: f.replay.waterTouchIsActive)
        _idleWaveStartTime = State(initialValue: f.replay.idleWaveStartTime)
        _waterDragEnergy = State(initialValue: f.replay.waterDragEnergy)
        _interactionTrail = State(initialValue: f.replay.interactionTrail)
    }
''' + reference[b:]
reference = reference.replace('let now = timeline.date.timeIntervalSinceReferenceDate', 'let now = migrationFixture.time')
for marker in ['.onAppear {', '.task {']:
    old = v.block(reference, marker)
    reference = reference.replace(old, '', 1)
reference = reference.replace('activation:captionProbe.key == v2Key ? captionProbe.activation:0', 'activation:migrationFixture.activation')
reference = reference.replace('.onPreferenceChange(V2CaptionFrameKey.self) { captionFrame = $0 }', '.onPreferenceChange(V2CaptionFrameKey.self) { captionFrame = $0; if MigrationEnvironment.frame === migrationFixture { MigrationEnvironment.captionFrame = $0 } }')
old = v.block(reference, '.onChange(of: elapsed,initial:true)')
reference = reference.replace(old, '''.onChange(of: elapsed,initial:true) { _,_ in
                    guard MigrationEnvironment.frame === migrationFixture else {return}\n                    MigrationEnvironment.uniforms = v2Uniforms
                    MigrationEnvironment.history = v2History
                    MigrationEnvironment.distortion = Float(trailDistortionStrength)
                }''')
reference = reference.replace('@StateObject private var touchRuntime', '@ObservedObject private var behaviorClock = BehaviorEnvironment.clock\n    @StateObject private var touchRuntime')
reference = reference.replace('let now = migrationFixture.time', 'let now = migrationFixture.time')
# Feed the real reference View with the original replay state; no View recreation per frame.
reference = reference.replace('.statusBarHidden(true)', '.statusBarHidden(true).onReceive(behaviorClock.$tick) { _ in\n' + r'''        guard BehaviorEnvironment.active, MigrationEnvironment.frame === migrationFixture else {return}
        let r=migrationFixture.replay
        progress=r.progress;progressIncrements=r.progressIncrements;startTime=r.startTime
        waterTouchPoint=r.waterTouchPoint;waterTouchPreviousPoint=r.waterTouchPreviousPoint
        waterTouchLastMove=r.waterTouchLastMove;waterTouchIsActive=r.waterTouchIsActive
        idleWaveStartTime=r.idleWaveStartTime;waterDragEnergy=r.waterDragEnergy;interactionTrail=r.interactionTrail
    }''')
reference = reference.replace('.contentTransition(.numericText())', '''.contentTransition(.numericText())
                                .background { GeometryReader { proxy in
                                    Color.clear.onAppear { if MigrationEnvironment.frame === migrationFixture { MigrationEnvironment.counterFrame = proxy.frame(in: .global) } }
                                }}''')
reference = reference.replace('.zIndex(1)', '.zIndex(1).modifier(MigrationVisibility(ui:false))').replace('.zIndex(10)', '.zIndex(10).modifier(MigrationVisibility(ui:true))')
# UI and formulas are retained. The only adaptations above supply clocks/state,
# isolate preferences, record geometry, and freeze separately measured activation.
(BUILD/'GradientInstallView.swift').write_text(reference)
for path in (ROOT/'Sources').glob('*.swift'):
    target = BUILD/path.name
    text = path.read_text()
    if path.name == 'GradientCaption.swift':
        text = text.replace(' private var busy=false,', ' var busy=false,')
        text = text.replace(' private var lastTime:TimeInterval=0', ' var migrationTime:TimeInterval=1000\n var migrationCompletion:(()->Void)?\n private var lastTime:TimeInterval=0')
        text = text.replace('let currentTime=ProcessInfo.processInfo.systemUptime', 'let currentTime=migrationTime')
        text = text.replace('self.activation=min(max(next,0),1)', 'self.activation=min(max(next,0),1)\n    self.migrationCompletion?()')
    target.write_text(text)
# Reuse the existing validated extractor, not a rewritten gesture implementation.
replay = v.behavior_source(v.app_source())
a = replay.index('struct ProgressIncrement'); b = replay.index('struct GestureValue')
replay = replay[:a] + replay[b:]
replay = replay[:replay.index('private let replay = Replay()')]
replay = replay.replace('private final class Replay', 'final class MigrationReplay').replace('private func ', 'func ')
(BUILD/'MigrationReplay.swift').write_text(replay)
shutil.copyfile(HERE/'MigrationApp.swift', BUILD/'_22App.swift')
shutil.copytree(ROOT/'Assets.xcassets', BUILD/'Assets.xcassets', dirs_exist_ok=True)
subprocess.run(['python3',str(ROOT/'Scripts/compose_metal.py'),'--output',str(BUILD/'LiquidSpecBackground.metal')],check=True)
project = (ROOT/'GradientsV2.xcodeproj/project.pbxproj').read_text()
project = project.replace('1A0000030000000000000051 /* Compose Metal */,','')
project = project.replace('sourceTree = DERIVED_FILE_DIR;', 'sourceTree = "<group>";')
for name in ['GradientTheme','GradientInteractionState','GradientSettings','GradientOverlays','GradientCaption']:
    project = project.replace('path = Sources/'+name, 'path = '+name)
project = project.replace('com.local.gradients.v2;', 'com.local.gradients.v2.migrationprobe;')
project = project.replace('PRODUCT_NAME = GradientsV2;', 'PRODUCT_NAME = MigrationProbe;')
project = project.replace('GradientsV2.app', 'MigrationProbe.app').replace('"Gradients V2"','"V2 Migration Probe"')
extras = ['MigrationReplay.swift']
for path in sorted((ROOT/'UIKitComponent').rglob('*.swift')):
    text=path.read_text()
    if path.name == 'GradientGPU.swift':
        text=text.replace('library=try device.makeDefaultLibrary(bundle:Bundle(for:GradientResourceMarker.self))', 'let source=try String(contentsOf:Bundle.main.url(forResource:"PrototypeShader",withExtension:"txt")!).replacingOccurrences(of:"[[ stitchable ]]",with:"")\n        let options=MTLCompileOptions();options.fastMathEnabled=true\n        library=try device.makeLibrary(source:source,options:options)')
    (BUILD/path.name).write_text(text);extras.append(path.name)
shutil.copyfile(HERE/'BehaviorDemo.swift',BUILD/'BehaviorDemo.swift');extras.append('BehaviorDemo.swift')
if (HERE/'PrototypeRenderer.swift').exists():
    shutil.copyfile(HERE/'PrototypeRenderer.swift',BUILD/'PrototypeRenderer.swift')
    extras.append('PrototypeRenderer.swift')
    project=project.replace('SWIFT_VERSION = 5.0;', 'SWIFT_VERSION = 5.0;\nSWIFT_ACTIVE_COMPILATION_CONDITIONS = \"$(inherited) UIKIT_PROTOTYPE\";')
    shader = (BUILD/'LiquidSpecBackground.metal').read_text() + '\n' + (HERE/'PrototypeAdapters.metal').read_text()
    (BUILD/'PrototypeShader.txt').write_text(shader)
    project = project.replace('/* End PBXBuildFile section */','1C0000990000000000000001 = {isa = PBXBuildFile; fileRef = 1C0000990000000000000011; };\n/* End PBXBuildFile section */')
    project = project.replace('/* End PBXFileReference section */','1C0000990000000000000011 = {isa = PBXFileReference; lastKnownFileType = text; path = PrototypeShader.txt; sourceTree = "<group>"; };\n/* End PBXFileReference section */')
    project = project.replace('1A0000040000000000000001 /* Assets.xcassets in Resources */,','1A0000040000000000000001 /* Assets.xcassets in Resources */,\n1C0000990000000000000001,')
for i,name in enumerate(extras,1):
    base = f'1C{i:06}000000000000'
    build,ref = base+'0001',base+'0011'
    project = project.replace('/* End PBXBuildFile section */',f'{build} = {{isa = PBXBuildFile; fileRef = {ref}; }};\n/* End PBXBuildFile section */')
    project = project.replace('/* End PBXFileReference section */',f'{ref} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
    project = project.replace('1A0000020000000000000001 /* GradientInstallView.swift in Sources */,',f'1A0000020000000000000001 /* GradientInstallView.swift in Sources */,\n{build},')
proj = BUILD/'MigrationProbe.xcodeproj'; proj.mkdir(exist_ok=True)
(proj/'project.pbxproj').write_text(project)
scheme = (ROOT/'GradientsV2.xcodeproj/xcshareddata/xcschemes/222.xcscheme').read_text().replace('GradientsV2.app','MigrationProbe.app').replace('GradientsV2.xcodeproj','MigrationProbe.xcodeproj')
schemes = proj/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
(schemes/'222.xcscheme').write_text(scheme)
files = ['GradientInstallView.swift','_22App.swift','GradientsV2.xcodeproj/project.pbxproj']
files += [str(p.relative_to(ROOT)) for folder in ['Sources','ShaderSources','Scripts'] for p in sorted((ROOT/folder).rglob('*')) if p.is_file() and '__pycache__' not in str(p)]
manifest = {'baseline_commit':'dd5bb02','files':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in files},'adaptations':['fixed frame clock and state initialization','isolated theme storage','geometry/uniform recording','caption activation from original probe with fixed timestep','original appearance/task disabled for fixture loading'], 'generated_files_committed':False}
(BUILD/'provenance.json').write_text(json.dumps(manifest,indent=2))
print(proj)
