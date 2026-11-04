#!/usr/bin/env python3
"""Regenerate Demo/tests linked to the sibling standalone SDK project."""
from pathlib import Path
import sys

DEV = Path(__file__).resolve().parents[1]
SDK = DEV.parent/'GradientsKit-V4'
sys.path.insert(0, str(SDK/'Scripts'))
from xcode_project import *

project = DEV/'UIKitDemo/GradientsUIKitV4.xcodeproj'
sdk_path = '../../GradientsKit-V4/GradientsKit.xcodeproj'
sdk_project = file(sdk_path, 'wrapper.pb-project')
product_proxy = obj('sdkProductProxy','PBXContainerItemProxy',containerPortal=sdk_project,proxyType=2,
                    remoteGlobalIDString=raw(ident('file:GradientsKit.framework')),remoteInfo='GradientsKit')
product = obj('sdkReference','PBXReferenceProxy',fileType=raw('wrapper.framework'),path='GradientsKit.framework',
              remoteRef=product_proxy,sourceTree='BUILT_PRODUCTS_DIR')
sdk_products = obj('sdkProducts','PBXGroup',name='Products',children=[product],sourceTree='<group>')
sdk_target_proxy = obj('sdkTargetProxy','PBXContainerItemProxy',containerPortal=sdk_project,proxyType=1,
                       remoteGlobalIDString=raw(ident('sdk')),remoteInfo='GradientsKit')
sdk_dependency = obj('externalSDKDependency','PBXTargetDependency',name='GradientsKit',targetProxy=sdk_target_proxy)
demo_product = file('GradientsUIKitV4.app','wrapper.application','BUILT_PRODUCTS_DIR')
unit_product = file('GradientsUIKitV4Tests.xctest','wrapper.cfbundle','BUILT_PRODUCTS_DIR')
ui_product = file('GradientsUIKitV4UITests.xctest','wrapper.cfbundle','BUILT_PRODUCTS_DIR')
demo = file('AppDelegate.swift','sourcecode.swift')
unit = file('Tests/ComponentTests.swift','sourcecode.swift')
stability = file('Tests/SDKStabilityTests.swift','sourcecode.swift')
ui = file('UITests/InteractionTests.swift','sourcecode.swift')
embed = obj('demoEmbed','PBXCopyFilesBuildPhase',buildActionMask=2147483647,
            files=[build(product,'embed',['CodeSignOnCopy','RemoveHeadersOnCopy'])],dstPath='',dstSubfolderSpec=10,
            name='Embed Frameworks',runOnlyForDeploymentPostprocessing=0)
demo_target = obj('demo','PBXNativeTarget',name='GradientsUIKitV4',productName='GradientsUIKitV4',productReference=demo_product,
                 productType='com.apple.product-type.application',buildConfigurationList=configurations('demo', {
                     'PRODUCT_BUNDLE_IDENTIFIER':'com.local.gradients.v4.uikit', 'INFOPLIST_KEY_CFBundleDisplayName':'GradientsKit V4',
                     'INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES', 'INFOPLIST_KEY_UILaunchScreen_Generation':'YES',
                     'INFOPLIST_KEY_UISupportedInterfaceOrientations':'UIInterfaceOrientationPortrait',
                     'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks', 'SKIP_INSTALL':'YES'}),
                 buildPhases=[phase('demoSources','PBXSourcesBuildPhase',[build(demo,'demo')]),
                              phase('demoFrameworks','PBXFrameworksBuildPhase',[build(product,'link')]),
                              phase('demoResources','PBXResourcesBuildPhase',[]),embed],buildRules=[],dependencies=[sdk_dependency])
for name, source, result, kind, extra in [('unit',unit,unit_product,'unit-test',{'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/GradientsUIKitV4.app/GradientsUIKitV4','BUNDLE_LOADER':'$(TEST_HOST)'}),
                                       ('ui',ui,ui_product,'ui-testing',{'TEST_TARGET_NAME':'GradientsUIKitV4'})]:
    proxy = obj(name+'proxy','PBXContainerItemProxy',containerPortal=raw(ident('project')),proxyType=1,remoteGlobalIDString=demo_target,remoteInfo='GradientsUIKitV4')
    dependency = obj(name+'dep','PBXTargetDependency',target=demo_target,targetProxy=proxy)
    obj(name,'PBXNativeTarget',name='GradientsUIKitV4Tests' if name=='unit' else 'GradientsUIKitV4UITests',productReference=result,
        productName='Tests',productType='com.apple.product-type.bundle.'+kind,
        buildConfigurationList=configurations(name,{'PRODUCT_BUNDLE_IDENTIFIER':'com.local.gradients.v4.uikit.'+name,**extra}),
        buildPhases=[phase(name+'Sources','PBXSourcesBuildPhase',[build(source,name)]+([build(stability,'stability')] if name=='unit' else [])),
                     phase(name+'Frameworks','PBXFrameworksBuildPhase',[build(product,name+'link')] if name=='unit' else []),
                     phase(name+'Resources','PBXResourcesBuildPhase',[])],buildRules=[],dependencies=[dependency])
write_project(project,[sdk_project,demo,unit,stability,ui],[demo_product,unit_product,ui_product],
              [demo_target,raw(ident('unit')),raw(ident('ui'))],references=[{'ProductGroup':sdk_products,'ProjectRef':sdk_project}])
entry = reference('demo','GradientsUIKitV4.app','GradientsUIKitV4','GradientsUIKitV4.xcodeproj')
sdk_entry = reference('sdk','GradientsKit.framework','GradientsKit',sdk_path)
tests = ''.join('<TestableReference skipped="NO">'+reference(n,'GradientsUIKitV4Tests.xctest' if n=='unit' else 'GradientsUIKitV4UITests.xctest',
        'GradientsUIKitV4Tests' if n=='unit' else 'GradientsUIKitV4UITests','GradientsUIKitV4.xcodeproj')+'</TestableReference>' for n in ['unit','ui'])
write_scheme(project,'GradientsUIKitV4',entry,tests,sdk_entry)
# Framework-only scheme references the external target instead of compiling SDK copies.
write_scheme(project,'GradientsKit',sdk_entry)
print(project)
