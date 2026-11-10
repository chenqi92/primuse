import base64
from email.message import Message
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch
from urllib.error import URLError

import update_community_qr as sync


PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8A"
    "AQUBAScY42YAAAAASUVORK5CYII="
)
OTHER_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR42mP4//8/"
    "AAX+Av4zEpUUAAAAAElFTkSuQmCC"
)
JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkS"
    "Ew8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJ"
    "CQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIy"
    "MjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAA"
    "AAAAAAAAAAAAAAAAAAj/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFAEBAAAAAAAAAAAA"
    "AAAAAAAAAP/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AJ/AB//Z"
)
README = '''# Primuse
<a href="https://g2.al/palveni"><img src="https://example.com/badge.png" alt="公测"/></a>
<p align="center">
  <a href="https://g2.al/palveni">
    <img src="https://g2.al/palveni" width="320" alt="Palveni 微信群聊二维码"/>
  </a>
</p>
保留其他内容。
'''


class CommunityQRTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.readme = Path(self.temp.name) / "README.md"
        self.readme.write_text(README, encoding="utf-8")

    def response(self, body=PNG, content_type="image/png", status=200):
        response = MagicMock()
        response.status = status
        response.headers = Message()
        response.headers["Content-Type"] = content_type
        response.read.return_value = body
        response.__enter__.return_value = response
        return response

    def test_only_qr_source_changes_and_identical_image_does_not_write(self):
        self.assertTrue(sync.update_readme(self.readme, PNG))
        updated = self.readme.read_text(encoding="utf-8")
        self.assertEqual(
            sync.IMAGE_SOURCE.sub('src="IMAGE"', updated),
            sync.IMAGE_SOURCE.sub('src="IMAGE"', README),
        )
        self.assertIn('src="https://example.com/badge.png"', updated)
        self.assertIn('href="https://g2.al/palveni"', updated)
        self.assertIn('src="https://g2.al/palveni?v=', updated)
        with patch.object(Path, "write_text") as write:
            self.assertFalse(sync.update_readme(self.readme, PNG))
        write.assert_not_called()

    def test_different_content_rotates_url_then_stops_changing(self):
        sync.update_readme(self.readme, PNG)
        previous = self.readme.read_bytes()
        self.assertTrue(sync.update_readme(self.readme, OTHER_PNG))
        self.assertNotEqual(self.readme.read_bytes(), previous)
        self.assertFalse(sync.update_readme(self.readme, OTHER_PNG))

    def test_missing_or_ambiguous_qr_does_not_modify_readme(self):
        for content in ["# Primuse\n", README + README,
                        README.replace('src="https://g2.al/palveni"', 'data-src="old"')]:
            with self.subTest(content=content):
                self.readme.write_text(content, encoding="utf-8")
                with self.assertRaises(ValueError):
                    sync.update_readme(self.readme, PNG)
                self.assertEqual(self.readme.read_text(encoding="utf-8"), content)

    def test_fetch_accepts_png_and_requests_revalidation(self):
        response = self.response()
        with patch.object(sync, "urlopen", return_value=response) as opener:
            self.assertEqual(sync.fetch_image(), PNG)
        request = opener.call_args.args[0]
        self.assertEqual(request.full_url, sync.SOURCE_URL)
        self.assertEqual(request.get_header("Cache-control"), "no-cache")
        response.read.assert_called_once_with(sync.MAX_IMAGE_BYTES + 1)

    def test_fetch_accepts_jpeg(self):
        with patch.object(sync, "urlopen", return_value=self.response(JPEG, "image/jpeg")):
            self.assertEqual(sync.fetch_image(), JPEG)

    def test_failed_or_invalid_download_preserves_existing_version(self):
        sync.update_readme(self.readme, PNG)
        before = self.readme.read_bytes()
        responses = [
            self.response(b"<html>Unavailable</html>", "text/html"),
            self.response(b"<html>Unavailable</html>", "image/png"),
            self.response(b"", "image/png"),
            self.response(PNG[:-12], "image/png"),
            self.response(b"x" * (sync.MAX_IMAGE_BYTES + 1)),
            self.response(status=206),
        ]
        for response in responses:
            with self.subTest(response=response), \
                    patch.object(sync, "urlopen", return_value=response), \
                    patch("sys.argv", ["sync", "--readme", str(self.readme)]), \
                    patch("sys.stderr"):
                self.assertEqual(sync.main(), 1)
                self.assertEqual(self.readme.read_bytes(), before)
        with patch.object(sync, "urlopen", side_effect=URLError("unavailable")), \
                patch("sys.argv", ["sync", "--readme", str(self.readme)]), \
                patch("sys.stderr"):
            self.assertEqual(sync.main(), 1)
            self.assertEqual(self.readme.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
