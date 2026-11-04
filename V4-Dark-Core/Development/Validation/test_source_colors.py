"""Build-time color configuration: exact defaults, isolation, safe input, dependencies."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2];SDK=ROOT/'GradientsKit-V4'
sys.path.insert(0,str(SDK/'Scripts'))
from compose_metal import compose
from compose_uikit_metal import compose_sdk
from source_colors import bind_metal,load,scope,swift_source,value


class SourceColorsTests(unittest.TestCase):
    def setUp(self):
        self.canonical=(compose().replace(b'[[ stitchable ]]',b'')+b'\n'+(SDK/'Sources/GradientsKit/Shaders/GradientAdapters.metal').read_bytes()).decode()
        self.config=load(SDK)

    def test_defaults_are_exact_single_compiler_input(self):
        self.assertEqual(compose_sdk(),self.canonical.encode())
        for marker in ('function_constant','V4ConfiguredPalette','palette_prototype','YellowDarkColors','YellowLightColors'):
            self.assertNotIn(marker,compose_sdk().decode())

    def test_every_setting_is_consumed_and_opposite_theme_is_unchanged(self):
        for theme in ('dark','light'):
            other='Light' if theme=='dark' else 'Dark'
            for role,color in self.config[theme].items():
                with self.subTest(theme=theme,role=role):
                    variant=copy.deepcopy(self.config)
                    variant[theme][role]=['0.91','0.51','0.13'] if isinstance(color,list) else '0.97'
                    result=bind_metal(self.canonical,SDK,variant)
                    self.assertTrue(result!=self.canonical or swift_source(variant)!=swift_source(self.config),'unused setting')
                    for kind in ('MAIN','Contact'):
                        signature='namespace Yellow'+other+kind+' {'
                        a,b=scope(self.canonical,self.canonical.index(signature));x,y=scope(result,result.index(signature))
                        self.assertEqual(result[x:y],self.canonical[a:b])
                    # Global Blue, physical fields, shared geometry/HSV, dispatcher,
                    # readability, probe and pipeline adapters are not recolored.
                    begin=self.canonical.index('namespace YellowShared {')
                    self.assertEqual(result[:begin],self.canonical[:begin])
                    tail=self.canonical.index('half4 v2ComposeBackground(')
                    self.assertEqual(result[result.index('half4 v2ComposeBackground('):],self.canonical[tail:])
                    a,b=scope(self.canonical,begin);x,y=scope(result,result.index('namespace YellowShared {'))
                    self.assertEqual(result[x:y],self.canonical[a:b])

    def test_contact_hue_literals_and_shared_helpers_are_bound(self):
        variant=copy.deepcopy(self.config)
        variant['dark']['contactHueBright']=['1.0','0.81','0.0']
        variant['dark']['contactHueShade']=['1.0','0.71','0.0']
        result=bind_metal(self.canonical,SDK,variant)
        self.assertIn('float brightGold=yellowReviewHSV(float3(1.0,0.81,0.0)).x;',result)
        self.assertIn('float shadedOrange=yellowReviewHSV(float3(1.0,0.71,0.0)).x;',result)
        variant=copy.deepcopy(self.config);variant['light']['mainHot']=['1.0','0.68','0.0']
        result=bind_metal(self.canonical,SDK,variant)
        self.assertIn('namespace YellowLightColors {',result)
        self.assertIn('using YellowLightColors::yellowReviewTransmission;',result)
        self.assertNotIn('namespace YellowDarkColors {',result)
        self.assertNotIn('__V4_RGB_',result)
        # A referenced historical Yellow color helper is scoped to Light, never
        # changed globally in ApprovedBlue or replaced by a whole second shader.
        self.assertEqual(result.count('half4 qaHistoricalYellowDarkWave(float density) {'),1)
        variant['light']['mainMid']=['1.0','0.54','0.0']
        result=bind_metal(self.canonical,SDK,variant)
        self.assertEqual(result.count('half4 qaHistoricalYellowDarkWave(float density) {'),2)

    def test_expressions_and_generated_cpu_values(self):
        self.assertEqual(value('221.0 / 255.0').numerator,13)
        for bad in ['140 / 255','nan','float(1)','1.01','-0.1','__import__("os")','1.0; abort()', '1.0 / 0.0']:
            with self.subTest(bad=bad),self.assertRaises(ValueError):value(bad)
        generated=swift_source(self.config)
        self.assertIn('[CGFloat]=[0.105,0.060,0.008]',generated)
        self.assertNotIn('JSON',generated)
        self.assertNotIn('public',generated)
        with tempfile.TemporaryDirectory() as temp:
            temp=Path(temp);source=temp/'main.swift'
            source.write_text(generated+'''
import Foundation
let old:[CGFloat]=[0.105,0.060,0.008]
for i in 0..<3 {precondition(Double(old[i]).bitPattern==Double(GradientYellowColors.darkMaskTint[i]).bitPattern)}
let c=GradientYellowColors.lightCaptionTint
precondition(c.0==1 && c.1==1 && Double(c.2).bitPattern==Double(CGFloat(0.3)).bitPattern)
precondition(GradientYellowColors.darkMaskBase==[0,0,0])
print("Default CGFloat components bit-identical")
''')
            for mode in ('-Onone','-O'):
                subprocess.run(['xcrun','swiftc',mode,'-module-cache-path',str(temp/'cache'),str(source),'-o',str(temp/'test')],check=True)
                subprocess.run([str(temp/'test')],check=True)

    def test_config_is_validated_and_is_a_build_dependency(self):
        with tempfile.TemporaryDirectory() as temp:
            temp=Path(temp);(temp/'Configuration').mkdir()
            for mutate in ('missing','unknown','bad_rgb'):
                variant=copy.deepcopy(self.config)
                if mutate=='missing':del variant['dark']['mainDeep']
                if mutate=='unknown':variant['dark']['gamma']='2.2'
                if mutate=='bad_rgb':variant['light']['contactArc']=['1.0','0.5']
                (temp/'Configuration/YellowColors.json').write_text(json.dumps(variant))
                with self.assertRaises(ValueError):load(temp)
        project=(SDK/'GradientsKit.xcodeproj/project.pbxproj').read_text()
        for item in ('$(SRCROOT)/Configuration/YellowColors.json','$(SRCROOT)/Scripts/source_colors.py','$(DERIVED_FILE_DIR)/GradientYellowColors.swift'):
            self.assertIn(item,project)
        for path in ('GradientGPU.swift','SessionCaptionProbe.swift','GradientRenderSafety.swift'):
            self.assertEqual((SDK/'Sources/GradientsKit'/path).read_bytes(),subprocess.check_output(['git','show','615dfe0:GradientsKit-V4/Sources/GradientsKit/'+path],cwd=ROOT))


if __name__=='__main__':unittest.main()
