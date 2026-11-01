import copy
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from PIL import Image, ImageChops


ICONS = Path(__file__).resolve().parents[1] / "Primuse/Resources-iOS/AppIcons"
RENDITIONS = {
    "Default": "Light",
    "Dark": "Dark",
    "TintedLight": "Mono",
    "TintedDark": "Mono",
    "ClearLight": "Mono",
    "ClearDark": "Mono",
}


class LayeredIconRenderingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
        cls.tool = developer.parent / "Applications/Icon Composer.app/Contents/Executables/ictool"
        if not cls.tool.is_file():
            raise unittest.SkipTest("Requires Xcode with Icon Composer")

    def render(self, source, destination, rendition, generation):
        subprocess.run(
            [str(self.tool), str(source), "--export-image", "--output-file", str(destination),
             "--platform", "iOS", "--rendition", rendition, "--width", "128", "--height", "128",
             "--scale", "2", "--design-generation", str(generation)],
            check=True, capture_output=True, text=True,
        )
        with Image.open(destination) as image:
            return image.convert("RGBA")

    def check_appearances(self, renditions):
        with tempfile.TemporaryDirectory(prefix="primuse-icon-render-") as temporary:
            root = Path(temporary)
            for source in sorted(ICONS.glob("*.icon")):
                document = json.loads((source / "icon.json").read_text())
                reference = root / source.name
                shutil.copytree(source, reference)
                for rendition in renditions:
                    isolated = copy.deepcopy(document)
                    isolated["groups"] = [{
                        "name": "Reference",
                        "shadow": {"kind": "neutral", "opacity": 0},
                        "translucency": {"enabled": False, "value": 0},
                        "specular": RENDITIONS[rendition] == "Mono",
                        "layers": [{"name": "Reference", "image-name": RENDITIONS[rendition] + ".png",
                                    "glass": RENDITIONS[rendition] == "Mono"}],
                    }]
                    (reference / "icon.json").write_text(json.dumps(isolated))
                    for generation in (26, 27):
                        with self.subTest(icon=source.stem, rendition=rendition, generation=generation):
                            actual = self.render(source, root / "actual.png", rendition, generation)
                            expected = self.render(reference, root / "expected.png", rendition, generation)
                            # Removing inactive layers must not change any rendered color or material.
                            difference = ImageChops.difference(actual, expected)
                            self.assertTrue(
                                all(channel.getbbox() is None for channel in difference.split()),
                                "Inactive artwork contributes pixels or glass effects",
                            )

    def test_color_appearances_exclude_inactive_glass(self):
        self.check_appearances(["Default", "Dark"])

    def test_mono_appearances_exclude_color_plates(self):
        self.check_appearances(["TintedLight", "TintedDark", "ClearLight", "ClearDark"])

    def test_compiled_icons_have_only_the_current_image_and_material(self):
        sources = sorted(ICONS.glob("*.icon"))
        self.assertTrue(sources)
        appearances = {"UIAppearanceLight": "Light", "UIAppearanceDark": "Dark", "ISAppearanceTintable": "Mono"}
        with tempfile.TemporaryDirectory(prefix="primuse-icon-compile-") as temporary:
            root = Path(temporary)
            command = ["xcrun", "actool", *map(str, sources), "--compile", str(root),
                       "--platform", "iphoneos", "--minimum-deployment-target", "18.0",
                       "--target-device", "iphone", "--target-device", "ipad", "--app-icon", "AppIcon",
                       "--output-partial-info-plist", str(root / "partial.plist")]
            for source in sources:
                if source.stem != "AppIcon":
                    command += ["--alternate-app-icon", source.stem]
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=120)
            catalog = json.loads(subprocess.check_output(["xcrun", "assetutil", "--info", str(root / "Assets.car")]))
            groups = [item for item in catalog if item.get("AssetType") == "IconGroup"]
            self.assertEqual(len(groups), len(sources) * len(appearances))
            for group in groups:
                with self.subTest(icon=group["Name"], appearance=group["Appearance"]):
                    artwork = appearances[group["Appearance"]]
                    self.assertEqual(group["LayerCount"], 1, "Transparent inactive layers must not reach SpringBoard")
                    self.assertEqual(len(group["Layers"]), 1)
                    layer = group["Layers"][0]
                    self.assertEqual(layer["Name"].split("/")[-1], artwork)
                    self.assertEqual(layer["LayerOpacity"], 1)
                    self.assertEqual(layer.get("LayerHasLightingEffects", False), artwork == "Mono")
            for stack in (item for item in catalog if item.get("AssetType") == "IconImageStack"):
                for group in (layer for layer in stack["Layers"] if layer.get("AssetType") == "IconGroup"):
                    self.assertEqual(group.get("LayerHasSpecular", False), stack["Appearance"] == "ISAppearanceTintable")


if __name__ == "__main__":
    unittest.main()
