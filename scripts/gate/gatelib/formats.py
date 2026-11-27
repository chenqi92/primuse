"""标准库里没有的两种格式：工程定义用到的那部分 YAML，以及 Apple 的 .strings 文件。"""
import re


class FormatError(Exception):
    pass


# ---------------------------------------------------------------------------
# YAML（块式映射与序列、引号与流式标量、块标量）

def _strip_comment(line):
    quote = None
    i = 0
    while i < len(line):
        char = line[i]
        if quote:
            if char == "\\" and quote == '"':
                i += 2
                continue
            if char == quote:
                if quote == "'" and line.startswith("''", i):
                    i += 2
                    continue
                quote = None
        elif char in "'\"" and (i == 0 or line[i - 1] in " \t[{,:-"):
            quote = char
        elif char == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i].rstrip()
        i += 1
    return line.rstrip()


def _split_flow(text):
    items, depth, quote, current = [], 0, None, []
    i = 0
    while i < len(text):
        char = text[i]
        if quote:
            current.append(char)
            if char == "\\" and quote == '"' and i + 1 < len(text):
                current.append(text[i + 1])
                i += 2
                continue
            if char == quote:
                quote = None
        elif char in "'\"":
            quote = char
            current.append(char)
        elif char in "[{":
            depth += 1
            current.append(char)
        elif char in "]}":
            depth -= 1
            current.append(char)
        elif char == "," and depth == 0:
            items.append("".join(current).strip())
            current = []
        else:
            current.append(char)
        i += 1
    tail = "".join(current).strip()
    if tail:
        items.append(tail)
    return items


def _scalar(text):
    text = text.strip()
    if not text:
        return None
    if text.startswith('"') and text.endswith('"') and len(text) >= 2:
        body = text[1:-1]
        return re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(m.group(1), m.group(1)), body)
    if text.startswith("'") and text.endswith("'") and len(text) >= 2:
        return text[1:-1].replace("''", "'")
    if text.startswith("[") and text.endswith("]"):
        return [_scalar(item) for item in _split_flow(text[1:-1])]
    if text.startswith("{") and text.endswith("}"):
        result = {}
        for item in _split_flow(text[1:-1]):
            key, _, value = item.partition(":")
            result[_scalar(key)] = _scalar(value)
        return result
    if text in ("true", "True", "yes", "Yes"):
        return True
    if text in ("false", "False", "no", "No"):
        return False
    if text in ("null", "~"):
        return None
    if text.startswith(("&", "*")):
        raise FormatError("不支持锚点与别名：%s" % text)
    return text


def _split_key(content):
    """`key: value` → (key, value)；不是映射项返回 None。"""
    quote = None
    for i, char in enumerate(content):
        if quote:
            if char == quote:
                quote = None
            continue
        if char in "'\"" and i == 0:
            quote = char
            continue
        if char == ":" and (i + 1 == len(content) or content[i + 1] in " \t"):
            return _scalar(content[:i]), content[i + 1:].strip()
    return None


class _Lines:
    def __init__(self, text):
        self.raw = text.split("\n")
        self.items = []  # (缩进, 内容, 原始行号)
        for number, line in enumerate(self.raw):
            stripped = _strip_comment(line.replace("\t", "    "))
            if not stripped.strip() or stripped.strip() == "---":
                self.items.append(None)
                continue
            indent = len(stripped) - len(stripped.lstrip(" "))
            self.items.append((indent, stripped.strip(), number))

    def next(self, i):
        while i < len(self.items) and self.items[i] is None:
            i += 1
        return i


def parse_yaml(text):
    lines = _Lines(text)
    i = lines.next(0)
    if i >= len(lines.items):
        return None
    value, _ = _parse_block(lines, i, lines.items[i][0])
    return value


def _block_scalar(lines, i, parent_indent, style):
    """i 指向块标量的第一行内容。返回 (文本, 下一行)。按第一行的缩进去掉缩进；`|-` 不留结尾换行。"""
    collected = []
    j = i
    while j < len(lines.raw):
        raw = lines.raw[j]
        if raw.strip() and (len(raw) - len(raw.lstrip(" "))) <= parent_indent:
            break
        collected.append(raw)
        j += 1
    while collected and not collected[-1].strip():
        collected.pop()
    content = [line for line in collected if line.strip()]
    indent = min((len(line) - len(line.lstrip(" ")) for line in content), default=0)
    text = "\n".join(line[indent:] for line in collected)
    if text and not style.endswith("-"):
        text += "\n"
    return text, j


def _value_after_key(lines, i, indent, rest):
    if rest in ("|", "|-", "|+", ">", ">-", ">+"):
        return _block_scalar(lines, i + 1, indent, rest)
    if rest:
        return _scalar(rest), i + 1
    j = lines.next(i + 1)
    if j < len(lines.items):
        child_indent, content, _ = lines.items[j]
        if child_indent > indent or (child_indent == indent and (content == "-" or content.startswith("- "))):
            return _parse_block(lines, j, child_indent)
    return None, i + 1


def _parse_block(lines, i, indent):
    content = lines.items[i][1]
    if content == "-" or content.startswith("- "):
        return _parse_sequence(lines, i, indent)
    return _parse_mapping(lines, i, indent)


def _parse_mapping(lines, i, indent, first=None):
    result = {}
    while True:
        i = lines.next(i)
        if i >= len(lines.items):
            return result, i
        line_indent, content, number = lines.items[i]
        if first is not None:
            content, first = first, None
        elif line_indent != indent:
            if line_indent < indent:
                return result, i
            raise FormatError("第 %d 行缩进不对" % (number + 1))
        if content == "-" or content.startswith("- "):
            return result, i
        pair = _split_key(content)
        if pair is None:
            raise FormatError("第 %d 行不是 key: value：%s" % (number + 1, content))
        key, rest = pair
        value, i = _value_after_key(lines, i, indent, rest)
        result[key] = value


def _parse_sequence(lines, i, indent):
    result = []
    while True:
        i = lines.next(i)
        if i >= len(lines.items):
            return result, i
        line_indent, content, number = lines.items[i]
        if line_indent != indent or not (content == "-" or content.startswith("- ")):
            return result, i
        item = content[1:].strip()
        if not item:
            j = lines.next(i + 1)
            if j < len(lines.items) and lines.items[j][0] > indent:
                value, i = _parse_block(lines, j, lines.items[j][0])
            else:
                value, i = None, i + 1
            result.append(value)
            continue
        pair = _split_key(item)
        if pair is not None and not item.startswith(("[", "{")):
            offset = indent + (len(content) - len(item))
            value, i = _parse_mapping(lines, i, offset, first=item)
            result.append(value)
            continue
        result.append(_scalar(item))
        i += 1


# ---------------------------------------------------------------------------
# .strings（OpenStep 属性表的 "键" = "值"; 形式）

_UNQUOTED = re.compile(r"[A-Za-z0-9_$+/:.\-]+")
_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f", "v": "\v", '"': '"', "\\": "\\",
            "'": "'"}


def _decode_quoted(body):
    out = []
    i = 0
    while i < len(body):
        char = body[i]
        if char != "\\" or i + 1 >= len(body):
            out.append(char)
            i += 1
            continue
        following = body[i + 1]
        if following in "Uu" and re.match(r"[0-9a-fA-F]{4}", body[i + 2:i + 6]):
            out.append(chr(int(body[i + 2:i + 6], 16)))
            i += 6
            continue
        octal = re.match(r"[0-7]{1,3}", body[i + 1:i + 4])
        if octal:
            out.append(chr(int(octal.group(0), 8)))
            i += 1 + len(octal.group(0))
            continue
        out.append(_ESCAPES.get(following, following))
        i += 2
    return "".join(out)


_STRINGS_SKIP = re.compile(r"(?:\s+|//[^\n]*|/\*.*?\*/)*", re.S)
_STRINGS_ENTRY = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.S)
_STRINGS_TOKEN = re.compile(r'"((?:[^"\\]|\\.)*)"|((?!/[*/])[A-Za-z0-9_$+/:.\-]+)|([={};])', re.S)


def _decoded(raw):
    return _decode_quoted(raw) if "\\" in raw else raw


def parse_strings(text):
    """返回 {键: 值}；格式不对抛 FormatError（带行号）。同一个键出现两次时后一个为准，与 plutil 相同。"""
    if text.startswith("\ufeff"):
        text = text[1:]
    n = len(text)

    def fail(message, at):
        raise FormatError("第 %d 行：%s" % (text.count("\n", 0, at) + 1, message))

    def token(pos):
        """跳过空白和注释后的下一个记号：(种类, 值, 开始, 结束)；种类 s 是字符串，其余是标点，None 是文件尾。"""
        pos = _STRINGS_SKIP.match(text, pos).end()
        if pos >= n:
            return None, None, pos, pos
        match = _STRINGS_TOKEN.match(text, pos)
        if not match:
            if text.startswith("/*", pos):
                fail("注释没有收尾", pos)
            if text[pos] == '"':
                fail("字符串没有收尾", pos)
            fail("不认识的字符 %r" % text[pos], pos)
        quoted, bare, punct = match.groups()
        if quoted is not None:
            return "s", _decoded(quoted), pos, match.end()
        if bare is not None:
            return "s", bare, pos, match.end()
        return punct, punct, pos, match.end()

    result = {}
    kind, _, start, pos = token(0)
    braced = kind == "{"
    if not braced:
        pos = start
    while True:
        entry_start = _STRINGS_SKIP.match(text, pos).end()
        fast = _STRINGS_ENTRY.match(text, entry_start)
        if fast:
            result[_decoded(fast.group(1))] = _decoded(fast.group(2))
            pos = fast.end()
            continue
        kind, key, start, pos = token(pos)
        if kind is None:
            if braced:
                fail("缺少收尾的 }", start)
            return result
        if braced and kind == "}":
            if token(pos)[0] is not None:
                fail("} 之后还有内容", pos)
            return result
        if kind != "s":
            fail("这里应该是键", start)
        kind, _, start, pos = token(pos)
        if kind == ";":
            result[key] = key
            continue
        if kind != "=":
            fail("键 %r 后面要有 =" % key, start)
        kind, value, start, pos = token(pos)
        if kind != "s":
            fail("键 %r 的值缺失" % key, start)
        kind, _, start, pos = token(pos)
        if kind != ";":
            fail("键 %r 的值后面要有 ;" % key, start)
        result[key] = value


DUPLICATE_KEY_RE = re.compile(r'^\s*"((?:\\.|[^"\\])*)"\s*=')


def duplicate_string_keys(text):
    """与 check-localizations.rb 一样按行找重复的键：{原样的键: [行号...]}。"""
    keys = {}
    for number, line in enumerate(text.split("\n"), 1):
        match = DUPLICATE_KEY_RE.match(line)
        if match:
            keys.setdefault(match.group(1), []).append(number)
    return {key: lines for key, lines in keys.items() if len(lines) > 1}


FORMAT_SPECIFIER_RE = re.compile(r"%(?:\d+\$)?[-+0 #']*\d*(?:\.\d+)?(lld|llu|ld|lu|d|i|u|f|g|@)")


def format_signature(value):
    """与 check-localizations.rb 的 format_signature 相同：去掉 %% 后各占位符的类型，排序。"""
    return sorted(FORMAT_SPECIFIER_RE.findall(value.replace("%%", "")))


# Unicode 的 Han 文字区段（与 Ruby 的 \p{Han} 对应）。
_HAN_RANGES = [(0x2E80, 0x2E99), (0x2E9B, 0x2EF3), (0x2F00, 0x2FD5), (0x3005, 0x3005), (0x3007, 0x3007),
               (0x3021, 0x3029), (0x3038, 0x303B), (0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xF900, 0xFA6D),
               (0xFA70, 0xFAD9), (0x16FE2, 0x16FE3), (0x16FF0, 0x16FF1), (0x20000, 0x2A6DF), (0x2A700, 0x2B739),
               (0x2B740, 0x2B81D), (0x2B820, 0x2CEA1), (0x2CEB0, 0x2EBE0), (0x2EBF0, 0x2EE5D), (0x2F800, 0x2FA1D),
               (0x30000, 0x3134A), (0x31350, 0x323AF)]
HAN_RE = re.compile("[" + "".join("%s-%s" % (chr(a), chr(b)) for a, b in _HAN_RANGES) + "]")


def ruby_strip(value):
    return value.strip(" \t\n\v\f\r\0")
