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
                    for group in isolated["groups"]:
                        group["layers"] = [layer for layer in group["layers"]
                                           if layer["name"] == RENDITIONS[rendition]]
                        for layer in group["layers"]:
                            layer.pop("opacity-specializations", None)
                            layer.pop("hidden-specializations", None)
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


if __name__ == "__main__":
    unittest.main()
