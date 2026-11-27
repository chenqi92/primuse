"""关卡的公共部分：配置、发现、被检查的树（工作区、暂存区、某个提交）、基线文件和输出。"""
import json
import os
import re
import shutil
import subprocess
import sys

EMPTY_TREE_SHA1 = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


class GateError(Exception):
    """用法或环境错误：打印后以 1 退出。"""


# ---------------------------------------------------------------------------
# 配置

class Config:
    def __init__(self, path):
        self.path = os.path.abspath(path)
        with open(self.path, encoding="utf-8") as handle:
            self.data = json.load(handle)
        self.directory = os.path.dirname(self.path)
        self.tool_root = os.path.normpath(os.path.join(self.directory, self.data.get("tool_root", "../..")))

    def rule(self, rule_id):
        return self.data.get("rules", {}).get(rule_id, {})

    def severity(self, rule_id):
        return self.rule(rule_id).get("severity", "error")

    def enabled(self, rule_id):
        spec = self.rule(rule_id)
        return bool(spec) and spec.get("enabled", True)

    def tool_path(self, relative):
        return os.path.join(self.tool_root, relative)

    @property
    def test_prefixes(self):
        return tuple(self.data.get("test_prefixes", []))

    def is_test(self, path):
        return path.startswith(self.test_prefixes)


# ---------------------------------------------------------------------------
# 发现

class Finding:
    __slots__ = ("rule", "severity", "path", "line", "message", "fix", "subject")

    def __init__(self, rule, severity, path, line, message, fix, subject=None):
        self.rule, self.severity, self.path, self.line = rule, severity, path, line
        self.message, self.fix, self.subject = message, fix, subject

    def location(self):
        if self.path and self.line:
            return "%s:%d" % (self.path, self.line)
        if self.path:
            return self.path
        return self.subject or "(仓库)"


# ---------------------------------------------------------------------------
# 路径匹配

_GLOB_CACHE = {}


def glob_regex(pattern):
    """把 `**`、`*`、`?`、`[…]` 的路径通配符转成正则；`**/` 匹配零层或多层目录。"""
    cached = _GLOB_CACHE.get(pattern)
    if cached is not None:
        return cached
    out = []
    i = 0
    while i < len(pattern):
        char = pattern[i]
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif char == "*":
            out.append("[^/]*")
            i += 1
        elif char == "?":
            out.append("[^/]")
            i += 1
        elif char == "[":
            end = pattern.find("]", i + 1)
            if end < 0:
                out.append(re.escape(char))
                i += 1
            else:
                out.append(pattern[i:end + 1])
                i = end + 1
        else:
            out.append(re.escape(char))
            i += 1
    compiled = re.compile("^" + "".join(out) + "$")
    _GLOB_CACHE[pattern] = compiled
    return compiled


def glob_match(path, pattern):
    return bool(glob_regex(pattern).match(path))


def matches_any(path, patterns):
    return any(glob_match(path, pattern) for pattern in patterns)


def matches_self_or_ancestor(relative, patterns):
    """XcodeGen 的 excludes：通配符命中文件本身或它的某一级上层目录都算排除。"""
    parts = relative.split("/")
    for depth in range(1, len(parts) + 1):
        if matches_any("/".join(parts[:depth]), patterns):
            return True
    return False


# ---------------------------------------------------------------------------
# Git

def git(root, *args, check=True, input_bytes=None):
    try:
        result = subprocess.run(["git", "-C", root] + list(args), capture_output=True, input=input_bytes)
    except OSError as error:
        raise GateError("运行 git 失败：%s" % error)
    if check and result.returncode != 0:
        raise GateError("git %s 失败：%s" % (" ".join(args), result.stderr.decode("utf-8", "replace").strip()))
    return result


def git_text(root, *args, check=True):
    return git(root, *args, check=check).stdout.decode("utf-8", "replace")


def is_git_repo(root):
    if shutil.which("git") is None:
        return False
    result = subprocess.run(["git", "-C", root, "rev-parse", "--is-inside-work-tree"], capture_output=True)
    return result.returncode == 0 and result.stdout.strip() == b"true"


def rev_parse(root, rev):
    result = git(root, "rev-parse", "--verify", "--quiet", rev + "^{commit}", check=False)
    if result.returncode != 0:
        return None
    return result.stdout.decode().strip()


def is_zero_sha(sha):
    return bool(sha) and set(sha) == {"0"}


def empty_tree(root):
    result = git(root, "hash-object", "-t", "tree", "--stdin", check=False, input_bytes=b"")
    sha = result.stdout.decode().strip()
    return sha or EMPTY_TREE_SHA1


class BatchReader:
    """一个常驻的 `git cat-file --batch`，按对象名读内容。"""

    def __init__(self, root):
        self.root = root
        self.process = None

    def read(self, name):
        if self.process is None:
            self.process = subprocess.Popen(["git", "-C", self.root, "cat-file", "--batch"],
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.process.stdin.write(name.encode("utf-8") + b"\n")
        self.process.stdin.flush()
        header = self.process.stdout.readline().decode("utf-8", "replace").rstrip("\n")
        if header.endswith(" missing") or header.endswith(" ambiguous") or not header:
            return None
        size = int(header.split()[-1])
        data = self.process.stdout.read(size)
        self.process.stdout.read(1)
        return data

    def close(self):
        if self.process is not None:
            self.process.stdin.close()
            self.process.wait()
            self.process = None


# ---------------------------------------------------------------------------
# 被检查的树

class Tree:
    """文件列表加读取。路径一律是仓库相对路径、用 `/` 分隔。"""

    label = ""
    disk_root = None  # 这棵树在磁盘上原样存在时的目录，外部脚本只能在这种树上跑

    def __init__(self):
        self._files = None
        self._dirs = None
        self._cache = {}

    def _load(self):
        raise NotImplementedError

    def files(self):
        if self._files is None:
            self._files = self._load()  # {path: is_symlink}
        return self._files

    def paths(self):
        return sorted(self.files())

    def exists(self, path):
        return path in self.files()

    def is_symlink(self, path):
        return self.files().get(path, False)

    def is_dir(self, path):
        if self._dirs is None:
            dirs = set()
            for file_path in self.files():
                parts = file_path.split("/")[:-1]
                for depth in range(1, len(parts) + 1):
                    dirs.add("/".join(parts[:depth]))
            self._dirs = dirs
        return path.rstrip("/") in self._dirs

    def read_bytes(self, path):
        raise NotImplementedError

    def read(self, path):
        if path in self._cache:
            return self._cache[path]
        data = self.read_bytes(path)
        text = None if data is None else data.decode("utf-8", "replace")
        if len(self._cache) < 4096:
            self._cache[path] = text
        return text

    def close(self):
        pass


class DictTree(Tree):
    """自检用的内存树。"""

    label = "样例"

    def __init__(self, files):
        Tree.__init__(self)
        self.contents = dict(files)

    def _load(self):
        return {path: False for path in self.contents}

    def read_bytes(self, path):
        text = self.contents.get(path)
        return None if text is None else text.encode("utf-8")


class WorkTree(Tree):
    label = "工作区"

    def __init__(self, root, use_git=True):
        Tree.__init__(self)
        self.root = root
        self.disk_root = root
        self.use_git = use_git

    def _load(self):
        files = {}
        if self.use_git:
            tracked = git(self.root, "ls-files", "-z", "--cached").stdout.decode("utf-8", "replace").split("\0")
            others = git(self.root, "ls-files", "-z", "--others", "--exclude-standard").stdout.decode(
                "utf-8", "replace").split("\0")
            for path in tracked + others:
                if not path or path in files:
                    continue
                full = os.path.join(self.root, path)
                if os.path.islink(full):
                    files[path] = True
                elif os.path.isfile(full):
                    files[path] = False
            return files
        skip = {".git", "build", ".build", "DerivedData", "node_modules", ".swiftpm"}
        for directory, subdirectories, names in os.walk(self.root):
            subdirectories[:] = [d for d in subdirectories if d not in skip]
            for name in names:
                full = os.path.join(directory, name)
                relative = os.path.relpath(full, self.root).replace(os.sep, "/")
                files[relative] = os.path.islink(full)
        return files

    def read_bytes(self, path):
        try:
            with open(os.path.join(self.root, path), "rb") as handle:
                return handle.read()
        except OSError:
            return None


class _GitObjectTree(Tree):
    def __init__(self, root):
        Tree.__init__(self)
        self.root = root
        self.reader = BatchReader(root)
        self.blobs = {}

    def read_bytes(self, path):
        self.files()  # 对象名在列文件时才拿到
        sha = self.blobs.get(path)
        if sha is None:
            return None
        return self.reader.read(sha)

    def close(self):
        self.reader.close()


class IndexTree(_GitObjectTree):
    label = "暂存区"

    def _load(self):
        files = {}
        output = git(self.root, "ls-files", "-z", "-s").stdout.decode("utf-8", "replace")
        for entry in output.split("\0"):
            if not entry:
                continue
            meta, path = entry.split("\t", 1)
            mode, sha, stage = meta.split()
            if path in files or mode == "160000":
                continue
            files[path] = mode == "120000"
            self.blobs[path] = sha
        return files


class CommitTree(_GitObjectTree):
    def __init__(self, root, rev):
        _GitObjectTree.__init__(self, root)
        self.rev = rev
        self.label = "提交 %s" % rev[:10]

    def _load(self):
        files = {}
        if self.rev is None:
            return files
        output = git(self.root, "ls-tree", "-r", "-z", "--full-tree", self.rev).stdout.decode("utf-8", "replace")
        for entry in output.split("\0"):
            if not entry:
                continue
            meta, path = entry.split("\t", 1)
            mode, kind, sha = meta.split()
            if kind != "blob":
                continue
            files[path] = mode == "120000"
            self.blobs[path] = sha
        return files


# ---------------------------------------------------------------------------
# 改动

class Change:
    __slots__ = ("status", "path", "old_path")

    def __init__(self, status, path, old_path=None):
        self.status, self.path, self.old_path = status, path, old_path


def parse_name_status(raw):
    """`git diff --name-status -z -M` 的输出。"""
    parts = raw.decode("utf-8", "replace").split("\0")
    changes = []
    i = 0
    while i < len(parts):
        status = parts[i]
        if not status:
            i += 1
            continue
        letter = status[0]
        if letter in "RC":
            changes.append(Change(letter, parts[i + 2], parts[i + 1]))
            i += 3
        else:
            changes.append(Change(letter, parts[i + 1]))
            i += 2
    return changes


def staged_changes(root):
    head = rev_parse(root, "HEAD")
    against = head or empty_tree(root)
    raw = git(root, "diff", "--cached", "--name-status", "-z", "-M", "--no-ext-diff", against).stdout
    return parse_name_status(raw)


def range_changes(root, base, head):
    raw = git(root, "diff", "--name-status", "-z", "-M", "--no-ext-diff", base, head).stdout
    return parse_name_status(raw)


def worktree_changes(root):
    """工作区相对 HEAD 的改名（给 --update-baseline 认出移动过的大文件）。"""
    if rev_parse(root, "HEAD") is None:
        return []
    raw = git(root, "diff", "--name-status", "-z", "-M", "--no-ext-diff", "HEAD", check=False).stdout
    return parse_name_status(raw)


def resolve_range(root, spec):
    """`A..B` → (合并基点, B 的提交号, A 的提交号)。A 是全零或空时退到 B 的父提交之前（整棵树都算新的）。"""
    if ".." not in spec:
        raise GateError("范围要写成 <base>..<head>：%s" % spec)
    base_spec, head_spec = spec.split("...", 1) if "..." in spec else spec.split("..", 1)
    head = rev_parse(root, head_spec or "HEAD")
    if head is None:
        raise GateError("找不到提交 %s" % head_spec)
    if not base_spec or is_zero_sha(base_spec):
        return empty_tree(root), head, None
    base = rev_parse(root, base_spec)
    if base is None:
        raise GateError("找不到提交 %s（CI 里要 fetch-depth: 0）" % base_spec)
    merge_base = git_text(root, "merge-base", base, head, check=False).strip()
    return (merge_base or base), head, base


# ---------------------------------------------------------------------------
# 基线

GROWTH_NOTE_PREFIX = "# 放宽："


class Baseline:
    """TSV：若干列键加最后一列计数。以 `#` 开头的行是说明；`# 放宽：` 开头的是放宽记录。"""

    def __init__(self, path, columns, header=None):
        self.path = path
        self.columns = columns
        self.header = header or []
        self.notes = []
        self.entries = {}

    @classmethod
    def parse(cls, path, columns, text):
        baseline = cls(path, columns)
        if text is None:
            return baseline
        for raw in text.split("\n"):
            line = raw.rstrip("\r")
            if not line.strip():
                continue
            if line.startswith("#"):
                if line.startswith(GROWTH_NOTE_PREFIX):
                    baseline.notes.append(line)
                else:
                    baseline.header.append(line)
                continue
            fields = line.split("\t")
            if len(fields) != len(columns):
                continue
            try:
                baseline.entries[tuple(fields[:-1])] = int(fields[-1])
            except ValueError:
                continue
        return baseline

    def key_path(self, key):
        return key[self.columns.index("path")] if "path" in self.columns else None

    def render(self):
        lines = list(self.header) + list(self.notes)
        for key in sorted(self.entries):
            lines.append("\t".join(list(key) + [str(self.entries[key])]))
        return "\n".join(lines) + "\n"

    def total(self):
        return sum(self.entries.values())


def remap_key(baseline, key, renames):
    """改名后的文件按原路径查基线。renames: 新路径 → 旧路径。"""
    if not renames or "path" not in baseline.columns:
        return key
    index = baseline.columns.index("path")
    old = renames.get(key[index])
    if old is None:
        return key
    key = list(key)
    key[index] = old
    return tuple(key)


def compare_baselines(old, new, renames=None):
    """new 相对 old 变大的项：[(键, 旧数, 新数)]。改名的文件按旧路径比。"""
    grew = []
    for key, count in sorted(new.entries.items()):
        previous = old.entries.get(remap_key(new, key, renames))
        if previous is None:
            previous = old.entries.get(key, 0)
        if count > previous:
            grew.append((key, previous, count))
    return grew


# ---------------------------------------------------------------------------
# 输出

def _escape_data(text):
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def _escape_property(text):
    return _escape_data(text).replace(":", "%3A").replace(",", "%2C")


def github_annotation(finding):
    level = "error" if finding.severity == "error" else "warning"
    props = []
    if finding.path:
        props.append("file=" + _escape_property(finding.path))
        if finding.line:
            props.append("line=%d" % finding.line)
    title = finding.rule if not finding.subject else "%s %s" % (finding.rule, finding.subject)
    props.append("title=" + _escape_property(title))
    message = finding.message + ("\n改法：" + finding.fix if finding.fix else "")
    return "::%s %s::%s" % (level, ",".join(props), _escape_data(message))


def format_text(finding):
    label = "错误" if finding.severity == "error" else "警告"
    text = "%s: [%s] %s：%s" % (finding.location(), finding.rule, label, finding.message)
    if finding.fix:
        text += "\n    改法：" + finding.fix
    return text


class Report:
    def __init__(self, fmt="text", stream=None):
        self.format = fmt
        self.stream = stream or sys.stdout
        self.findings = []
        self.skipped = []  # (rule, why, optional)
        self.notes = []
        self.ran = []  # (rule, severity)
        self.not_applicable = []  # 这次的改动与之无关的规则

    def add(self, findings):
        self.findings.extend(findings)

    def skip(self, rule, why, optional):
        self.skipped.append((rule, why, optional))

    def note(self, text):
        self.notes.append(text)

    def errors(self):
        return [f for f in self.findings if f.severity == "error"]

    def warnings(self):
        return [f for f in self.findings if f.severity != "error"]

    def failed(self, require_all):
        if self.errors():
            return True
        return require_all and any(not optional for _, _, optional in self.skipped)

    def emit(self, require_all, header, quiet_pass=False):
        out = self.stream
        failed = self.failed(require_all)
        if quiet_pass and not failed and not self.findings:
            return failed
        out.write(header + "\n")
        for finding in self.findings:
            if self.format == "github":
                out.write(github_annotation(finding) + "\n")
            out.write(format_text(finding) + "\n")
        for rule, why, optional in self.skipped:
            hard = require_all and not optional
            if self.format == "github":
                level = "error" if hard else "notice"
                out.write("::%s title=%s::%s\n" % (level, _escape_property("SKIPPED " + rule), _escape_data(why)))
            out.write("SKIPPED %s: %s%s\n" % (rule, why, "（--require-all 下算失败）" if hard else ""))
        for text in self.notes:
            out.write(text + "\n")
        errors, warnings = len(self.errors()), len(self.warnings())
        verdict = "没通过" if failed else "通过"
        out.write("架构关卡%s：%d 个错误，%d 个警告，%d 条规则跳过。\n" % (verdict, errors, warnings, len(self.skipped)))
        if self.format == "github":
            self.write_summary(header, failed, require_all)
        return failed

    def write_summary(self, header, failed, require_all):
        path = os.environ.get("GITHUB_STEP_SUMMARY")
        if not path:
            return
        lines = ["## 架构关卡：%s" % ("没通过" if failed else "通过"), "", header, "",
                 "| 规则 | 级别 | 结果 |", "| --- | --- | --- |"]
        by_rule = {}
        for finding in self.findings:
            by_rule.setdefault(finding.rule, []).append(finding)
        skipped = {rule: (why, optional) for rule, why, optional in self.skipped}
        for rule, severity in self.ran:
            found = by_rule.get(rule.split("/")[0], []) + [f for r, fs in by_rule.items() if r.startswith(rule + "/") for f in fs]
            if rule in skipped:
                result = "跳过：" + skipped[rule][0]
            elif rule in self.not_applicable:
                result = "这次的改动与它无关"
            elif found:
                result = "%d 处" % len(found)
            else:
                result = "通过"
            lines.append("| `%s` | %s | %s |" % (rule, severity, result.replace("|", "\\|")))
        if self.findings:
            lines += ["", "### 发现", ""]
            for finding in self.findings[:100]:
                lines.append("- **%s** `%s` %s%s" % (finding.rule, finding.location(), finding.message,
                                                     ("　改法：" + finding.fix) if finding.fix else ""))
            if len(self.findings) > 100:
                lines.append("- ……另有 %d 处，见日志" % (len(self.findings) - 100))
        try:
            with open(path, "a", encoding="utf-8") as handle:
                handle.write("\n".join(lines) + "\n\n")
        except OSError:
            pass
