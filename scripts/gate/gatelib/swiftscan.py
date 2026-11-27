"""Swift 源码的记号级扫描：不建语法树，只认记号、括号配对和声明的开头。

够用来回答两个问题：`@Observable` 类的类体里有哪些成员、各属于哪一类（与构建机上
SwiftSyntax 工具 observable-split 的分类一致），以及文件导入了哪些模块。
字符串（含插值、多行、原始字符串）、注释（块注释可嵌套）、正则字面量、`#if` 块、
特性和嵌套括号都按 Swift 的规矩处理。
"""
import re

IDENT_RE = re.compile(r"[^\W\d]\w*|\$\w*", re.UNICODE)
NUMBER_RE = re.compile(r"0[xX][0-9a-fA-F_]+(?:\.[0-9a-fA-F_]+)?(?:[pP][+-]?\d+)?|0[bB][01_]+|0[oO][0-7_]+|"
                       r"\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?")
OPERATOR_CHARS = set("/=-+!*%<>&|^~?.")
PUNCT = set("{}()[],;:")
OPEN_TO_CLOSE = {"(": ")", "[": "]", "{": "}"}


class Token:
    __slots__ = ("kind", "text", "line", "end_line", "lead")

    def __init__(self, kind, text, line, end_line):
        self.kind, self.text, self.line, self.end_line = kind, text, line, end_line
        self.lead = None  # 前导注释（另起一行的第一条注释）所在行

    def __repr__(self):
        return "%s(%r@%d)" % (self.kind, self.text, self.line)


class SwiftSource:
    """一个文件的记号表：有意义的记号（不含注释）与括号配对。"""

    def __init__(self, text):
        self.text = text
        self.tokens = tokenize(text)
        self.match = match_groups(self.tokens)


def _scan_string(src, i):
    """i 指向字符串字面量的开头（`#`… 或 `"`）。返回结尾之后的下标。"""
    n = len(src)
    hashes = 0
    while i < n and src[i] == "#":
        hashes += 1
        i += 1
    if src.startswith('"""', i):
        terminator = '"""' + "#" * hashes
        i += 3
        multiline = True
    else:
        terminator = '"' + "#" * hashes
        i += 1
        multiline = False
    escape = "\\" + "#" * hashes
    while i < n:
        if src.startswith(escape, i):
            j = i + len(escape)
            if j < n and src[j] == "(":
                i = _scan_interpolation(src, j + 1)
                continue
            i = j + 1
            continue
        if src.startswith(terminator, i):
            return i + len(terminator)
        if src[i] == "\n" and not multiline:
            return i  # 单行字符串没收尾：在行尾截断，免得吞掉后面的代码
        i += 1
    return n


def _scan_interpolation(src, i):
    """i 指向插值 `\\(` 之后。返回配对的 `)` 之后的下标。"""
    n = len(src)
    depth = 1
    while i < n:
        char = src[i]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        elif char == '"' or (char == "#" and re.match(r"#+\"", src[i:i + 8])):
            i = _scan_string(src, i)
            continue
        i += 1
    return n


def _scan_regex(src, i, hashes):
    """扩展正则 `#/…/#`：i 指向 `/`。返回结尾之后的下标；找不到收尾返回 None。"""
    terminator = "/" + "#" * hashes
    end = src.find(terminator, i + 1)
    return None if end < 0 else end + len(terminator)


def _bare_regex_end(src, i):
    """裸正则 `/…/`：只在同一行里找收尾，字符类和转义里的 `/` 不算。找不到返回 None。"""
    n = len(src)
    if i + 1 >= n or src[i + 1] in " \t\n\r/*":
        return None
    j = i + 1
    in_class = 0
    while j < n:
        char = src[j]
        if char == "\n":
            return None
        if char == "\\":
            j += 2
            continue
        if char == "[":
            in_class += 1
        elif char == "]" and in_class:
            in_class -= 1
        elif char == "/" and not in_class:
            if src[j - 1] in " \t":
                return None
            return j + 1
        j += 1
    return None


REGEX_PREFIX_KEYWORDS = {"return", "case", "in", "where", "throw", "try", "await", "if", "guard", "while", "else"}


def _regex_allowed(previous):
    if previous is None:
        return True
    if previous.kind == "punct":
        return previous.text in "([{,:;"
    if previous.kind == "op":
        return True
    if previous.kind == "id":
        return previous.text in REGEX_PREFIX_KEYWORDS
    return False


def tokenize(src):
    tokens = []
    n = len(src)
    i = 0
    line = 1
    last_end_line = 0
    pending_lead = None
    previous = None

    def add(kind, text, start_line, end_line):
        nonlocal pending_lead, last_end_line, previous
        token = Token(kind, text, start_line, end_line)
        token.lead = pending_lead
        pending_lead = None
        last_end_line = end_line
        tokens.append(token)
        previous = token

    def comment(start_line):
        nonlocal pending_lead
        if pending_lead is None and (start_line > last_end_line or not tokens):
            pending_lead = start_line

    while i < n:
        char = src[i]
        if char == "\n":
            line += 1
            i += 1
            continue
        if char in " \t\r\f\v﻿":
            i += 1
            continue
        if char == "/" and i + 1 < n and src[i + 1] == "/":
            end = src.find("\n", i)
            end = n if end < 0 else end
            comment(line)
            i = end
            continue
        if char == "/" and i + 1 < n and src[i + 1] == "*":
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            comment(line)
            line += src.count("\n", i, j)
            i = j
            continue
        if char == '"' or (char == "#" and re.match(r"#+\"", src[i:i + 8])):
            j = _scan_string(src, i)
            start = line
            line += src.count("\n", i, j)
            add("str", src[i:j], start, line)
            i = j
            continue
        if char == "#":
            match = re.match(r"(#+)/", src[i:i + 8])
            if match:
                j = _scan_regex(src, i + len(match.group(1)), len(match.group(1)))
                if j is not None:
                    start = line
                    line += src.count("\n", i, j)
                    add("str", src[i:j], start, line)
                    i = j
                    continue
            ident = IDENT_RE.match(src, i + 1)
            if ident:
                add("pound", "#" + ident.group(0), line, line)
                i = ident.end()
                continue
            add("op", "#", line, line)
            i += 1
            continue
        if char == "@":
            match = re.compile(r"@([^\W\d]\w*(?:\.[^\W\d]\w*)*)", re.UNICODE).match(src, i)
            if match:
                add("attr", match.group(1), line, line)
                i = match.end()
                continue
            add("op", "@", line, line)
            i += 1
            continue
        if char == "`":
            end = src.find("`", i + 1)
            if end > 0 and "\n" not in src[i:end]:
                add("id", src[i + 1:end], line, line)
                i = end + 1
                continue
            add("op", "`", line, line)
            i += 1
            continue
        if char.isdigit():
            match = NUMBER_RE.match(src, i)
            add("num", match.group(0), line, line)
            i = match.end()
            continue
        ident = IDENT_RE.match(src, i)
        if ident:
            add("id", ident.group(0), line, line)
            i = ident.end()
            continue
        if char in PUNCT:
            add("punct", char, line, line)
            i += 1
            continue
        if char == "/" and _regex_allowed(previous):
            end = _bare_regex_end(src, i)
            if end is not None:
                add("str", src[i:end], line, line)
                i = end
                continue
        if char in OPERATOR_CHARS:
            j = i
            while j < n and src[j] in OPERATOR_CHARS and not src.startswith("//", j) and not src.startswith("/*", j):
                j += 1
            if j == i:
                j = i + 1
            add("op", src[i:j], line, line)
            i = j
            continue
        add("op", char, line, line)
        i += 1
    return tokens


def match_groups(tokens):
    match = {}
    stack = []
    for index, token in enumerate(tokens):
        if token.kind != "punct":
            continue
        if token.text in OPEN_TO_CLOSE:
            stack.append(index)
        elif token.text in ")]}":
            while stack:
                opener = stack.pop()
                if OPEN_TO_CLOSE[tokens[opener].text] == token.text:
                    match[opener] = index
                    break
    return match


# ---------------------------------------------------------------------------
# 声明

MODIFIERS = {"public", "private", "fileprivate", "internal", "package", "open", "static", "final", "override",
             "required", "convenience", "lazy", "weak", "unowned", "dynamic", "optional", "mutating",
             "nonmutating", "nonisolated", "indirect", "prefix", "postfix", "infix", "distributed",
             "__consuming", "consuming", "borrowing", "isolated", "class"}
MODIFIERS_WITH_ARGUMENT = {"public", "private", "fileprivate", "internal", "package", "open", "unowned",
                           "nonisolated"}
DECL_KEYWORDS = {"var", "let", "func", "init", "deinit", "subscript", "typealias", "struct", "enum", "class",
                 "actor", "protocol", "extension", "case", "associatedtype", "macro", "import", "operator",
                 "precedencegroup"}
TYPE_KEYWORDS = {"class", "struct", "enum", "actor", "protocol", "extension"}
NAMED_SCOPES = {"class", "struct", "enum", "actor", "extension"}
ACCESSOR_KEYWORDS = {"get", "set", "willSet", "didSet", "init", "_modify", "_read", "modify", "read",
                     "unsafeAddress", "unsafeMutableAddress"}
OBSERVATION_ATTRIBUTES = ("ObservationIgnored", "ObservationTracked")


def _is_class_modifier(tokens, index, end):
    """`class` 后面跟着声明关键字或修饰符时是修饰符（class func / class var），否则是类声明。"""
    following = tokens[index + 1] if index + 1 < end else None
    return following is not None and following.kind == "id" and (
        following.text in DECL_KEYWORDS or following.text in MODIFIERS)


def _header_start(tokens, match_back, index):
    """从声明关键字往回走过修饰符与特性，返回声明头第一个记号的下标。"""
    j = index - 1
    start = index
    while j >= 0:
        token = tokens[j]
        if token.kind == "attr":
            start = j
            j -= 1
            continue
        if token.kind == "id" and token.text in MODIFIERS and tokens[start].line == token.end_line:
            start = j
            j -= 1
            continue
        if token.kind == "punct" and token.text == ")" and j in match_back:
            opener = match_back[j]
            if opener > 0 and (tokens[opener - 1].kind == "attr" or
                               (tokens[opener - 1].kind == "id" and tokens[opener - 1].text in MODIFIERS_WITH_ARGUMENT)):
                start = opener - 1
                j = opener - 2
                continue
        break
    return start


def _at_declaration_start(tokens, start):
    if start == 0:
        return True
    previous = tokens[start - 1]
    if previous.kind == "punct" and previous.text in "{};":
        return True
    return previous.end_line < tokens[start].line


class TypeDecl:
    __slots__ = ("kind", "name", "qualified", "top_level", "attributes", "modifiers", "decl_line",
                 "open_index", "close_index")

    @property
    def observable(self):
        return any(name in ("Observable", "Observation.Observable") for name in self.attributes)


def find_types(source):
    """文件里所有类型声明（含嵌套、函数体里的），带外层作用域的名字。"""
    tokens, match = source.tokens, source.match
    match_back = {close: opener for opener, close in match.items()}
    found = []
    pending = {}
    stack = []  # (close_index, kind, name)
    count = len(tokens)
    for index, token in enumerate(tokens):
        while stack and stack[-1][0] is not None and stack[-1][0] <= index:
            stack.pop()
        if token.kind == "id" and token.text in TYPE_KEYWORDS and index + 1 < count:
            name_token = tokens[index + 1]
            previous = tokens[index - 1] if index else None
            if (name_token.kind == "id" and name_token.line == token.line
                    and not (previous is not None and previous.kind == "op" and previous.text.endswith("."))
                    and not (token.text == "class" and _is_class_modifier(tokens, index, count))):
                start = _header_start(tokens, match_back, index)
                if _at_declaration_start(tokens, start):
                    opener = _find_body(tokens, match, index + 1)
                    if opener is not None:
                        decl = TypeDecl()
                        decl.kind = token.text
                        if token.text == "extension":
                            decl.name = _extended_type(tokens, index + 1, opener)
                        else:
                            decl.name = name_token.text
                        names = [name for _, kind, name in stack if kind in NAMED_SCOPES]
                        decl.qualified = ".".join(names + [decl.name])
                        decl.top_level = not stack
                        decl.attributes = [t.text for t in tokens[start:index] if t.kind == "attr"]
                        decl.modifiers = {t.text for t in tokens[start:index] if t.kind == "id" and t.text in MODIFIERS}
                        decl.decl_line = tokens[start].line
                        decl.open_index = opener
                        decl.close_index = match.get(opener)
                        found.append(decl)
                        pending[opener] = (token.text, decl.name)
        if token.kind == "punct" and token.text == "{":
            kind, name = pending.pop(index, ("block", None))
            stack.append((match.get(index), kind, name))
    return found


def _find_body(tokens, match, index):
    limit = min(len(tokens), index + 400)
    j = index
    while j < limit:
        token = tokens[j]
        if token.kind == "punct":
            if token.text == "{":
                return j
            if token.text in "([" and j in match:
                j = match[j] + 1
                continue
            if token.text in ";}":
                return None
        j += 1
    return None


def _extended_type(tokens, start, opener):
    parts = []
    for token in tokens[start:opener]:
        if (token.kind == "punct" and token.text == ":") or (token.kind == "id" and token.text == "where"):
            break
        parts.append(token.text)
    return "".join(parts)


# ---------------------------------------------------------------------------
# 类体成员

class Member:
    __slots__ = ("kind", "name", "decision", "reason", "intrinsic", "decls", "children", "start_line",
                 "decl_line", "end_line")

    def __init__(self, kind, name, decision, reason, decls=1, children=None):
        self.kind, self.name, self.decision, self.reason = kind, name, decision, reason
        self.intrinsic = decision
        self.decls = decls
        self.children = children
        self.start_line = self.decl_line = self.end_line = 0


def _starts_member(tokens, k):
    token = tokens[k]
    if token.line <= tokens[k - 1].end_line and not (tokens[k - 1].kind == "punct" and tokens[k - 1].text == ";"):
        return False
    if token.kind in ("attr", "pound"):
        return True
    return token.kind == "id" and (token.text in DECL_KEYWORDS or token.text in MODIFIERS)


def parse_members(source, lo, hi):
    tokens, match = source.tokens, source.match
    members = []
    i = lo
    while i < hi:
        token = tokens[i]
        if token.kind == "punct" and token.text == ";":
            i += 1
            continue
        if token.kind == "pound" and token.text == "#if":
            end, member = _parse_if_region(source, i, hi)
            members.append(member)
            i = end
            continue
        attributes, modifiers = [], set()
        j = i
        while j < hi:
            current = tokens[j]
            if current.kind == "attr":
                attributes.append(current.text)
                j += 1
                if j < hi and tokens[j].kind == "punct" and tokens[j].text == "(" and tokens[j].line == tokens[j - 1].line:
                    j = match.get(j, j) + 1
                continue
            if current.kind == "id" and current.text in MODIFIERS:
                if current.text == "class" and not _is_class_modifier(tokens, j, hi):
                    break
                modifiers.add(current.text)
                j += 1
                if (current.text in MODIFIERS_WITH_ARGUMENT and j < hi and tokens[j].kind == "punct"
                        and tokens[j].text == "("):
                    j = match.get(j, j) + 1
                continue
            break
        keyword_index = j
        k = j + 1
        while k < hi:
            current = tokens[k]
            if current.kind == "punct":
                if current.text in "([{" and k in match:
                    k = match[k] + 1
                    continue
                if current.text == ";":
                    k += 1
                    break
            if _starts_member(tokens, k):
                break
            k += 1
        k = min(k, hi)
        member = _classify(source, attributes, modifiers, keyword_index, k)
        member.start_line = tokens[i].lead or tokens[i].line
        member.decl_line = tokens[i].line
        member.end_line = tokens[k - 1].end_line
        members.append(member)
        i = k
    return members


def _parse_if_region(source, i, hi):
    tokens, match = source.tokens, source.match
    clauses = []
    depth = 0
    directive = i
    j = i + 1
    end = hi
    while j < hi:
        token = tokens[j]
        if token.kind == "punct" and token.text in "([{" and j in match:
            j = match[j] + 1
            continue
        if token.kind == "pound":
            if token.text == "#if":
                depth += 1
            elif token.text == "#endif":
                if depth == 0:
                    clauses.append((directive, j))
                    end = j + 1
                    break
                depth -= 1
            elif token.text in ("#elseif", "#else") and depth == 0:
                clauses.append((directive, j))
                directive = j
        j += 1
    else:
        clauses.append((directive, hi))
    children = []
    for directive_index, clause_end in clauses:
        body = directive_index + 1
        line = tokens[directive_index].line
        while body < clause_end and tokens[body].line == line:
            body = match.get(body, body) + 1 if tokens[body].kind == "punct" and tokens[body].text == "(" else body + 1
        children.extend(parse_members(source, body, clause_end))
    condition_tokens = []
    k = i + 1
    while k < len(tokens) and tokens[k].line == tokens[i].line:
        condition_tokens.append(tokens[k].text)
        k += 1
    condition = " ".join(condition_tokens)
    decls = sum(child.decls for child in children)
    staying = [child for child in children if child.decision == "stay"]
    if staying:
        reasons = ", ".join(sorted({child.reason for child in staying}))
        member = Member("#if region", condition, "stay", "#if region containing: " + reasons, decls, children)
    else:
        member = Member("#if region", condition, "move", "#if region without instance stored state", decls, children)
    member.start_line = tokens[i].lead or tokens[i].line
    member.decl_line = tokens[i].line
    member.end_line = tokens[min(end, len(tokens)) - 1].end_line
    return end, member


def _accessor_specifiers(tokens, match, opener):
    """访问器块里各访问器的关键字；第一个不是访问器关键字时是隐式 getter，返回 None。"""
    close = match.get(opener)
    if close is None:
        return None
    specifiers = []
    j = opener + 1
    expect = True
    while j < close:
        token = tokens[j]
        if expect:
            if token.kind == "attr":
                j += 1
                if j < close and tokens[j].kind == "punct" and tokens[j].text == "(":
                    j = match.get(j, j) + 1
                continue
            if token.kind == "id" and token.text in ("mutating", "nonmutating", "__consuming", "consuming"):
                j += 1
                continue
            following = tokens[j + 1] if j + 1 < len(tokens) else None
            if (token.kind == "id" and token.text in ACCESSOR_KEYWORDS and following is not None and
                    (following.text in ("{", "(", "}", "async", "throws") or following.text in ACCESSOR_KEYWORDS)):
                specifiers.append(token.text)
                expect = False
                j += 1
                continue
            return None if not specifiers else specifiers
        if token.kind == "punct" and token.text == "{" and j in match:
            j = match[j] + 1
            expect = True
            continue
        if token.kind == "id" and token.text in ACCESSOR_KEYWORDS:
            specifiers.append(token.text)
        j += 1
    return specifiers


def _binding_segments(tokens, match, start, end):
    segments = []
    angle = 0
    segment_start = start
    j = start
    while j < end:
        token = tokens[j]
        if token.kind == "punct":
            if token.text in "([{" and j in match:
                j = match[j] + 1
                continue
            if token.text == "," and angle == 0:
                segments.append((segment_start, j))
                segment_start = j + 1
        elif token.kind == "op" and set(token.text) <= {"<", ">"}:
            angle += token.text.count("<") - token.text.count(">")
            angle = max(angle, 0)
        j += 1
    segments.append((segment_start, end))
    return segments


def _classify_variable(source, attributes, modifiers, keyword_index, end):
    tokens, match = source.tokens, source.match
    keyword = tokens[keyword_index].text
    is_static = "static" in modifiers or "class" in modifiers
    names = []
    stored = keyword == "let"
    observed = False
    init_accessor = False
    for seg_start, seg_end in _binding_segments(tokens, match, keyword_index + 1, end):
        if seg_start < seg_end:
            names.append(tokens[seg_start].text)
        has_initializer = False
        accessor_block = None
        j = seg_start
        while j < seg_end:
            token = tokens[j]
            if token.kind == "op" and token.text == "=":
                has_initializer = True
            if token.kind == "punct" and token.text in "([" and j in match:
                j = match[j] + 1
                continue
            if token.kind == "punct" and token.text == "{":
                if not has_initializer:
                    accessor_block = j
                break
            j += 1
        if has_initializer or accessor_block is None:
            stored = True
            continue
        specifiers = _accessor_specifiers(tokens, match, accessor_block)
        if specifiers is None:
            continue  # 隐式 getter
        if "init" in specifiers:
            init_accessor = True
        if specifiers and set(specifiers) <= {"willSet", "didSet"}:
            stored = True
            observed = True
    name = ", ".join(names)
    observation = any(a.endswith(OBSERVATION_ATTRIBUTES) for a in attributes)
    if stored:
        kind = "static stored property" if is_static else "stored property"
        if "lazy" in modifiers:
            kind = "lazy " + kind
        if observed:
            kind += " (observed)"
        if is_static:
            if observation:
                return Member(kind, name, "stay", "observation attribute on static stored property")
            return Member(kind, name, "move", "static stored property")
        return Member(kind, name, "stay", "stored property")
    kind = "static computed property" if is_static else "computed property"
    if init_accessor:
        return Member(kind, name, "stay", "init accessor")
    if "override" in modifiers:
        return Member(kind, name, "stay", "override")
    if observation:
        return Member(kind, name, "stay", "observation attribute on computed property")
    return Member(kind, name, "move", kind)


def _classify(source, attributes, modifiers, keyword_index, end):
    tokens = source.tokens
    if keyword_index >= end:
        return Member("other", "", "stay", "unhandled declaration kind")
    keyword = tokens[keyword_index]
    following = tokens[keyword_index + 1].text if keyword_index + 1 < end else ""
    if keyword.kind == "pound":
        return Member("macro expansion", keyword.text, "stay", "freestanding macro")
    text = keyword.text if keyword.kind == "id" else ""
    if text in ("var", "let"):
        return _classify_variable(source, attributes, modifiers, keyword_index, end)
    is_static = "static" in modifiers or "class" in modifiers
    if text == "func":
        kind = "static function" if is_static else "function"
        if "override" in modifiers:
            return Member(kind, following, "stay", "override")
        return Member(kind, following, "move", kind)
    if text == "init":
        if "override" in modifiers:
            return Member("initializer", "init", "stay", "override")
        if "required" in modifiers:
            return Member("initializer", "init", "stay", "required init")
        if "convenience" in modifiers:
            return Member("convenience initializer", "init", "move", "convenience initializer")
        return Member("initializer", "init", "stay", "designated init")
    if text == "deinit":
        return Member("deinit", "deinit", "stay", "deinit")
    if text == "subscript":
        if "override" in modifiers:
            return Member("subscript", "subscript", "stay", "override")
        return Member("subscript", "subscript", "move", "subscript")
    if text in ("struct", "enum", "class", "actor", "protocol"):
        return Member("nested " + text, following, "move", "nested type")
    if text == "typealias":
        return Member("typealias", following, "move", "typealias")
    if text == "case":
        return Member("enum case", "case", "stay", "enum case")
    if text == "associatedtype":
        return Member("associatedtype", "associatedtype", "stay", "associatedtype")
    return Member("other: " + (keyword.text or ""), "", "stay", "unhandled declaration kind")


class ClassReport:
    __slots__ = ("decl", "members", "body_decls", "stay_decls", "move_decls", "stay_reasons", "offending")


def _offending(members):
    """该移出类体的成员：本身可移动的成员（不管是否与别的声明共用一行），以及留在类体的 #if 块里可移动的成员。"""
    result = []
    for member in members:
        if member.kind == "#if region":
            if member.intrinsic == "move":
                result.append(member)
            else:
                result.extend(_offending(member.children or []))
        elif member.intrinsic == "move":
            result.append(member)
    return result


def analyze_class(source, decl):
    tokens = source.tokens
    if decl.close_index is None:
        return None
    members = parse_members(source, decl.open_index + 1, decl.close_index)
    open_line = tokens[decl.open_index].line
    close_line = tokens[decl.close_index].line
    for index, member in enumerate(members):
        shared = member.start_line <= open_line or member.end_line >= close_line
        if index > 0 and member.start_line <= members[index - 1].end_line:
            shared = True
        if index + 1 < len(members) and members[index + 1].start_line <= member.end_line:
            shared = True
        if shared and member.decision == "move":
            member.decision = "stay"
            member.reason = "shares a line with another declaration or a brace"
    report = ClassReport()
    report.decl = decl
    report.members = members
    report.body_decls = sum(m.decls for m in members)
    report.stay_decls = sum(m.decls for m in members if m.decision == "stay")
    report.move_decls = sum(m.decls for m in members if m.decision == "move")
    reasons = {}
    for member in members:
        if member.decision == "stay":
            reasons[member.reason] = reasons.get(member.reason, 0) + member.decls
    report.stay_reasons = reasons
    report.offending = _offending(members)
    return report


def observable_classes(text):
    """文件里所有 `@Observable` 类的类体分析（包括嵌套在别的类型或函数里的）。"""
    if "Observable" not in text:
        return []
    source = SwiftSource(text)
    reports = []
    for decl in find_types(source):
        if decl.kind == "class" and decl.observable:
            report = analyze_class(source, decl)
            if report is not None:
                reports.append(report)
    return reports


IMPORT_LINE_RE = re.compile(r"^[ \t]*(?:@[\w.]+(?:\([^)\n]*\))?[ \t]+)*import[ \t]+"
                            r"(?:(?:typealias|struct|class|enum|protocol|let|var|func|actor)[ \t]+)?([\w]+)",
                            re.MULTILINE)


def imports(text, names=None):
    """[(行号, 模块名)]：文件里的 import（字符串和注释里的不算）。给了 names 时只找这些模块。"""
    candidates = [(text.count("\n", 0, m.start()) + 1, m.group(1)) for m in IMPORT_LINE_RE.finditer(text)
                  if names is None or m.group(1) in names]
    if not candidates:
        return []
    tokens = tokenize(text)
    real = []
    for index, token in enumerate(tokens):
        if token.kind == "id" and token.text == "import" and index + 1 < len(tokens):
            j = index + 1
            if tokens[j].kind == "id" and tokens[j].text in ("typealias", "struct", "class", "enum", "protocol",
                                                            "let", "var", "func", "actor"):
                j += 1
            if j < len(tokens) and tokens[j].kind == "id":
                real.append((token.line, tokens[j].text))
    real_set = set(real)
    return [candidate for candidate in candidates if candidate in real_set]
