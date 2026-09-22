#!/usr/bin/env python3
"""Parses an Xcode project file as the OpenStep property list it is.

Xcode rejects the whole project with "not a valid property list" for a single
malformed value, and the message names no line. Unquoted strings are the usual
cause: a bare value may only contain [A-Za-z0-9_$./-], so a file name with a
'+' (AudioPlayerService+SpokenWord.swift) has to be quoted.

Run after editing project.pbxproj by hand or by script.
"""
import re
import sys

BARE = re.compile(r"[A-Za-z0-9_$./-]+")


class Parser:
    def __init__(self, text):
        self.text = text
        self.pos = 0

    def fail(self, message):
        line = self.text.count("\n", 0, self.pos) + 1
        column = self.pos - (self.text.rfind("\n", 0, self.pos) + 1)
        excerpt = self.text[self.pos:self.pos + 60].split("\n")[0]
        raise SyntaxError(f"line {line}, column {column}: {message}\n  near: {excerpt!r}")

    def skip(self):
        while self.pos < len(self.text):
            char = self.text[self.pos]
            if char in " \t\n\r":
                self.pos += 1
            elif self.text.startswith("//", self.pos):
                end = self.text.find("\n", self.pos)
                self.pos = len(self.text) if end < 0 else end
            elif self.text.startswith("/*", self.pos):
                end = self.text.find("*/", self.pos + 2)
                if end < 0:
                    self.fail("unterminated /* comment")
                self.pos = end + 2
            else:
                return

    def parse_value(self):
        self.skip()
        if self.pos >= len(self.text):
            self.fail("unexpected end of file")
        char = self.text[self.pos]
        if char == "{":
            return self.parse_dict()
        if char == "(":
            return self.parse_array()
        if char == '"':
            return self.parse_quoted()
        if char == "<":
            end = self.text.find(">", self.pos)
            if end < 0:
                self.fail("unterminated <data>")
            self.pos = end + 1
            return "<data>"
        match = BARE.match(self.text, self.pos)
        if not match:
            self.fail(f"value starting with {char!r} must be quoted")
        self.pos = match.end()
        return match.group(0)

    def parse_quoted(self):
        self.pos += 1
        out = []
        while self.pos < len(self.text):
            char = self.text[self.pos]
            if char == "\\":
                out.append(self.text[self.pos:self.pos + 2])
                self.pos += 2
                continue
            if char == '"':
                self.pos += 1
                return "".join(out)
            out.append(char)
            self.pos += 1
        self.fail("unterminated quoted string")

    def parse_dict(self):
        self.pos += 1
        result = {}
        while True:
            self.skip()
            if self.pos >= len(self.text):
                self.fail("unterminated dictionary")
            if self.text[self.pos] == "}":
                self.pos += 1
                return result
            key = self.parse_value()
            self.skip()
            if self.pos >= len(self.text) or self.text[self.pos] != "=":
                self.fail(f"expected '=' after key {key!r}")
            self.pos += 1
            result[key] = self.parse_value()
            self.skip()
            if self.pos < len(self.text) and self.text[self.pos] == ";":
                self.pos += 1
            else:
                self.fail(f"expected ';' after value of {key!r}")

    def parse_array(self):
        self.pos += 1
        result = []
        while True:
            self.skip()
            if self.pos >= len(self.text):
                self.fail("unterminated array")
            if self.text[self.pos] == ")":
                self.pos += 1
                return result
            result.append(self.parse_value())
            self.skip()
            if self.pos < len(self.text) and self.text[self.pos] == ",":
                self.pos += 1


def main(path):
    text = open(path, encoding="utf-8").read()
    parser = Parser(text)
    if text.startswith("// !$*UTF8*$!"):
        parser.pos = text.index("\n") + 1
    try:
        root = parser.parse_value()
    except SyntaxError as error:
        print(f"{path}: INVALID property list\n  {error}")
        return 1
    parser.skip()
    if parser.pos != len(text):
        print(f"{path}: trailing content after the root object at offset {parser.pos}")
        return 1
    if not isinstance(root, dict) or "objects" not in root:
        print(f"{path}: root object is not an Xcode project dictionary")
        return 1

    objects = root["objects"]
    refs = {k for k, v in objects.items() if isinstance(v, dict)}
    missing = []
    for key, value in objects.items():
        if not isinstance(value, dict):
            continue
        for field in ("fileRef", "productReference", "target"):
            ref = value.get(field)
            if isinstance(ref, str) and re.fullmatch(r"[0-9A-F]{24}", ref) and ref not in refs:
                missing.append((key, field, ref))
        for field in ("children", "files", "buildPhases", "targets"):
            for ref in value.get(field, []) or []:
                if isinstance(ref, str) and re.fullmatch(r"[0-9A-F]{24}", ref) and ref not in refs:
                    missing.append((key, field, ref))
    if missing:
        print(f"{path}: {len(missing)} dangling reference(s), e.g. {missing[:3]}")
        return 1

    print(f"{path}: valid property list, {len(objects)} objects, references resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "Primuse.xcodeproj/project.pbxproj"))
