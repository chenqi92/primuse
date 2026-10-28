#!/usr/bin/env python3
"""Read-only loopback HTTP/FTP fixtures for LargeVideoMetadataIntegrationTests.

Pass --manifest /tmp/manifest.json and existing multi-GB MP4 files. Run the
Mac tests with TEST_RUNNER_PRIMUSE_LARGE_VIDEO_MANIFEST pointing at that file.
No media is copied or modified. After the test host exits, Ctrl-C closes both
listeners and removes the temporary test libraries.
"""
import argparse
import json
import socket
import socketserver
import subprocess
import threading
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()
    files, entries = {}, []
    for index, path in enumerate(args.files):
        size = path.stat().st_size
        if size < 4_000_000_000:
            parser.error("Each fixture must be an existing video of at least 4 GB")
        probe = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_type",
            "-of", "json", str(path),
        ]))
        assert any(s["codec_type"] == "video" for s in probe["streams"])
        assert any(s["codec_type"] == "audio" for s in probe["streams"])
        name = f"/video-{index + 1}.mp4"
        files[name] = path
        entries.append(dict(path=name, size=size, duration=float(probe["format"]["duration"])))

    class HTTPHandler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            path = files.get(self.path)
            raw_range = self.headers.get("Range", "")
            if path is None or not raw_range.startswith("bytes="):
                self.send_error(400)
                return
            size = path.stat().st_size
            first, last = raw_range[6:].split("-", 1)
            start = int(first) if first else max(0, size - int(last))
            end = min(size, int(last) + 1) if first and last else size
            if not 0 <= start < end <= size:
                self.send_error(416)
                return
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end - 1}/{size}")
            self.send_header("Content-Length", str(end - start))
            self.send_header("Content-Type", "video/mp4")
            self.end_headers()
            with path.open("rb") as handle:
                handle.seek(start)
                remaining = end - start
                while remaining:
                    data = handle.read(min(64 * 1024, remaining))
                    if not data:
                        break
                    self.wfile.write(data)
                    remaining -= len(data)

    class FTPHandler(socketserver.StreamRequestHandler):
        def handle(self):
            passive, offset = None, 0

            def reply(text):
                self.wfile.write((text + "\r\n").encode())
                self.wfile.flush()

            reply("220 Read-only video fixture")
            try:
                for line in self.rfile:
                    command, _, argument = line.decode().strip().partition(" ")
                    if command == "USER":
                        reply("331 Anonymous login")
                    elif command == "PASS":
                        reply("230 Logged in")
                    elif command == "FEAT":
                        reply("211-Features\r\n EPSV\r\n REST STREAM\r\n SIZE\r\n UTF8\r\n211 End")
                    elif command == "SYST":
                        reply("215 UNIX Type: L8")
                    elif command in ("TYPE", "OPTS", "NOOP"):
                        reply("200 OK")
                    elif command == "PWD":
                        reply('257 "/"')
                    elif command == "SIZE" and argument in files:
                        reply(f"213 {files[argument].stat().st_size}")
                    elif command in ("EPSV", "PASV"):
                        if passive:
                            passive.close()
                        passive = socket.socket()
                        passive.bind(("127.0.0.1", 0))
                        passive.listen(1)
                        passive.settimeout(10)
                        port = passive.getsockname()[1]
                        if command == "EPSV":
                            reply(f"229 Entering Extended Passive Mode (|||{port}|)")
                        else:
                            reply(f"227 Entering Passive Mode (127,0,0,1,{port // 256},{port % 256})")
                    elif command == "REST":
                        offset = int(argument)
                        reply("350 Restart accepted")
                    elif command == "RETR" and argument in files and passive:
                        reply("150 Opening data connection")
                        data_socket, _ = passive.accept()
                        passive.close()
                        passive = None
                        completed = True
                        try:
                            with data_socket, files[argument].open("rb") as handle:
                                data_socket.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 64 * 1024)
                                handle.seek(offset)
                                while data := handle.read(64 * 1024):
                                    data_socket.sendall(data)
                        except (BrokenPipeError, ConnectionResetError):
                            completed = False
                        offset = 0
                        reply("226 Complete" if completed else "426 Range transfer closed")
                    elif command == "QUIT":
                        reply("221 Goodbye")
                        return
                    else:
                        reply("550 Read-only fixture: unsupported command")
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                if passive:
                    passive.close()

    class FTPServer(socketserver.ThreadingTCPServer):
        daemon_threads = True

    http = ThreadingHTTPServer(("127.0.0.1", 0), HTTPHandler)
    ftp = FTPServer(("127.0.0.1", 0), FTPHandler)
    for server in (http, ftp):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    scratch = tempfile.TemporaryDirectory(prefix="primuse-large-video-")
    args.manifest.write_text(json.dumps(dict(
        httpPort=http.server_port, ftpPort=ftp.server_address[1], files=entries,
        scratchDirectory=scratch.name,
    ), indent=2))
    print(f"Ready: {len(entries)} real videos; HTTP {http.server_port}, FTP {ftp.server_address[1]}", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    finally:
        for server in (http, ftp):
            server.shutdown()
            server.server_close()
        scratch.cleanup()


if __name__ == "__main__":
    main()
