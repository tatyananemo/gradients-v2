#!/usr/bin/env python3
"""Regenerate the standalone SDK project. Does not read Development or Git."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from xcode_project import *

ROOT = Path(__file__).resolve().parents[1]
project = ROOT/'GradientsKit.xcodeproj'
product = file('GradientsKit.framework', 'wrapper.framework', 'BUILT_PRODUCTS_DIR')
sources = [file(str(p.relative_to(ROOT)), 'sourcecode.swift') for p in sorted((ROOT/'Sources/GradientsKit').rglob('*.swift'))]
metal = obj('file:metal', 'PBXFileReference', path='GradientsUIKit.metal', lastKnownFileType=raw('sourcecode.metal'), sourceTree='DERIVED_FILE_DIR')
inputs = ['$(SRCROOT)/Scripts/compose_metal.py', '$(SRCROOT)/Scripts/compose_uikit_metal.py',
          '$(SRCROOT)/Sources/GradientsKit/Shaders/GradientAdapters.metal']
inputs += ['$(SRCROOT)/'+str(p.relative_to(ROOT)) for p in sorted([*(ROOT/'ShaderSources').glob('*.source'), *(ROOT/'ShaderSources').rglob('*.inc')])]
compose = obj('composeSDK', 'PBXShellScriptBuildPhase', buildActionMask=2147483647, files=[], inputPaths=inputs,
              outputPaths=['$(DERIVED_FILE_DIR)/GradientsUIKit.metal'], name='Compose approved Metal',
              runOnlyForDeploymentPostprocessing=0, shellPath='/bin/sh',
              shellScript='/usr/bin/python3 -I -B "$SRCROOT/Scripts/compose_uikit_metal.py" --output "$SCRIPT_OUTPUT_FILE_0"\n')
sdk = obj('sdk', 'PBXNativeTarget', name='GradientsKit', productName='GradientsKit', productReference=product,
          productType='com.apple.product-type.framework', buildConfigurationList=configurations('sdk', {
              'PRODUCT_BUNDLE_IDENTIFIER':'com.local.gradients.v4.kit', 'DEFINES_MODULE':'YES', 'SKIP_INSTALL':'NO',
              'BUILD_LIBRARY_FOR_DISTRIBUTION':'YES', 'INSTALL_PATH':'$(LOCAL_LIBRARY_DIR)/Frameworks',
              'DYLIB_INSTALL_NAME_BASE':'@rpath', 'LD_DYLIB_INSTALL_NAME':'@rpath/$(EXECUTABLE_PATH)'}),
          buildPhases=[compose, phase('sdkSources','PBXSourcesBuildPhase',[build(f,'sdk'+str(i)) for i,f in enumerate(sources)]+[build(metal,'metal')]),
                       phase('sdkFrameworks','PBXFrameworksBuildPhase',[]), phase('sdkResources','PBXResourcesBuildPhase',[])],
          buildRules=[], dependencies=[])
write_project(project, [*sources,metal], [product], [sdk])
write_scheme(project, 'GradientsKit', reference('sdk','GradientsKit.framework','GradientsKit','GradientsKit.xcodeproj'))
print(project)
