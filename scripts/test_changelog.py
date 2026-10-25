import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("changelog.py")
spec = importlib.util.spec_from_file_location("changelog", SCRIPT)
changelog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changelog)


class ChangelogReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.root / "scripts/changelog.py")
        (self.root / "Docs").mkdir()
        for name in ["CHANGELOG.md", "CHANGELOG.en.md"]:
            (self.root / "Docs" / name).write_text("# Changelog\n\n")
        self.git("init", "-q")
        self.git("config", "user.name", "Release test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.version("1.12.0", 108)
        self.commit("上一正式版本的功能")
        (self.root / "feature.txt").write_text("first")
        self.commit("新增本版本首项功能")
        self.version("1.12.1", 109)
        self.commit("准备 1.12.1（109）TestFlight 构建")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True).strip()

    def cli(self, *args):
        return subprocess.check_output(["python3", str(self.root / "scripts/changelog.py"), *args], text=True).strip()

    def version(self, marketing, build):
        (self.root / "project.yml").write_text(
            f'settings:\n  base:\n    MARKETING_VERSION: "{marketing}"\n    CURRENT_PROJECT_VERSION: "{build}"\n'
        )

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-qm", message)

    def test_same_version_new_build_refreshes_cumulative_notes(self):
        section = self.root / "section.md"
        self.cli("draft", "--version", "1.12.1", "--output", str(section))
        self.cli("apply", str(section))
        self.assertEqual(self.cli("is-current", "1.12.1"), "true")
        self.commit("补全 1.12.1 更新日志")
        (self.root / "feature.txt").write_text("first and second")
        self.commit("修复后续构建的播放问题")
        self.version("1.12.1", 114)
        self.commit("准备 1.12.1（114）TestFlight 构建")
        self.assertEqual(self.cli("is-bump"), "true")
        self.assertEqual(self.cli("is-current", "1.12.1"), "false")
        self.cli("draft", "--version", "1.12.1", "--output", str(section))
        draft = section.read_text()
        self.assertIn("build 109-114", draft)
        self.assertIn("本版本首项功能", draft)
        self.assertIn("后续构建的播放问题", draft)
        self.assertNotIn("上一正式版本的功能", draft)
        self.assertNotIn("TestFlight 构建", draft)
        self.assertNotIn("补全 1.12.1 更新日志", draft)
        self.cli("apply", str(section))
        self.assertEqual(self.cli("is-current", "1.12.1"), "true")
        self.assertEqual((self.root / "Docs/CHANGELOG.md").read_text().count("## [1.12.1]"), 1)

    def test_same_build_keeps_curated_notes_and_stale_translation_is_not_current(self):
        zh = self.root / "Docs/CHANGELOG.md"
        en = self.root / "Docs/CHANGELOG.en.md"
        zh.write_text("## [1.12.1] (build 109-114) - 2026-10-25\n\n人工整理的发布内容。\n")
        en.write_text("## [1.12.1] (build 109) - 2026-10-20\n\nOlder translation.\n")
        before = zh.read_bytes()
        self.assertEqual(self.cli("is-current", "1.12.1", "--build", "114"), "true")
        self.assertEqual(zh.read_bytes(), before)
        self.assertEqual(self.cli("is-current", "1.12.1", "--build", "114", "--lang", "en"), "false")
        self.assertEqual(self.cli("is-current", "1.12.1", "--build", "113"), "false")

    def test_missing_or_unversioned_sections_require_refresh(self):
        path = self.root / "Docs/CHANGELOG.md"
        for text in ["# Changelog\n", "## [1.12.1]\n\nOld notes.\n", "## [1.12.0] (build 114)\n"]:
            path.write_text(text)
            self.assertFalse(changelog.section_is_current(path, "1.12.1", "114"))

    def test_version_titles_keep_real_user_facing_changes(self):
        self.assertIsNone(changelog.normalize("准备 1.12.1（114）TestFlight 构建"))
        self.assertIsNone(changelog.normalize("准备 1.12.1（113）测试版本"))
        self.assertIsNone(changelog.normalize("补全 1.12.1 更新日志"))
        self.assertEqual(changelog.normalize("更新 1.9.6 构建 72 并保留 Siri 名称识别"), ("保留 Siri 名称识别", ""))


if __name__ == "__main__":
    unittest.main()
