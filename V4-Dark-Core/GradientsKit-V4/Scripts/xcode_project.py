"""Small deterministic Xcode-project writer shared by SDK and development tooling."""
import hashlib
import json

objects = {}
def ident(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def raw(value):
    return ('RAW', value)
def value(item, level=0):
    if isinstance(item, tuple):
        return item[1]
    indent, child = '\t' * level, '\t' * (level + 1)
    if isinstance(item, list):
        return '(\n' + ''.join(child + value(v, level + 1) + ',\n' for v in item) + indent + ')'
    if isinstance(item, dict):
        return '{\n' + ''.join(child + k + ' = ' + value(v, level + 1) + ';\n' for k, v in item.items()) + indent + '}'
    return json.dumps(str(item), ensure_ascii=False)
def obj(key, isa, **fields):
    key = ident(key)
    objects[key] = {'isa': raw(isa), **fields}
    return raw(key)
def file(path, kind, tree='<group>'):
    return obj('file:' + path, 'PBXFileReference', path=path, lastKnownFileType=raw(kind), sourceTree=tree)
def build(ref, name, attrs=None):
    return obj('build:' + name, 'PBXBuildFile', fileRef=ref, **({'settings': {'ATTRIBUTES': attrs}} if attrs else {}))
def phase(name, kind, files):
    return obj(name, kind, buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0)
BASE = {'SDKROOT':'iphoneos', 'IPHONEOS_DEPLOYMENT_TARGET':'17.0', 'SWIFT_VERSION':'5.0',
        'TARGETED_DEVICE_FAMILY':'1,2', 'CLANG_ENABLE_MODULES':'YES', 'CLANG_ENABLE_OBJC_ARC':'YES',
        'MTL_FAST_MATH':'YES', 'GENERATE_INFOPLIST_FILE':'YES', 'PRODUCT_NAME':'$(TARGET_NAME)',
        'CODE_SIGN_STYLE':'Automatic', 'CURRENT_PROJECT_VERSION':'1', 'MARKETING_VERSION':'4.0'}
def configurations(name, extra):
    configs = []
    for mode in ['Debug', 'Release']:
        settings = {**BASE, **extra, 'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O',
                    'DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym',
                    'ENABLE_TESTABILITY':'YES' if mode=='Debug' else 'NO',
                    'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if mode=='Debug' else ''}
        configs.append(obj(name+mode, 'XCBuildConfiguration', buildSettings=settings, name=mode))
    return obj(name+'config', 'XCConfigurationList', buildConfigurations=configs,
               defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
def write_project(path, children, products, targets, references=None):
    product_group = obj('products', 'PBXGroup', name='Products', children=products, sourceTree='<group>')
    group = obj('root', 'PBXGroup', children=[*children, product_group], sourceTree='<group>')
    obj('project', 'PBXProject', attributes={'BuildIndependentTargetsInParallel':1, 'LastUpgradeCheck':2630},
        buildConfigurationList=configurations('project', {}), compatibilityVersion='Xcode 15.0',
        developmentRegion='en', knownRegions=['en','Base'], mainGroup=group, productRefGroup=product_group,
        projectDirPath='', projectRoot='', targets=targets, **({'projectReferences':references} if references else {}))
    path.mkdir(parents=True, exist_ok=True)
    (path/'project.pbxproj').write_text('// !$*UTF8*$!\n'+value({'archiveVersion':1, 'classes':{},
        'objectVersion':60, 'objects':objects, 'rootObject':raw(ident('project'))})+'\n')
def reference(key, product, title, container):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(key)}" BuildableName="{product}" BlueprintName="{title}" ReferencedContainer="container:{container}"/>'
def write_scheme(path, name, entry, tests='', dependency=''):
    folder = path/'xcshareddata/xcschemes'
    folder.mkdir(parents=True, exist_ok=True)
    builds = ''.join('<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">'+r+'</BuildActionEntry>' for r in [dependency,entry] if r)
    (folder/(name+'.xcscheme')).write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2630" version="1.7"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>{builds}</BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{tests}</Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn"><BuildableProductRunnable runnableDebuggingMode="0">{entry}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{entry}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
