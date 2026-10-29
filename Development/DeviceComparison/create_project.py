#!/usr/bin/env python3
"""Generate an isolated iPhone-only A/B project; never regenerate the SDK/Demo."""
from pathlib import Path
import sys
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1];SDK=ROOT/'GradientsKit-V4'
sys.path.insert(0,str(SDK/'Scripts'))
import xcode_project as xp
from xcode_project import obj,file,build,phase,raw,ident,reference
project=HERE/'V4DeviceComparison.xcodeproj'
signing=file('LocalSigning.xcconfig','text.xcconfig')
if not (HERE/'LocalSigning.xcconfig').exists():(HERE/'LocalSigning.xcconfig').write_text('// Optional local DEVELOPMENT_TEAM; never committed.\n')

def configs(name,extra):
    refs=[]
    for variant in ['Reference','Precalc']:
        for mode in ['Debug','Release']:
            title=variant+mode
            settings={**xp.BASE,**extra,'SUPPORTED_PLATFORMS':'iphoneos','SUPPORTS_MACCATALYST':'NO',
                'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O',
                'DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym',
                'ENABLE_TESTABILITY':'YES' if mode=='Debug' else 'NO',
                'SWIFT_ACTIVE_COMPILATION_CONDITIONS':('DEBUG ' if mode=='Debug' else '')+('PRECALC_COMPARISON' if variant=='Precalc' else ''),
                'V4_COMPARISON_MODE':variant.lower(),'ENABLE_USER_SCRIPT_SANDBOXING':'NO'}
            if name=='demo':
                settings['PRODUCT_BUNDLE_IDENTIFIER']='com.local.gradients.v4.compare.'+variant.lower()
                settings['INFOPLIST_KEY_CFBundleDisplayName']='V4 '+('Reference' if variant=='Reference' else 'Precalc')
            refs.append(obj(name+title,'XCBuildConfiguration',buildSettings=settings,name=title,baseConfigurationReference=signing))
    return obj(name+'config','XCConfigurationList',buildConfigurations=refs,defaultConfigurationIsVisible=0,defaultConfigurationName='ReferenceRelease')
xp.configurations=configs
product=file('GradientsKit.framework','wrapper.framework','BUILT_PRODUCTS_DIR')
app_product=file('GradientsV4Comparison.app','wrapper.application','BUILT_PRODUCTS_DIR')
unit_product=file('GradientsV4ComparisonTests.xctest','wrapper.cfbundle','BUILT_PRODUCTS_DIR')
ui_product=file('GradientsV4ComparisonUITests.xctest','wrapper.cfbundle','BUILT_PRODUCTS_DIR')
base_sources=[p for p in sorted((SDK/'Sources/GradientsKit').rglob('*.swift')) if p.name not in ['GradientGPU.swift','GradientViewController.swift','GradientMaskRenderer.swift']]
sources=[file('../../GradientsKit-V4/'+str(p.relative_to(SDK)),'sourcecode.swift') for p in base_sources]
generated=[]
for name,kind in [('GradientGPU.swift','sourcecode.swift'),('GradientViewController.swift','sourcecode.swift'),('GradientMaskRenderer.swift','sourcecode.swift'),('GradientPrecalculationBuffers.swift','sourcecode.swift'),('GradientYellowColors.swift','sourcecode.swift'),('GradientsUIKit.metal','sourcecode.metal')]:
    generated.append(obj('generated:'+name,'PBXFileReference',path=name,lastKnownFileType=raw(kind),sourceTree='DERIVED_FILE_DIR'))
inputs=[str(p.relative_to(ROOT)) for p in sorted([*(SDK/'Scripts').glob('*.py'),*(SDK/'ShaderSources').rglob('*'),*(SDK/'Configuration').glob('*.json'),*(SDK/'Sources/GradientsKit').rglob('*.swift'),*(SDK/'Sources/GradientsKit/Shaders').glob('*.metal')]) if p.is_file()]
inputs=['$(SRCROOT)/../../'+p for p in inputs]+['$(SRCROOT)/'+p for p in ['prepare_sources.py','precalculation_source.py','GradientPrecalculationBuffers.swift']]
compose=obj('compose','PBXShellScriptBuildPhase',buildActionMask=2147483647,files=[],inputPaths=inputs,
    outputPaths=['$(DERIVED_FILE_DIR)/'+n for n in ['GradientGPU.swift','GradientViewController.swift','GradientMaskRenderer.swift','GradientPrecalculationBuffers.swift','GradientYellowColors.swift','GradientsUIKit.metal','SourceManifest.json']],
    name='Prepare isolated comparison sources',runOnlyForDeploymentPostprocessing=0,shellPath='/bin/sh',
    shellScript='if [ "$V4_MASK_DOMAIN" = "1" ]; then\n/usr/bin/python3 -I -B "$SRCROOT/prepare_sources.py" --mode "$V4_COMPARISON_MODE" --mask-domain --output "$DERIVED_FILE_DIR"\nelse\n/usr/bin/python3 -I -B "$SRCROOT/prepare_sources.py" --mode "$V4_COMPARISON_MODE" --output "$DERIVED_FILE_DIR"\nfi\n')
sdk=obj('sdk','PBXNativeTarget',name='GradientsKit',productName='GradientsKit',productReference=product,productType='com.apple.product-type.framework',
    buildConfigurationList=configs('sdk',{'PRODUCT_BUNDLE_IDENTIFIER':'com.local.gradients.v4.kit','DEFINES_MODULE':'YES','SKIP_INSTALL':'NO','BUILD_LIBRARY_FOR_DISTRIBUTION':'YES','INSTALL_PATH':'$(LOCAL_LIBRARY_DIR)/Frameworks','DYLIB_INSTALL_NAME_BASE':'@rpath','LD_DYLIB_INSTALL_NAME':'@rpath/$(EXECUTABLE_PATH)'}),
    buildPhases=[compose,phase('sdkSources','PBXSourcesBuildPhase',[build(s,'sdk'+str(i)) for i,s in enumerate(sources+generated)]),phase('sdkFrameworks','PBXFrameworksBuildPhase',[]),phase('sdkResources','PBXResourcesBuildPhase',[])],buildRules=[],dependencies=[])
sdk_dep=obj('sdkDep','PBXTargetDependency',target=sdk)
app_source=obj('generatedDemo','PBXFileReference',path='AppDelegate.swift',lastKnownFileType=raw('sourcecode.swift'),sourceTree='DERIVED_FILE_DIR')
monitor_source=obj('generatedMonitor','PBXFileReference',path='PhysicalRunMonitor.swift',lastKnownFileType=raw('sourcecode.swift'),sourceTree='DERIVED_FILE_DIR')
demo_compose=obj('composeDemo','PBXShellScriptBuildPhase',buildActionMask=2147483647,files=[],
    inputPaths=['$(SRCROOT)/../UIKitDemo/AppDelegate.swift','$(SRCROOT)/prepare_demo.py','$(SRCROOT)/PhysicalRunMonitor.swift'],
    outputPaths=['$(DERIVED_FILE_DIR)/AppDelegate.swift','$(DERIVED_FILE_DIR)/PhysicalRunMonitor.swift'],
    name='Prepare opt-in physical-test telemetry',runOnlyForDeploymentPostprocessing=0,shellPath='/bin/sh',
    shellScript='/usr/bin/python3 -I -B "$SRCROOT/prepare_demo.py" --output "$DERIVED_FILE_DIR"\n')
embed=obj('embed','PBXCopyFilesBuildPhase',buildActionMask=2147483647,files=[build(product,'embed',['CodeSignOnCopy','RemoveHeadersOnCopy'])],dstPath='',dstSubfolderSpec=10,name='Embed Frameworks',runOnlyForDeploymentPostprocessing=0)
app=obj('demo','PBXNativeTarget',name='GradientsV4Comparison',productName='GradientsV4Comparison',productReference=app_product,productType='com.apple.product-type.application',
    buildConfigurationList=configs('demo',{'INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES','INFOPLIST_KEY_UILaunchScreen_Generation':'YES','INFOPLIST_KEY_UISupportedInterfaceOrientations':'UIInterfaceOrientationPortrait','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks','SKIP_INSTALL':'YES'}),
    buildPhases=[demo_compose,phase('demoSources','PBXSourcesBuildPhase',[build(app_source,'app'),build(monitor_source,'monitor')]),phase('demoFrameworks','PBXFrameworksBuildPhase',[build(product,'appLink')]),phase('demoResources','PBXResourcesBuildPhase',[]),embed],buildRules=[],dependencies=[sdk_dep])
unit_sources=[file('../UIKitDemo/Tests/'+p.name,'sourcecode.swift') for p in sorted((ROOT/'Development/UIKitDemo/Tests').glob('*.swift'))]
unit_sources.append(file('PrecalculationTests.swift','sourcecode.swift'))
ui_source=file('../UIKitDemo/UITests/InteractionTests.swift','sourcecode.swift')
for name,title,kind,prod,refs,extra in [('unit','GradientsV4ComparisonTests','unit-test',unit_product,unit_sources,{'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/GradientsV4Comparison.app/GradientsV4Comparison','BUNDLE_LOADER':'$(TEST_HOST)'}),('ui','GradientsV4ComparisonUITests','ui-testing',ui_product,[ui_source],{'TEST_TARGET_NAME':'GradientsV4Comparison'})]:
    dep=obj(name+'dep','PBXTargetDependency',target=app)
    obj(name,'PBXNativeTarget',name=title,productName=title,productReference=prod,productType='com.apple.product-type.bundle.'+kind,
        buildConfigurationList=configs(name,{'PRODUCT_BUNDLE_IDENTIFIER':'com.local.gradients.v4.compare.'+name,**extra}),
        buildPhases=[phase(name+'Sources','PBXSourcesBuildPhase',[build(s,name+str(i)) for i,s in enumerate(refs)]),phase(name+'Frameworks','PBXFrameworksBuildPhase',[build(product,name+'link')] if name=='unit' else []),phase(name+'Resources','PBXResourcesBuildPhase',[])],buildRules=[],dependencies=[dep])
xp.write_project(project,[signing,*sources,*generated,app_source,monitor_source,*unit_sources,ui_source],[product,app_product,unit_product,ui_product],[sdk,app,raw(ident('unit')),raw(ident('ui'))])
entry=reference('demo','GradientsV4Comparison.app','GradientsV4Comparison',project.name)
sdk_entry=reference('sdk','GradientsKit.framework','GradientsKit',project.name)
tests=''.join('<TestableReference skipped="NO">'+reference(n,'GradientsV4ComparisonTests.xctest' if n=='unit' else 'GradientsV4ComparisonUITests.xctest','GradientsV4ComparisonTests' if n=='unit' else 'GradientsV4ComparisonUITests',project.name)+'</TestableReference>' for n in ['unit','ui'])
for variant in ['Reference','Precalc']:
    name='V4 '+variant
    xp.write_scheme(project,name,entry,tests,sdk_entry)
    path=project/'xcshareddata/xcschemes'/f'{name}.xcscheme';s=path.read_text()
    s=s.replace('buildConfiguration="Debug"','buildConfiguration="'+variant+'Debug"').replace('buildConfiguration="Release"','buildConfiguration="'+variant+'Release"')
    # Ordinary on-device comparison defaults to optimized Release without LLDB.
    start=s.index('<LaunchAction');end=s.index('</LaunchAction>',start)+len('</LaunchAction>')
    s=s[:start]+f'<LaunchAction buildConfiguration="{variant}Release" selectedDebuggerIdentifier="" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn"><BuildableProductRunnable runnableDebuggingMode="0">{entry}</BuildableProductRunnable><EnvironmentVariables><EnvironmentVariable key="GRADIENTS_THEME" value="dark" isEnabled="YES"/><EnvironmentVariable key="GRADIENTS_PROGRESS" value="0" isEnabled="YES"/></EnvironmentVariables></LaunchAction>'+s[end:]
    path.write_text(s)
print(project)
