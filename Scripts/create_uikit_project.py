#!/usr/bin/env python3
"""Reproduce the independent GradientsKit framework/UIKit demo Xcode project."""
from pathlib import Path
import hashlib,json
R=Path(__file__).resolve().parents[1];P=R/'UIKitDemo/GradientsUIKit.xcodeproj';P.mkdir(exist_ok=True)
objects={}
def ident(name):return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def raw(value):return ('RAW',value)
def value(x,level=0):
 if isinstance(x,tuple):return x[1]
 indent='\t'*level;child='\t'*(level+1)
 if isinstance(x,list):return '(\n'+''.join(child+value(v,level+1)+',\n' for v in x)+indent+')'
 if isinstance(x,dict):return '{\n'+''.join(child+k+' = '+value(v,level+1)+';\n' for k,v in x.items())+indent+'}'
 return json.dumps(str(x),ensure_ascii=False)
def obj(key,isa,**fields):
 k=ident(key);objects[k]={'isa':raw(isa),**fields};return raw(k)
def file(path,kind,tree='<group>'):
 return obj('file:'+path,'PBXFileReference',path=path,lastKnownFileType=raw(kind),sourceTree=tree)
def build(ref,name,attrs=None):
 return obj('build:'+name,'PBXBuildFile',fileRef=ref,**({'settings':{'ATTRIBUTES':attrs}} if attrs else {}))
def phase(name,kind,files):return obj(name,kind,buildActionMask=2147483647,files=files,runOnlyForDeploymentPostprocessing=0)
productSDK=file('GradientsKit.framework','wrapper.framework','BUILT_PRODUCTS_DIR')
productDemo=file('GradientsUIKit.app','wrapper.application','BUILT_PRODUCTS_DIR')
productTests=file('GradientsUIKitTests.xctest','wrapper.cfbundle','BUILT_PRODUCTS_DIR')
productUI=file('GradientsUIKitUITests.xctest','wrapper.cfbundle','BUILT_PRODUCTS_DIR')
sdkfiles=[file('../'+str(p.relative_to(R)),'sourcecode.swift') for p in sorted((R/'UIKitComponent').rglob('*.swift'))]
metal=obj('file:metal','PBXFileReference',path='GradientsUIKit.metal',lastKnownFileType=raw('sourcecode.metal'),sourceTree='DERIVED_FILE_DIR')
sdkSources=phase('sdkSources','PBXSourcesBuildPhase',[build(f,'sdk'+str(i)) for i,f in enumerate(sdkfiles)]+[build(metal,'metal')])
inputs=['$(SRCROOT)/../Scripts/compose_metal.py','$(SRCROOT)/../Scripts/compose_uikit_metal.py','$(SRCROOT)/../UIKitComponent/Shaders/GradientAdapters.metal']+['$(SRCROOT)/../'+str(p.relative_to(R)) for p in sorted((R/'ShaderSources').glob('*.source'))]
compose=obj('composeSDK','PBXShellScriptBuildPhase',buildActionMask=2147483647,files=[],inputPaths=inputs,outputPaths=['$(DERIVED_FILE_DIR)/GradientsUIKit.metal'],name='Compose approved Metal',runOnlyForDeploymentPostprocessing=0,shellPath='/bin/sh',shellScript='/usr/bin/python3 -I -B "$SRCROOT/../Scripts/compose_uikit_metal.py" --output "$SCRIPT_OUTPUT_FILE_0"\n')
demo=file('AppDelegate.swift','sourcecode.swift');unit=file('Tests/ComponentTests.swift','sourcecode.swift');ui=file('UITests/InteractionTests.swift','sourcecode.swift')
projectID=raw(ident('project'))
def dependency(name,target):
 proxy=obj(name+'proxy','PBXContainerItemProxy',containerPortal=projectID,proxyType=1,remoteGlobalIDString=target,remoteInfo=name)
 return obj(name+'dep','PBXTargetDependency',target=target,targetProxy=proxy)
base={'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'17.0','SWIFT_VERSION':'5.0','TARGETED_DEVICE_FAMILY':'1,2','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','MTL_FAST_MATH':'YES','GENERATE_INFOPLIST_FILE':'YES','PRODUCT_NAME':'$(TARGET_NAME)','CODE_SIGN_STYLE':'Automatic','CURRENT_PROJECT_VERSION':'1','MARKETING_VERSION':'2.0'}
def configurations(name,extra):
 configs=[]
 for mode in ['Debug','Release']:
  settings={**base,**extra,'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym','ENABLE_TESTABILITY':'YES' if mode=='Debug' else 'NO','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if mode=='Debug' else ''}
  configs.append(obj(name+mode,'XCBuildConfiguration',buildSettings=settings,name=mode))
 return obj(name+'config','XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
sdkID=raw(ident('sdk'));demoID=raw(ident('demo'))
obj('sdk','PBXNativeTarget',name='GradientsKit',productName='GradientsKit',productReference=productSDK,productType='com.apple.product-type.framework',buildConfigurationList=configurations('sdk',{'PRODUCT_BUNDLE_IDENTIFIER':'com.local.gradients.kit','DEFINES_MODULE':'YES','SKIP_INSTALL':'NO','BUILD_LIBRARY_FOR_DISTRIBUTION':'YES','INSTALL_PATH':'$(LOCAL_LIBRARY_DIR)/Frameworks','DYLIB_INSTALL_NAME_BASE':'@rpath','LD_DYLIB_INSTALL_NAME':'@rpath/$(EXECUTABLE_PATH)'}),buildPhases=[compose,sdkSources,phase('sdkFrameworks','PBXFrameworksBuildPhase',[]),phase('sdkResources','PBXResourcesBuildPhase',[])],buildRules=[],dependencies=[])
embed=obj('demoEmbed','PBXCopyFilesBuildPhase',buildActionMask=2147483647,files=[build(productSDK,'embed',['CodeSignOnCopy','RemoveHeadersOnCopy'])],dstPath='',dstSubfolderSpec=10,name='Embed Frameworks',runOnlyForDeploymentPostprocessing=0)
obj('demo','PBXNativeTarget',name='GradientsUIKit',productName='GradientsUIKit',productReference=productDemo,productType='com.apple.product-type.application',buildConfigurationList=configurations('demo',{'PRODUCT_BUNDLE_IDENTIFIER':'com.local.gradients.v2.uikit','INFOPLIST_KEY_CFBundleDisplayName':'Gradients V2 UIKit','INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES','INFOPLIST_KEY_UILaunchScreen_Generation':'YES','INFOPLIST_KEY_UISupportedInterfaceOrientations':'UIInterfaceOrientationPortrait','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks','SKIP_INSTALL':'YES'}),buildPhases=[phase('demoSources','PBXSourcesBuildPhase',[build(demo,'demo')]),phase('demoFrameworks','PBXFrameworksBuildPhase',[build(productSDK,'link')]),phase('demoResources','PBXResourcesBuildPhase',[]),embed],buildRules=[],dependencies=[dependency('demoSDK',sdkID)])
for name,source,product,ptype,extra in [('unit',unit,productTests,'unit-test',{'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/GradientsUIKit.app/GradientsUIKit','BUNDLE_LOADER':'$(TEST_HOST)'}),('ui',ui,productUI,'ui-testing',{'TEST_TARGET_NAME':'GradientsUIKit'})]:
 obj(name,'PBXNativeTarget',name='GradientsUIKitTests' if name=='unit' else 'GradientsUIKitUITests',productReference=product,productName='Tests',productType='com.apple.product-type.bundle.'+ptype,buildConfigurationList=configurations(name,{'PRODUCT_BUNDLE_IDENTIFIER':'com.local.gradients.v2.uikit.'+name,**extra}),buildPhases=[phase(name+'Sources','PBXSourcesBuildPhase',[build(source,name)]),phase(name+'Frameworks','PBXFrameworksBuildPhase',[build(productSDK,name+'link')] if name=='unit' else []),phase(name+'Resources','PBXResourcesBuildPhase',[])],buildRules=[],dependencies=[dependency(name+'Demo',demoID)])
products=obj('products','PBXGroup',name='Products',children=[productSDK,productDemo,productTests,productUI],sourceTree='<group>')
group=obj('root','PBXGroup',children=[*sdkfiles,metal,demo,unit,ui,products],sourceTree='<group>')
obj('project','PBXProject',attributes={'BuildIndependentTargetsInParallel':1,'LastUpgradeCheck':2630},buildConfigurationList=configurations('project',{}),compatibilityVersion='Xcode 15.0',developmentRegion='en',knownRegions=['en','Base'],mainGroup=group,productRefGroup=products,projectDirPath='',projectRoot='',targets=[sdkID,demoID,raw(ident('unit')),raw(ident('ui'))])
(P/'project.pbxproj').write_text('// !$*UTF8*$!\n'+value({'archiveVersion':1,'classes':{},'objectVersion':60,'objects':objects,'rootObject':projectID})+'\n')
schemes=P/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
def ref(name,product,title):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(name)}" BuildableName="{product}" BlueprintName="{title}" ReferencedContainer="container:GradientsUIKit.xcodeproj"/>'
for name in ['GradientsUIKit','GradientsKit']:
 sdkOnly=name=='GradientsKit';entry=ref('sdk','GradientsKit.framework','GradientsKit') if sdkOnly else ref('demo','GradientsUIKit.app','GradientsUIKit')
 tests=''.join('<TestableReference skipped="NO">'+ref(n,'GradientsUIKitTests.xctest' if n=='unit' else 'GradientsUIKitUITests.xctest','GradientsUIKitTests' if n=='unit' else 'GradientsUIKitUITests')+'</TestableReference>' for n in ['unit','ui']) if not sdkOnly else ''
 (schemes/(name+'.xcscheme')).write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2630" version="1.7"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{entry}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{tests}</Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn"><BuildableProductRunnable runnableDebuggingMode="0">{entry}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{entry}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print(P)
