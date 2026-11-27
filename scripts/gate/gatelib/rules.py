"""各条规则。每条规则读 Context，返回 Finding 列表；按基线执行的规则同时把现状计数记进 ctx.counts。"""
import contextlib
import importlib.util
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

from . import core, formats, swiftscan
from .core import Finding

BASELINE_COLUMNS = {
    "file-size": ["path", "lines"],
    "observable-class-body": ["path", "class", "count"],
    "layering": ["path", "count"],
    "library-scale": ["rule", "path", "count"],
}


class RuleInfo:
    def __init__(self, rule_id, title, kind, function, modes):
        self.id, self.title, self.kind, self.function, self.modes = rule_id, title, kind, function, modes


REGISTRY = []


def rule(rule_id, title, kind, modes=("all", "staged", "range")):
    def register(function):
        REGISTRY.append(RuleInfo(rule_id, title, kind, function, modes))
        return function
    return register


def rule_info(rule_id):
    for info in REGISTRY:
        if info.id == rule_id:
            return info
    return None


class Skip(Exception):
    """规则跑不了（缺工具或输入）。"""


class NotApplicable(Exception):
    """这次的改动与这条规则无关（只在 --staged、--range 时出现）。"""


class Context:
    def __init__(self, config, tree, mode, changes=None, base_tree=None, strict_baselines=False, root=None):
        self.config = config
        self.tree = tree
        self.mode = mode  # all | staged | range
        self.changes = changes
        self.base_tree = base_tree
        self.strict_baselines = strict_baselines
        self.root = root
        self.renames = {c.path: c.old_path for c in (changes or []) if c.status == "R"}
        self.counts = {}
        self.tighten = []  # (规则, 键, 基线数, 现在数)
        self.notes = []
        self._swift = None

    # 范围 ---------------------------------------------------------------
    def changed_paths(self):
        if self.changes is None:
            return None
        return {c.path for c in self.changes if c.status != "D"}

    def touched(self, patterns):
        """staged / range 模式里有没有改到这些路径（含删除与改名前的路径）。"""
        if self.changes is None:
            return True
        for change in self.changes:
            for path in (change.path, change.old_path):
                if path and core.matches_any(path, patterns):
                    return True
        return False

    def in_scope(self, path):
        swift = self.config.data.get("swift", {})
        if not path.endswith(tuple(swift.get("extensions", [".swift"]))):
            return False
        if core.matches_any(path, swift.get("exclude", [])):
            return False
        if self.tree.is_symlink(path):
            return False
        return True

    def is_generated(self, path, text):
        markers = self.config.data.get("swift", {}).get("generated_markers", [])
        if not markers:
            return False
        head = "\n".join(text.split("\n", 4)[:4])
        return any(marker in head for marker in markers)

    def swift_files(self):
        """per-file 规则要看的 Swift 文件：--all 是全部，其余模式是改到的那些。"""
        if self._swift is None:
            changed = self.changed_paths()
            candidates = self.tree.paths() if changed is None else sorted(p for p in changed if self.tree.exists(p))
            result = []
            for path in candidates:
                if not self.in_scope(path):
                    continue
                text = self.tree.read(path)
                if text is None or self.is_generated(path, text):
                    continue
                result.append(path)
            self._swift = result
        return self._swift

    # 基线 ---------------------------------------------------------------
    def baseline_path(self, rule_id):
        return self.config.rule(rule_id).get("baseline")

    def baseline(self, rule_id, tree=None):
        path = self.baseline_path(rule_id)
        tree = tree or self.tree
        return core.Baseline.parse(path, BASELINE_COLUMNS[rule_id], tree.read(path) if path else None)

    def allowed(self, baseline, key):
        """基线按文件现在的路径查。改名不自动沿用旧路径的额度：改名要同时运行 --update-baseline 让基线跟着改名，
        否则合并之后 --all 会把它当成新文件。"""
        return baseline.entries.get(key)

    def rename_hint(self, baseline, key):
        mapped = core.remap_key(baseline, key, self.renames)
        if mapped != key and mapped in baseline.entries:
            return "（它是从 %s 改名来的：运行 `python3 -I scripts/gate/gate.py --update-baseline` 让基线跟着改名）" % baseline.key_path(mapped)
        return ""

    def note_tighten(self, rule_id, baseline, current):
        """基线里、这次查过的文件中，现在比基线少的项（--all 时还包括文件已经不在的项）。"""
        checked = set(self.swift_files())
        for key, allowed in sorted(baseline.entries.items()):
            path = baseline.key_path(key)
            now = current.get(key, 0)
            if path in checked and now < allowed:
                self.tighten.append((rule_id, key, allowed, now))
            elif self.mode == "all" and path is not None and not self.tree.exists(path):
                self.tighten.append((rule_id, key, allowed, 0))

    def finding(self, rule_id, path, line, message, fix, subject=None):
        return Finding(rule_id, self.config.severity(rule_id), path, line, message, fix, subject)


def line_count(text):
    if not text:
        return 0
    return text.count("\n") + (0 if text.endswith("\n") else 1)


def thousands(number):
    return "{:,}".format(number)


# ---------------------------------------------------------------------------
# 1. 文件行数

@rule("file-size", "Swift 文件不超过上限行数；已经超过的记在基线里，只许变少", "file")
def check_file_size(ctx):
    spec = ctx.config.rule("file-size")
    limit = int(spec.get("max_lines", 1000))
    baseline = ctx.baseline("file-size")
    current = {}
    findings = []
    for path in ctx.swift_files():
        lines = line_count(ctx.tree.read(path))
        if lines > limit:
            current[(path,)] = lines
        allowed = ctx.allowed(baseline, (path,))
        if allowed is None:
            if lines > limit:
                findings.append(ctx.finding(
                    "file-size", path, limit + 1,
                    "文件 %s 行，不在基线里，超过 %s 行的上限%s" % (thousands(lines), thousands(limit),
                                                          ctx.rename_hint(baseline, (path,))),
                    "按职责拆成几个文件：每个类型家族各自成文件，大类型的扩展按职责分到 `类型+职责.swift`"))
        elif lines > allowed:
            findings.append(ctx.finding(
                "file-size", path, allowed + 1,
                "文件 %s 行，基线 %s 行，大文件只许变短" % (thousands(lines), thousands(allowed)),
                "新增的代码放进新的文件（同类型的扩展按职责另起 `类型+职责.swift`），或者先从这个文件拆出一部分"))
    ctx.counts["file-size"] = current
    ctx.note_tighten("file-size", baseline, current)
    return findings


# ---------------------------------------------------------------------------
# 2. @Observable 类体

KIND_NAMES = {
    "function": "方法", "static function": "静态方法", "computed property": "计算属性",
    "static computed property": "静态计算属性", "static stored property": "静态存储属性",
    "lazy static stored property": "静态存储属性", "static stored property (observed)": "静态存储属性",
    "subscript": "下标", "convenience initializer": "便利初始化方法", "typealias": "类型别名",
    "nested struct": "嵌套类型", "nested enum": "嵌套类型", "nested class": "嵌套类型",
    "nested actor": "嵌套类型", "nested protocol": "嵌套类型", "#if region": "#if 块",
}


def describe_members(members, limit=6):
    parts = []
    for member in members[:limit]:
        name = member.name if member.kind != "#if region" else ""
        parts.append("%s %s（第 %d 行）" % (KIND_NAMES.get(member.kind, member.kind), name, member.decl_line)
                     if name else "%s（第 %d 行）" % (KIND_NAMES.get(member.kind, member.kind), member.decl_line))
    if len(members) > limit:
        parts.append("……共 %d 个" % len(members))
    return "、".join(parts)


OBSERVABLE_FIX = ("把这些成员原样移到紧随类之后的同文件 `extension 类名 { }` 里（`#if` 里的成员连同 `#if` 一起移）；"
                  "类体只留实例存储属性、指定初始化方法和 deinit，override 和 required init 这类不能进扩展的除外")


@rule("observable-class-body", "@Observable 类的类体只放实例存储属性、指定初始化方法和 deinit", "file")
def check_observable(ctx):
    baseline = ctx.baseline("observable-class-body")
    current = {}
    findings = []
    for path in ctx.swift_files():
        text = ctx.tree.read(path)
        if "Observable" not in text:
            continue
        seen = {}
        for report in swiftscan.observable_classes(text):
            name = report.decl.qualified
            seen[name] = seen.get(name, 0) + 1
            if seen[name] > 1:
                name = "%s#%d" % (name, seen[name])
            key = (path, name)
            count = len(report.offending)
            if count:
                current[key] = count
            allowed = ctx.allowed(baseline, key)
            if count == 0:
                continue
            if allowed is None:
                findings.append(ctx.finding(
                    "observable-class-body", path, report.offending[0].decl_line,
                    "可观察类 %s 的类体里有 %d 个该放进扩展的成员：%s%s" % (name, count, describe_members(report.offending),
                                                                ctx.rename_hint(baseline, key)),
                    OBSERVABLE_FIX))
            elif count > allowed:
                findings.append(ctx.finding(
                    "observable-class-body", path, report.decl.decl_line,
                    "可观察类 %s 的类体里该放进扩展的成员从基线 %d 个变成 %d 个：%s"
                    % (name, allowed, count, describe_members(report.offending)),
                    OBSERVABLE_FIX))
    ctx.counts["observable-class-body"] = current
    ctx.note_tighten("observable-class-body", baseline, current)
    return findings


# ---------------------------------------------------------------------------
# 3. 大曲库内存纪律（scripts/check-crash-patterns.py，原样调用）

_MODULES = {}


def load_module(path, name):
    key = (path, name)
    if key not in _MODULES:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        with contextlib.redirect_stdout(io.StringIO()):
            spec.loader.exec_module(module)
        _MODULES[key] = module
    return _MODULES[key]


def crash_module(ctx):
    spec = ctx.config.rule("library-scale")
    path = ctx.config.tool_path(spec.get("script", "scripts/check-crash-patterns.py"))
    if not os.path.isfile(path):
        raise Skip("找不到 %s" % os.path.relpath(path, ctx.config.tool_root))
    module = load_module(path, "gate_crash_patterns")
    for attribute in ("scan_text", "RULES", "RATCHET_RULES"):
        if not hasattr(module, attribute):
            raise Skip("%s 没有 %s，接口变了，关卡要跟着改" % (os.path.basename(path), attribute))
    return module


def library_scale_files(ctx, module):
    skip = tuple(getattr(module, "SKIP_PREFIXES", ()))
    changed = ctx.changed_paths()
    candidates = ctx.tree.paths() if changed is None else sorted(p for p in changed if ctx.tree.exists(p))
    return [p for p in candidates if p.endswith(".swift") and not p.startswith(skip) and not ctx.tree.is_symlink(p)]


class _Hit:
    __slots__ = ("rule", "path", "line", "text")

    def __init__(self, rule, path, line, text):
        self.rule, self.path, self.line, self.text = rule, path, line, text


def _crash_scan_chunk(job):
    """子进程里扫一批文件（--all 时文件多，分给几个进程）。"""
    module_path, items = job
    module = load_module(module_path, "gate_crash_patterns")
    hits = []
    for path, text in items:
        for item in module.scan_text(path, text):
            hits.append((item.rule, item.path, item.line, item.text))
    return hits


def scan_library_scale(ctx, module, paths):
    items = [(path, ctx.tree.read(path)) for path in paths]
    items = [(path, text) for path, text in items if text is not None]
    workers = min(os.cpu_count() or 1, 8)
    if len(items) >= 300 and workers > 1:
        try:
            import concurrent.futures
            chunks = [items[i::workers * 4] for i in range(workers * 4)]
            jobs = [(module.__file__, chunk) for chunk in chunks if chunk]
            with concurrent.futures.ProcessPoolExecutor(max_workers=workers) as pool:
                hits = [hit for result in pool.map(_crash_scan_chunk, jobs) for hit in result]
            hits.sort(key=lambda hit: (hit[1], hit[2], hit[0]))
            return [_Hit(*hit) for hit in hits]
        except Exception:  # 进程池起不来（受限的环境）时退回单进程
            pass
    findings = []
    for path, text in items:
        findings.extend(module.scan_text(path, text))
    return findings


@rule("library-scale", "线上闪退写法与大曲库内存纪律（scripts/check-crash-patterns.py 的规则与棘轮基线）", "file")
def check_library_scale(ctx):
    module = crash_module(ctx)
    paths = library_scale_files(ctx, module)
    raw = scan_library_scale(ctx, module, paths)
    baseline = ctx.baseline("library-scale")
    counts = {}
    for item in raw:
        if item.rule in module.RATCHET_RULES:
            key = (item.rule, item.path)
            counts[key] = counts.get(key, 0) + 1
    over = {key for key, count in counts.items() if count > (ctx.allowed(baseline, key) or 0)}
    findings = []
    for item in raw:
        summary, incident, _ = module.RULES[item.rule]
        if item.rule in module.RATCHET_RULES:
            key = (item.rule, item.path)
            if key not in over:
                continue
            message = "%s：这个文件基线 %d 处、现在 %d 处：%s" % (
                item.rule, ctx.allowed(baseline, key) or 0, counts[key], item.text[:140])
        else:
            message = "%s：%s" % (item.rule, item.text[:140])
        findings.append(ctx.finding("library-scale", item.path, item.line, message,
                                    "%s（来源：%s）" % (summary, incident), subject=item.rule))
    ctx.counts["library-scale"] = counts
    checked = set(paths)
    for key, allowed in sorted(baseline.entries.items()):
        now = counts.get(key, 0)
        if key[1] in checked and now < allowed:
            ctx.tighten.append(("library-scale", key, allowed, now))
        elif ctx.mode == "all" and not ctx.tree.exists(key[1]):
            ctx.tighten.append(("library-scale", key, allowed, 0))
    return findings


# ---------------------------------------------------------------------------
# 4. 核心包目录

@rule("kit-layout", "核心包的源文件和测试按领域分目录，测试目录与源目录镜像", "file")
def check_kit_layout(ctx):
    spec = ctx.config.rule("kit-layout")
    source_root = spec["source_root"].rstrip("/")
    test_root = spec["test_root"].rstrip("/")
    allowed_root = set(spec.get("allowed_root_files", []))
    free_dirs = set(spec.get("test_dirs_without_source", []))
    findings = []
    for path in ctx.swift_files():
        directory = os.path.dirname(path)
        if directory in (source_root, test_root) and path not in allowed_root:
            findings.append(ctx.finding(
                "kit-layout", path, None, "文件直接放在 %s/ 下，没有进领域子目录" % directory,
                "移到对应领域的子目录（看看同类文件在哪个目录）；确实属于根目录的写进 gate.config.json 的 allowed_root_files"))
            continue
        if path.startswith(test_root + "/"):
            relative = os.path.dirname(path[len(test_root) + 1:])
            if relative and relative.split("/")[0] not in free_dirs and not ctx.tree.is_dir(source_root + "/" + relative):
                findings.append(ctx.finding(
                    "kit-layout", path, None,
                    "测试目录 %s 在源码里没有对应的 %s/%s" % (relative, source_root, relative),
                    "测试放到与被测源文件同名的领域目录里（%s/<领域>/），共用的测试辅助放 %s"
                    % (test_root, "、".join(sorted(free_dirs)) or "Support")))
    return findings


# ---------------------------------------------------------------------------
# 5. 分层

@rule("layering", "核心包不导入界面框架（SwiftUI、UIKit、AppKit……）", "file")
def check_layering(ctx):
    spec = ctx.config.rule("layering")
    roots = tuple(spec.get("roots", []))
    forbidden = set(spec.get("forbidden_imports", []))
    baseline = ctx.baseline("layering")
    current = {}
    findings = []
    for path in ctx.swift_files():
        if not path.startswith(roots):
            continue
        text = ctx.tree.read(path)
        if "import" not in text:
            continue
        hits = swiftscan.imports(text, forbidden)
        if hits:
            current[(path,)] = len(hits)
        allowed = ctx.allowed(baseline, (path,)) or 0
        if len(hits) > allowed:
            for line, name in hits:
                findings.append(ctx.finding(
                    "layering", path, line, "核心包导入了界面框架 %s（基线 %d 处）" % (name, allowed),
                    "核心包只放能脱离界面测试的逻辑：把用到 %s 的部分留在 App 模块，核心包里用平台无关的类型（CGFloat、数据、协议）" % name))
    ctx.counts["layering"] = current
    ctx.note_tighten("layering", baseline, current)
    return findings


# ---------------------------------------------------------------------------
# 6. 工程文件

FOLDER_LIKE = (".xcassets", ".framework", ".bundle", ".xcdatamodeld", ".playground", ".lproj", ".docc",
               ".xcframework", ".icon", ".appiconset")


def pbx_module(ctx):
    spec = ctx.config.rule("project-file")
    path = ctx.config.tool_path(spec.get("script", "scripts/check-pbxproj.py"))
    if not os.path.isfile(path):
        raise Skip("找不到 %s" % os.path.relpath(path, ctx.config.tool_root))
    return load_module(path, "gate_check_pbxproj")


def pbx_targets(objects, root_object):
    project = objects[root_object]
    paths = {}
    stack = [(project["mainGroup"], "")]
    while stack:
        identifier, parent = stack.pop()
        group = objects.get(identifier, {})
        tree, path = group.get("sourceTree"), group.get("path")
        if tree == "<group>":
            base = parent if not path else (parent + "/" + path if parent else path)
        elif tree == "SOURCE_ROOT":
            base = path or ""
        else:
            continue
        paths[identifier] = base
        for child in group.get("children", []) or []:
            stack.append((child, base))
    targets = {}
    for identifier in project.get("targets", []):
        target = objects[identifier]
        members = set()
        for phase_id in target.get("buildPhases", []) or []:
            phase = objects.get(phase_id, {})
            if phase.get("isa") != "PBXSourcesBuildPhase":
                continue
            for build_file in phase.get("files", []) or []:
                reference = objects.get(build_file, {}).get("fileRef")
                if reference in paths:
                    members.add(paths[reference])
        targets[target.get("name")] = members
    return targets


def expected_sources(tree, spec_targets, extensions):
    expected, declared_files = {}, []
    swift = [p for p in tree.paths() if p.endswith(extensions) and not tree.is_symlink(p)]
    for name, target in (spec_targets or {}).items():
        files = set()
        for source in (target or {}).get("sources", []) or []:
            if isinstance(source, str):
                source = {"path": source}
            if not isinstance(source, dict) or "path" not in source:
                continue
            if source.get("type") == "folder" or source.get("buildPhase") not in (None, "sources"):
                continue
            path = str(source["path"]).rstrip("/")
            if tree.is_dir(path):
                excludes = source.get("excludes") or []
                includes = source.get("includes") or []
                for candidate in swift:
                    if not candidate.startswith(path + "/"):
                        continue
                    relative = candidate[len(path) + 1:]
                    if any(part.endswith(FOLDER_LIKE) for part in relative.split("/")[:-1]):
                        continue
                    if excludes and core.matches_self_or_ancestor(relative, excludes):
                        continue
                    if includes and not core.matches_self_or_ancestor(relative, includes):
                        continue
                    files.add(candidate)
            elif path.endswith(extensions):
                if tree.exists(path):
                    files.add(path)
                elif not source.get("optional"):
                    declared_files.append((name, path))
        expected[name] = files
    return expected, declared_files


PROJECT_FIX = "在构建机上用 XcodeGen 重新生成：`xcodegen generate --spec project.yml`（版本见 gate.config.json），不要手改 project.pbxproj"


@rule("project-file", "project.pbxproj 是有效的属性表，并且与 project.yml 按目录给各目标的 Swift 文件一一对应", "tree")
def check_project_file(ctx):
    spec = ctx.config.rule("project-file")
    project_path = spec.get("project")
    spec_path = spec.get("spec", "project.yml")
    if not project_path:
        raise Skip("gate.config.json 的 project-file 没有写 project（project.pbxproj 的路径）")
    if ctx.mode == "staged" and not (ctx.touched([project_path, spec_path]) or any(
            c.status in "ADRC" and c.path.endswith(".swift") for c in ctx.changes)):
        raise NotApplicable()
    module = pbx_module(ctx)
    text = ctx.tree.read(project_path)
    if text is None:
        raise Skip("树里没有 %s" % project_path)
    findings = []
    version = spec.get("xcodegen_version", "")
    fix = PROJECT_FIX.replace("（版本见 gate.config.json）", "（XcodeGen %s）" % version if version else "")
    # 原样跑 check-pbxproj.py：它只认磁盘上的路径。
    with tempfile.TemporaryDirectory(prefix="gate-pbx-") as directory:
        if ctx.tree.disk_root:
            disk_path = os.path.join(ctx.tree.disk_root, project_path)
        else:
            disk_path = os.path.join(directory, "project.pbxproj")
            with open(disk_path, "w", encoding="utf-8") as handle:
                handle.write(text)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = module.main(disk_path)
    if status != 0:
        findings.append(ctx.finding("project-file", project_path, None,
                                    "check-pbxproj.py：" + output.getvalue().strip().replace(disk_path, project_path),
                                    "Xcode 会因此拒绝整个工程；" + fix))
        return findings
    parser = module.Parser(text)
    if text.startswith("// !$*UTF8*$!"):
        parser.pos = text.index("\n") + 1
    root = parser.parse_value()
    targets = pbx_targets(root["objects"], root["rootObject"])
    spec_text = ctx.tree.read(spec_path)
    if spec_text is None:
        raise Skip("树里没有 %s" % spec_path)
    try:
        project_spec = formats.parse_yaml(spec_text)
    except formats.FormatError as error:
        findings.append(ctx.finding("project-file", spec_path, None, "读不懂 project.yml：%s" % error,
                                    "检查缩进与引号；关卡只认块式 YAML、引号、流式列表和块标量"))
        return findings
    extensions = tuple(spec.get("source_extensions", [".swift"]))
    expected, missing_declared = expected_sources(ctx.tree, project_spec.get("targets"), extensions)
    for target, path in missing_declared:
        findings.append(ctx.finding("project-file", spec_path, None,
                                    "project.yml 给目标 %s 列了不存在的文件 %s" % (target, path),
                                    "从 project.yml 删掉这一项或者恢复文件，然后" + fix))
    for target, files in sorted(expected.items()):
        actual = {p for p in targets.get(target, set()) if p.endswith(extensions)}
        if target not in targets:
            findings.append(ctx.finding("project-file", project_path, None,
                                        "project.yml 里的目标 %s 在 project.pbxproj 里没有" % target, fix))
            continue
        for path in sorted(files - actual):
            findings.append(ctx.finding("project-file", path, None,
                                        "project.yml 把这个文件给了目标 %s，project.pbxproj 里却没有登记" % target, fix))
        for path in sorted(actual - files):
            reason = "文件已经不在了" if not ctx.tree.exists(path) else "project.yml 没有把它给这个目标"
            findings.append(ctx.finding("project-file", path, None,
                                        "project.pbxproj 让目标 %s 编这个文件，但%s" % (target, reason), fix))
    return findings


# ---------------------------------------------------------------------------
# 7. 本地化

@rule("localization", "各语言的 .strings 键一致、占位符一致、没有空译文", "tree")
def check_localization(ctx):
    spec = ctx.config.rule("localization")
    groups = spec.get("groups", [])
    if ctx.mode != "all" and not ctx.touched(["**/*.strings"] + [g["dir"] + "/**" for g in groups]):
        raise NotApplicable()
    locales = spec["locales"]
    development = spec.get("development_locale", "en")
    han_locales = set(spec.get("han_locales", []))
    findings = []
    for group in groups:
        name, directory, file_name = group["name"], group["dir"].rstrip("/"), group["file"]
        exact = group.get("exact_development_parity", True)
        paths = {locale: "%s/%s.lproj/%s" % (directory, locale, file_name) for locale in locales}
        missing = [locale for locale, path in paths.items() if not ctx.tree.exists(path)]
        if missing:
            findings.append(ctx.finding("localization", "%s/*.lproj/%s" % (directory, file_name), None,
                                        "%s 缺少这些语言的文件：%s" % (name, "、".join(missing)),
                                        "每种语言都要有同名的 .strings 文件（%d 种语言）" % len(locales)))
            continue
        values = {}
        broken = False
        for locale, path in paths.items():
            text = ctx.tree.read(path)
            try:
                values[locale] = formats.parse_strings(text)
            except formats.FormatError as error:
                findings.append(ctx.finding("localization", path, None, "%s %s 读不懂：%s" % (name, locale, error),
                                            "修好引号、= 和 ;（每行 \"键\" = \"值\";）"))
                broken = True
                continue
            for key, lines in sorted(formats.duplicate_string_keys(text).items()):
                findings.append(ctx.finding("localization", path, lines[1],
                                            "%s %s 重复的键 \"%s\"（第 %s 行）" % (name, locale, key, "、".join(map(str, lines))),
                                            "删掉多余的一行，只留一个译文"))
        if broken:
            continue
        union = set()
        for dictionary in values.values():
            union |= set(dictionary)
        for locale, dictionary in values.items():
            path = paths[locale]
            for key, value in dictionary.items():
                if not formats.ruby_strip(value):
                    findings.append(ctx.finding("localization", path, None, "%s %s \"%s\" 的译文是空的" % (name, locale, key),
                                                "补上这种语言的译文"))
                if locale not in han_locales and formats.HAN_RE.search(value):
                    findings.append(ctx.finding("localization", path, None,
                                                "%s %s \"%s\" 里有汉字" % (name, locale, key),
                                                "这种语言的译文不应出现中文，换成该语言的说法"))
            if locale == development and not exact:
                continue
            absent = sorted(union - set(dictionary))
            if absent:
                findings.append(ctx.finding("localization", path, None,
                                            "%s %s 缺少 %d 个键：%s" % (name, locale, len(absent), ", ".join(absent[:12])
                                                                     + ("……" if len(absent) > 12 else "")),
                                            "每个键在 %d 种语言里都要有译文" % len(locales)))
        english = values[development]
        for locale, dictionary in values.items():
            if locale == development:
                continue
            for key, value in dictionary.items():
                if key not in english:
                    continue
                expected, actual = formats.format_signature(english[key]), formats.format_signature(value)
                if expected != actual:
                    findings.append(ctx.finding("localization", paths[locale], None,
                                                "%s %s \"%s\" 的占位符和 %s 不同：应为 %s，实际 %s"
                                                % (name, locale, key, development, expected, actual),
                                                "占位符的个数和类型要与 %s 一致（顺序可以用 %%1$@ 这种写法调换）" % development))
    return findings


# ---------------------------------------------------------------------------
# 基线只许收紧

@rule("baseline-integrity", "基线文件只许变小；放宽要仓库所有者用 --update-baseline --allow-growth 写明理由", "tree")
def check_baseline_integrity(ctx):
    if ctx.base_tree is None:
        return []
    findings = []
    for rule_id in BASELINE_COLUMNS:
        if not ctx.config.enabled(rule_id):
            continue
        path = ctx.baseline_path(rule_id)
        if not path:
            continue
        old_text = ctx.base_tree.read(path)
        if old_text is None:
            continue
        new = ctx.baseline(rule_id)
        old = core.Baseline.parse(path, BASELINE_COLUMNS[rule_id], old_text)
        grew = core.compare_baselines(old, new, ctx.renames)
        if not grew:
            continue
        added_notes = [note for note in new.notes if note not in old.notes]
        detail = "；".join("%s %d → %d" % ("/".join(key), before, after) for key, before, after in grew[:8])
        if len(grew) > 8:
            detail += "……共 %d 项" % len(grew)
        if added_notes and not ctx.strict_baselines:
            findings.append(Finding("baseline-integrity", "warn", path, None,
                                    "基线放宽了（%s），理由：%s" % (detail, added_notes[-1][len(core.GROWTH_NOTE_PREFIX):].strip()),
                                    "确认这是仓库所有者的决定；之后尽快把代码改回基线以内再收紧"))
        else:
            findings.append(ctx.finding("baseline-integrity", path, None, "基线变大了：%s" % detail,
                                        "修代码而不是改基线；基线只许用 --update-baseline 收紧。确需放宽由仓库所有者在 main 上运行 "
                                        "`--update-baseline --allow-growth \"理由\"`" + ("（拉取请求里一律不许放宽）" if ctx.strict_baselines else "")))
    return findings


# ---------------------------------------------------------------------------
# 外部脚本

def _available(requirement):
    if requirement.startswith("/"):
        return os.path.exists(requirement) and os.access(requirement, os.X_OK)
    return shutil.which(requirement) is not None


@contextlib.contextmanager
def _overlay(disk_root, tool_root):
    """外部脚本按自己所在位置找仓库根。关卡代码与被检查的树不在一处时（CI 里关卡来自基准分支），
    在临时目录里拼一棵树：scripts/ 是真目录，放关卡那份的脚本副本（Ruby 的 __dir__ 会解开符号链接，
    所以脚本本身不能是链接），其余顶层条目链接到被检查的树。"""
    if os.path.realpath(disk_root) == os.path.realpath(tool_root):
        yield disk_root
        return
    directory = tempfile.mkdtemp(prefix="gate-overlay-")
    try:
        for name in os.listdir(disk_root):
            if name in ("scripts", ".git"):
                continue
            os.symlink(os.path.join(disk_root, name), os.path.join(directory, name))
        scripts = os.path.join(directory, "scripts")
        os.mkdir(scripts)
        source = os.path.join(tool_root, "scripts")
        for name in os.listdir(source):
            if os.path.isfile(os.path.join(source, name)):
                shutil.copy2(os.path.join(source, name), os.path.join(scripts, name))
        yield directory
    finally:
        shutil.rmtree(directory, ignore_errors=True)


def run_external(ctx, rule_id):
    spec = ctx.config.rule(rule_id)
    if ctx.mode == "range" and not ctx.touched(spec.get("triggers", ["**"])):
        raise NotApplicable()
    missing = [r for r in spec.get("requires", []) if not _available(r)]
    if missing:
        raise Skip("缺少 %s" % "、".join(missing))
    if spec.get("probe"):
        try:
            probe = subprocess.run(spec["probe"], capture_output=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            probe = None
        if probe is None or probe.returncode != 0:
            raise Skip(spec.get("probe_reason", "环境检查没通过：%s" % " ".join(spec["probe"])))
    if not ctx.tree.disk_root:
        raise Skip("被检查的提交不是当前检出的内容（工作区有改动或推送的不是 HEAD），没有磁盘上的树可查")
    absent = [p for p in spec.get("inputs", []) if not (ctx.tree.exists(p) or ctx.tree.is_dir(p))]
    if absent:
        raise Skip("缺少输入 %s" % "、".join(absent))
    script = ctx.config.tool_path(spec["script"])
    if not os.path.isfile(script):
        raise Skip("找不到 %s" % spec["script"])
    with _overlay(ctx.tree.disk_root, ctx.config.tool_root) as root:
        command = [part.replace("{script}", os.path.join(root, spec["script"])) for part in spec["command"]]
        try:
            result = subprocess.run(command, cwd=root, capture_output=True, timeout=spec.get("timeout", 600))
        except subprocess.TimeoutExpired:
            return [ctx.finding(rule_id, spec["script"], None, "运行超过 %d 秒" % spec.get("timeout", 600),
                                "在本机单独运行看卡在哪：%s" % " ".join(spec["command"]).replace("{script}", spec["script"]))]
    if result.returncode == 0:
        return []
    output = (result.stdout + result.stderr).decode("utf-8", "replace").strip().split("\n")
    tail = "\n".join(output[-25:])
    return [ctx.finding(rule_id, spec["script"], None, "%s 没通过：\n%s" % (spec["script"], tail),
                        spec.get("fix", "按脚本的提示修；单独运行：%s" % " ".join(spec["command"]).replace("{script}", spec["script"])))]


def _external_rule(rule_id, title):
    @rule(rule_id, title, "external", modes=("all", "range"))
    def check(ctx):
        return run_external(ctx, rule_id)
    return check


_external_rule("toolbar-environment", "工具栏里的视图不读必需的 @Environment 对象（scripts/check-toolbar-environment.rb）")
_external_rule("widget-platforms", "小组件平台、App Intents 与重新生成的工程逐字节一致（scripts/check-widget-platforms.rb，需要构建机）")
_external_rule("branding", "品牌名与备用名称（scripts/check-branding.sh，需要 PlistBuddy）")
_external_rule("localization-full", "完整的本地化检查（scripts/check-localizations.rb，需要 plutil）")
