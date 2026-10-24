#!/usr/bin/env python3
"""Add an isolated XCTest UI target to the generated comparison host only."""
from pathlib import Path
import shutil
h=Path(__file__).resolve().parent;b=h/'Build';p=b/'MigrationProbe.xcodeproj/project.pbxproj';s=p.read_text()
shutil.copyfile(h/'UITests/InteractionTests.swift',b/'InteractionTests.swift')
if 'name = InteractionTests;' in s:raise SystemExit('Already prepared; regenerate host first')
objects='''
1D0000000000000000000001 = {isa = PBXBuildFile; fileRef = 1D0000000000000000000002; };
1D0000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = InteractionTests.swift; sourceTree = "<group>"; };
1D0000000000000000000003 = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = InteractionTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
1D0000000000000000000004 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (1D0000000000000000000001,); runOnlyForDeploymentPostprocessing = 0; };
1D0000000000000000000005 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
1D0000000000000000000006 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
1D0000000000000000000007 = {isa = PBXContainerItemProxy; containerPortal = 1A0000010000000000000071; proxyType = 1; remoteGlobalIDString = 1A0000010000000000000041; remoteInfo = 222; };
1D0000000000000000000008 = {isa = PBXTargetDependency; target = 1A0000010000000000000041; targetProxy = 1D0000000000000000000007; };
1D0000000000000000000009 = {isa = PBXNativeTarget; buildConfigurationList = 1D0000000000000000000010; buildPhases = (1D0000000000000000000004,1D0000000000000000000005,1D0000000000000000000006,); buildRules = (); dependencies = (1D0000000000000000000008,); name = InteractionTests; productName = InteractionTests; productReference = 1D0000000000000000000003; productType = "com.apple.product-type.bundle.ui-testing"; };
1D0000000000000000000010 = {isa = XCConfigurationList; buildConfigurations = (1D0000000000000000000011,1D0000000000000000000012,); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
'''
settings='GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = com.local.gradients.v2.migrationprobe.uitests; PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 5.0; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos; TARGETED_DEVICE_FAMILY = 1; TEST_TARGET_NAME = 222; CODE_SIGN_STYLE = Automatic;'
for name,ident in [('Debug','11'),('Release','12')]:objects+=f'1D00000000000000000000{ident} = {{isa = XCBuildConfiguration; buildSettings = {{{settings}}}; name = {name}; }};\n'
s=s.replace('\n\t};\n\trootObject',objects+'\n\t};\n\trootObject')
s=s.replace('targets = (','targets = (\n1D0000000000000000000009,',1)
p.write_text(s)
scheme=b/'MigrationProbe.xcodeproj/xcshareddata/xcschemes/222.xcscheme';s=scheme.read_text();ref='<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="1D0000000000000000000009" BuildableName="InteractionTests.xctest" BlueprintName="InteractionTests" ReferencedContainer="container:MigrationProbe.xcodeproj"/>'
s=s.replace('   </TestAction>','<Testables><TestableReference skipped="NO">'+ref+'</TestableReference></Testables>\n   </TestAction>')
scheme.write_text(s)
