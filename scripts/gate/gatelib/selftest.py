"""--self-test：每条规则一组正反样例，在内存里的树上跑，不碰仓库。"""
import copy
import io
import os

from . import commits, core, formats, rules, swiftscan

APP = "App/"
KIT_SRC = "Kit/Sources/Kit"
KIT_TEST = "Kit/Tests/KitTests"


def sample_config(real):
    """以真实配置为底，把路径换成样例树里的。"""
    config = copy.copy(real)
    data = copy.deepcopy(real.data)
    data["swift"]["exclude"] = ["Vendor/**"]
    data["test_prefixes"] = ["AppTests/", "Kit/Tests/"]
    r = data["rules"]
    r["file-size"].update({"severity_new_file": "error", "severity_growth": "warn", "max_lines": 5,
                           "baseline": "gate/file-size.tsv"})
    r["file-size"].pop("severity", None)
    r["observable-class-body"]["baseline"] = "gate/observable.tsv"
    r["library-scale"]["baseline"] = "gate/library-scale.tsv"
    r["layering"].update({"roots": [KIT_SRC + "/"], "baseline": "gate/layering.tsv"})
    r["kit-layout"].update({"source_root": KIT_SRC, "test_root": KIT_TEST,
                            "allowed_root_files": [KIT_SRC + "/Constants.swift"], "test_dirs_without_source": ["Support"]})
    r["project-file"].update({"spec": "project.yml", "project": "App.xcodeproj/project.pbxproj"})
    r["localization"].update({"locales": ["en", "de", "ja"], "han_locales": ["ja"], "baseline": "gate/localization.tsv",
                              "groups": [{"name": "Sample", "dir": "Res", "file": "Localizable.strings"}]})
    config.data = data
    return config


class Runner:
    def __init__(self, config, out):
        self.config = config
        self.out = out
        self.counts = {}
        self.failures = 0

    def check(self, rule_id, label, ok, detail=""):
        self.counts.setdefault(rule_id, [0, 0])
        self.counts[rule_id][0] += 1
        if not ok:
            self.counts[rule_id][1] += 1
            self.failures += 1
            self.out.write("自检失败 [%s] %s %s\n" % (rule_id, label, detail))

    def run_rule(self, rule_id, files, base=None, mode="all", changes=None, strict=False):
        tree = core.DictTree(files)
        base_tree = core.DictTree(base) if base is not None else None
        ctx = rules.Context(self.config, tree, mode, changes, base_tree, strict)
        findings = rules.rule_info(rule_id).function(ctx)
        return findings, ctx

    def expect(self, rule_id, label, files, count, base=None, contains=None, severity=None, **kwargs):
        findings, ctx = self.run_rule(rule_id, files, base, **kwargs)
        ok = len(findings) == count
        if ok and contains:
            ok = any(contains in f.message for f in findings)
        if ok and severity:
            ok = all(f.severity == severity for f in findings)
        self.check(rule_id, label, ok, "：期望 %d 处，得到 %d 处 %s" % (count, len(findings),
                                                                    [f.message[:80] for f in findings][:3]))
        return ctx


def lines(n):
    return "".join("let v%d = %d\n" % (i, i) for i in range(n))


# ---------------------------------------------------------------------------

def test_file_size(t):
    base = {"gate/file-size.tsv": "# h\nApp/Big.swift\t8\n"}
    t.expect("file-size", "新文件超过上限（按 severity_new_file 报错误）", dict(base, **{"App/New.swift": lines(6)}), 1,
             contains="不在基线里", severity="error")
    t.expect("file-size", "新文件刚好在上限", dict(base, **{"App/New.swift": lines(5)}), 0)
    t.expect("file-size", "基线里的文件变长（按 severity_growth 报警告）", dict(base, **{"App/Big.swift": lines(9)}), 1,
             contains="基线 8 行", severity="warn")
    ctx = t.expect("file-size", "基线里的文件变短", dict(base, **{"App/Big.swift": lines(7)}), 0)
    t.check("file-size", "变短后提示收紧", any(item[0] == "file-size" and item[3] == 7 for item in ctx.tighten))
    t.expect("file-size", "排除的目录不查", dict(base, **{"Vendor/Lib.swift": lines(50)}), 0)
    t.expect("file-size", "生成的文件不查", dict(base, **{"App/Gen.swift": "// DO NOT EDIT\n" + lines(50)}), 0)
    t.expect("file-size", "改名的大文件提示跟着改基线", dict(base, **{"App/Moved.swift": lines(8)}), 1, contains="改名",
             mode="range", changes=[core.Change("R", "App/Moved.swift", "App/Big.swift")])


OBSERVABLE_OK = '''import Observation

@Observable
@MainActor
final class Good: Base {
    /// 文档注释
    var count = 0
    @ObservationIgnored private var cache: [String: Int] = [:]
    let label: String = "{ not a brace }"
    var observed = 0 { didSet { print("changed") } }
    private(set) var items: [Int] = [
        1,
        2,
    ]
    var handler: () -> Void = { print("closure {") }
    @ObservationIgnored var lazyText: String { "ignored computed stays" }
    #if os(iOS)
    var phoneOnly = true
    #endif

    init(label: String) { self.label2 = label }
    required init() {}
    override func update() {}
    deinit {}
}

extension Good {
    var doubled: Int { count * 2 }
    func reset() { count = 0 }
}
'''

OBSERVABLE_BAD = '''@Observable
final class Bad {
    var count = 0
    var doubled: Int { count * 2 }
    func reset() { count = 0 }
    static let shared = Bad()
    struct Nested {}
    typealias ID = String
    convenience init(x: Int) { self.init() }
    subscript(i: Int) -> Int { i }
    #if os(macOS)
    var macOnly = 1
    func macHelper() {}
    #endif
}
'''


def test_observable(t):
    t.expect("observable-class-body", "只有存储属性、初始化方法和 deinit", {"App/Good.swift": OBSERVABLE_OK}, 0)
    t.expect("observable-class-body", "方法、计算属性、静态属性、嵌套类型都在类体里", {"App/Bad.swift": OBSERVABLE_BAD}, 1,
             contains="8 个")
    base = {"gate/observable.tsv": "# h\nApp/Bad.swift\tBad\t8\n"}
    t.expect("observable-class-body", "基线内", dict(base, **{"App/Bad.swift": OBSERVABLE_BAD}), 0)
    grown = OBSERVABLE_BAD.replace("    var count = 0\n", "    var count = 0\n    func more() {}\n")
    t.expect("observable-class-body", "比基线多", dict(base, **{"App/Bad.swift": grown}), 1, contains="从基线 8 个变成 9 个")
    nested = '''struct Screen {
    @Observable final class Model {
        var value = 0
        func load() {}
    }
}
func make() {
    @Observable class Local { var x = 0; func f() {} }
}
'''
    found, _ = t.run_rule("observable-class-body", {"App/Nested.swift": nested})
    t.check("observable-class-body", "嵌套类与函数里的类都找到", len(found) == 2 and "Screen.Model" in found[0].message,
            str([f.message[:60] for f in found]))
    tricky = '''@Observable final class Tricky {
    var a = "unterminated? no: \\(value) } {"
    var b = #"raw \\(not interpolation) { "#
    var c = """
        multi } line {
        """
    /* block /* nested */ { */
    var d = 1 // { trailing
    var e = /\\}+/
    class var shared: Int { 1 }
}
'''
    found, _ = t.run_rule("observable-class-body", {"App/Tricky.swift": tricky})
    t.check("observable-class-body", "字符串、注释、正则里的括号不干扰", len(found) == 1 and "1 个" in found[0].message,
            str([f.message[:80] for f in found]))
    # 与 SwiftSyntax 工具相同的计数口径：#if 块的声明数是块里成员之和，共用一行的可移动成员留在类体。
    source = swiftscan.SwiftSource(OBSERVABLE_BAD)
    report = swiftscan.analyze_class(source, [d for d in swiftscan.find_types(source) if d.name == "Bad"][0])
    t.check("observable-class-body", "类体声明计数与 SwiftSyntax 口径一致",
            (report.body_decls, report.stay_decls, report.move_decls) == (10, 3, 7),
            str((report.body_decls, report.stay_decls, report.move_decls)))
    t.check("observable-class-body", "#if 块里与存储属性混在一起的方法也算该移走", len(report.offending) == 8 and any(
        m.name == "macHelper" for m in report.offending), str([m.name for m in report.offending]))


def test_library_scale(t):
    """仓库自己的闪退扫描脚本能接上；脚本里有大曲库规则（Primuse）时再用样例查棘轮、豁免和测试目录。"""
    module = rules.crash_module(rules.Context(t.config, core.DictTree({}), "all"))
    t.expect("library-scale", "仓库的扫描脚本能接上，干净的文件没有命中",
             {"App/Clean.swift": "import Foundation\nlet value = 1\n"}, 0)
    if "library-array-property" not in module.RULES:
        return
    spec = t.config.data["rules"]["library-scale"]
    saved = spec.pop("ratchet", None)
    try:
        product = "import Foundation\nfinal class Store {\n    var songs: [Song] = []\n}\n"
        t.expect("library-scale", "整库歌曲数组属性（基线外）", {"App/Store.swift": product}, 1,
                 contains="library-array-property")
        base = {"gate/library-scale.tsv": "# h\nlibrary-array-property\tApp/Store.swift\t1\n"}
        t.expect("library-scale", "基线内", dict(base, **{"App/Store.swift": product}), 0)
        allowed = product.replace("[Song] = []", "[Song] = []  // crash-pattern: allow library-array-property 最多 50 首")
        t.expect("library-scale", "写明上界的豁免", {"App/Store.swift": allowed}, 0)
        t.expect("library-scale", "测试目录不查棘轮规则（按 check-crash-patterns.py 自己的测试目录）",
                 {"PrimuseTests/StoreTests.swift": product}, 0)
    finally:
        if saved is not None:
            spec["ratchet"] = saved


FAKE_CRASH_CHECKER = """RULES = {"no-force-try": ("不要用 try!", "样例", None)}


class Hit:
    def __init__(self, rule, path, line, text):
        self.rule, self.path, self.line, self.text = rule, path, line, text


def scan_text(path, text):
    return [Hit("no-force-try", path, number, line) for number, line in enumerate(text.split("\\n"), 1) if "try!" in line]
"""


def test_library_scale_generic(t):
    """别的仓库的闪退扫描脚本：没有 RATCHET_RULES 时照样能接；"ratchet": "all" 时现有命中按基线执行。"""
    import shutil
    import tempfile
    directory = tempfile.mkdtemp(prefix="gate-selftest-crash-")
    saved_root, saved_spec = t.config.tool_root, dict(t.config.data["rules"]["library-scale"])
    try:
        os.makedirs(os.path.join(directory, "scripts"))
        with open(os.path.join(directory, "scripts", "fake-crash.py"), "w", encoding="utf-8") as handle:
            handle.write(FAKE_CRASH_CHECKER)
        t.config.tool_root = directory
        t.config.data["rules"]["library-scale"].update({"script": "scripts/fake-crash.py", "ratchet": "all"})
        code = {"App/A.swift": "let a = try! load()\n"}
        t.expect("library-scale", "通用脚本：基线外的命中", code, 1, contains="no-force-try")
        t.expect("library-scale", "通用脚本：基线内", dict(code, **{"gate/library-scale.tsv": "# h\nno-force-try\tApp/A.swift\t1\n"}), 0)
        t.config.data["rules"]["library-scale"].pop("ratchet")
        t.expect("library-scale", "通用脚本：不按基线执行时命中一律报",
                 dict(code, **{"gate/library-scale.tsv": "# h\nno-force-try\tApp/A.swift\t1\n"}), 1)
    finally:
        t.config.tool_root = saved_root
        t.config.data["rules"]["library-scale"] = saved_spec
        shutil.rmtree(directory, ignore_errors=True)


def test_kit_layout(t):
    t.expect("kit-layout", "根目录的文件", {KIT_SRC + "/Loose.swift": "struct A {}\n"}, 1)
    t.expect("kit-layout", "配置里允许的根目录文件", {KIT_SRC + "/Constants.swift": "enum C {}\n"}, 0)
    t.expect("kit-layout", "测试目录没有对应源目录",
             {KIT_SRC + "/Audio/A.swift": "", KIT_TEST + "/Video/VTests.swift": "import XCTest\n"}, 1)
    t.expect("kit-layout", "测试目录镜像源目录",
             {KIT_SRC + "/Audio/Mixer/A.swift": "", KIT_TEST + "/Audio/Mixer/ATests.swift": "import XCTest\n",
              KIT_TEST + "/Support/Fixtures.swift": ""}, 0)
    t.expect("kit-layout", "测试根目录的文件", {KIT_TEST + "/LooseTests.swift": ""}, 1)


def test_layering(t):
    t.expect("layering", "核心包导入 SwiftUI", {KIT_SRC + "/UI/View.swift": "import Foundation\nimport SwiftUI\n"}, 1)
    t.expect("layering", "带特性的导入也算", {KIT_SRC + "/UI/View.swift": "@preconcurrency import UIKit\n"}, 1)
    t.expect("layering", "字符串和注释里的不算",
             {KIT_SRC + "/A/B.swift": 'let s = """\nimport SwiftUI\n"""\n// import AppKit\n/*\nimport UIKit\n*/\n'}, 0)
    t.expect("layering", "App 模块可以导入", {APP + "V.swift": "import SwiftUI\n"}, 0)
    t.expect("layering", "基线内", {KIT_SRC + "/UI/View.swift": "import SwiftUI\n",
                                   "gate/layering.tsv": "# h\nKit/Sources/Kit/UI/View.swift\t1\n"}, 0)


def pbxproj(files_by_target):
    """最小的 project.pbxproj：主分组下按目录建分组，每个目标一个 Sources 阶段。"""
    objects = []
    counter = [0]

    def oid():
        counter[0] += 1
        return "%024X" % counter[0]

    groups = {}
    root_group = oid()
    children = {root_group: []}
    refs = {}
    for paths in files_by_target.values():
        for path in paths:
            if path in refs:
                continue
            parent = root_group
            prefix = ""
            for part in path.split("/")[:-1]:
                prefix = prefix + "/" + part if prefix else part
                if prefix not in groups:
                    groups[prefix] = oid()
                    children[groups[prefix]] = []
                    children[parent].append(groups[prefix])
                parent = groups[prefix]
            refs[path] = oid()
            children[parent].append(refs[path])
            objects.append('%s = {isa = PBXFileReference; path = "%s"; sourceTree = "<group>"; };'
                           % (refs[path], path.split("/")[-1]))
    for prefix, identifier in groups.items():
        objects.append('%s = {isa = PBXGroup; children = (%s); path = "%s"; sourceTree = "<group>"; };'
                       % (identifier, ", ".join(children[identifier]), prefix.split("/")[-1]))
    objects.append('%s = {isa = PBXGroup; children = (%s); sourceTree = "<group>"; };'
                   % (root_group, ", ".join(children[root_group])))
    targets = []
    for name, paths in files_by_target.items():
        build_files = []
        for path in paths:
            build = oid()
            build_files.append(build)
            objects.append("%s = {isa = PBXBuildFile; fileRef = %s; };" % (build, refs[path]))
        phase, target = oid(), oid()
        objects.append("%s = {isa = PBXSourcesBuildPhase; files = (%s); };" % (phase, ", ".join(build_files)))
        objects.append("%s = {isa = PBXNativeTarget; buildPhases = (%s); name = %s; };" % (target, phase, name))
        targets.append(target)
    project = oid()
    objects.append("%s = {isa = PBXProject; mainGroup = %s; targets = (%s); };" % (project, root_group, ", ".join(targets)))
    return "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tobjects = {\n%s\n\t};\n\trootObject = %s;\n}\n" % (
        "\n".join("\t\t" + o for o in objects), project)


PROJECT_YML = '''name: App
targets:
  App:
    type: application
    sources:
      - path: App
        excludes:
          - "Mac/**"
          - "**/*.local.swift"
      - path: Shared/One.swift
  Kit:
    sources: [Kit]
'''


def test_project_file(t):
    base_files = {"project.yml": PROJECT_YML, "App/A.swift": "", "App/Views/B.swift": "", "App/Mac/M.swift": "",
                  "App/Secrets.local.swift": "", "Shared/One.swift": "", "Kit/K.swift": ""}
    good = {"App": ["App/A.swift", "App/Views/B.swift", "Shared/One.swift"], "Kit": ["Kit/K.swift"]}
    t.expect("project-file", "工程与 project.yml 一致", dict(base_files, **{"App.xcodeproj/project.pbxproj": pbxproj(good)}), 0)
    t.expect("project-file", "新文件没有重新生成工程",
             dict(base_files, **{"App/Views/New.swift": "", "App.xcodeproj/project.pbxproj": pbxproj(good)}), 1,
             contains="没有登记")
    stale = {"App": good["App"] + ["App/Gone.swift"], "Kit": good["Kit"]}
    t.expect("project-file", "工程里登记了已删的文件", dict(base_files, **{"App.xcodeproj/project.pbxproj": pbxproj(stale)}), 1,
             contains="不在了")
    excluded = {"App": good["App"] + ["App/Mac/M.swift"], "Kit": good["Kit"]}
    t.expect("project-file", "工程编了 excludes 排除的文件",
             dict(base_files, **{"App.xcodeproj/project.pbxproj": pbxproj(excluded)}), 1, contains="没有把它给")
    broken = pbxproj(good).replace("isa = PBXBuildFile;", "isa = PBX+Build;", 1)
    t.expect("project-file", "无效的属性表", dict(base_files, **{"App.xcodeproj/project.pbxproj": broken}), 1,
             contains="check-pbxproj")


def strings(entries):
    return "".join('"%s" = "%s";\n' % pair for pair in entries)


def test_localization(t):
    good = {"Res/en.lproj/Localizable.strings": strings([("a", "Hello %@"), ("b", "%lld songs")]),
            "Res/de.lproj/Localizable.strings": strings([("a", "Hallo %@"), ("b", "%lld Titel")]),
            "Res/ja.lproj/Localizable.strings": "/* 注释 */\n" + strings([("a", "こんにちは %@"), ("b", "%lld 曲")])}
    t.expect("localization", "三种语言一致", good, 0)
    t.expect("localization", "缺一个键", dict(good, **{"Res/de.lproj/Localizable.strings": strings([("a", "Hallo %@")])}), 1,
             contains="缺少 1 个键")
    t.expect("localization", "占位符不同",
             dict(good, **{"Res/de.lproj/Localizable.strings": strings([("a", "Hallo"), ("b", "%lld Titel")])}), 1,
             contains="占位符")
    t.expect("localization", "非中日文里有汉字",
             dict(good, **{"Res/de.lproj/Localizable.strings": strings([("a", "Hallo %@ 你好"), ("b", "%lld Titel")])}), 1,
             contains="汉字")
    t.expect("localization", "空译文",
             dict(good, **{"Res/de.lproj/Localizable.strings": strings([("a", "%@ "), ("b", " ")])}), 2)
    t.expect("localization", "重复的键",
             dict(good, **{"Res/de.lproj/Localizable.strings": strings([("a", "Hallo %@"), ("b", "%lld Titel"),
                                                                       ("a", "Hallo %@")])}), 1, contains="重复")
    t.expect("localization", "缺语言文件", {k: v for k, v in good.items() if "/ja." not in k}, 1, contains="缺少这些语言")
    t.expect("localization", "读不懂的文件",
             dict(good, **{"Res/de.lproj/Localizable.strings": '"a" = "Hallo %@"\n"b" = "x";\n'}), 1, contains="读不懂")
    known = {"gate/localization.tsv": "# h\nRes/de.lproj/Localizable.strings\tmissing-key:b\t1\n"}
    t.expect("localization", "基线里记着的缺键不报", dict(good, **known, **{"Res/de.lproj/Localizable.strings": strings([("a", "Hallo %@")])}), 0)
    t.expect("localization", "基线外的新问题照报",
             dict(good, **known, **{"Res/de.lproj/Localizable.strings": strings([("a", "Hallo")])}), 1,
             contains="占位符")
    t.check("localization", "占位符签名与 Ruby 版相同",
            formats.format_signature("%1$@ hat %2$lld %% und %.1f") == ["@", "f", "lld"])


def test_baseline_integrity(t):
    old = {"gate/file-size.tsv": "# h\nApp/Big.swift\t8\n"}
    t.expect("baseline-integrity", "基线变大", {"gate/file-size.tsv": "# h\nApp/Big.swift\t9\n"}, 1, base=old,
             contains="变大", severity="error")
    t.expect("baseline-integrity", "基线新增一项", {"gate/file-size.tsv": "# h\nApp/Big.swift\t8\nApp/New.swift\t7\n"}, 1, base=old)
    t.expect("baseline-integrity", "基线收紧", {"gate/file-size.tsv": "# h\nApp/Big.swift\t7\n"}, 0, base=old)
    noted = "# h\n# 放宽：2026-11-27 迁移期间（App/Big.swift 8 → 9）\nApp/Big.swift\t9\n"
    t.expect("baseline-integrity", "有放宽记录时只警告", {"gate/file-size.tsv": noted}, 1, base=old, severity="warn")
    t.expect("baseline-integrity", "拉取请求里放宽记录也不算", {"gate/file-size.tsv": noted}, 1, base=old, severity="error",
             strict=True)
    t.expect("baseline-integrity", "改名随基线一起改", {"gate/file-size.tsv": "# h\nApp/Moved.swift\t8\n"}, 0, base=old,
             mode="range", changes=[core.Change("R", "App/Moved.swift", "App/Big.swift")])


def test_commit_message(t):
    spec = t.config.rule("commit-message")
    cases = [
        ("一行中文标题", "曲库还没装好时不再把查不到当成没有 refs #478", False, 0),
        ("GitHub 的 squash 合并", "Mac 设置页开关改为原生无障碍开关 (#486)\n\n设置页回到前台时只刷新授权状态。", False, 0),
        ("功能描述里的产品名", "听歌识词的 Gemini 转写每一步都共用 AI 额度 (#299)", False, 0),
        ("功能描述里的 Claude API", "AI 设置页接入 Claude API 的流式输出", False, 0),
        ("功能描述：改用某模型生成", "歌词翻译改用 Gemini 生成，离线时回退本地模型", False, 0),
        ("人类合作者尾注", "修复投送断连\n\n发送端重复请求时继续等待同一次起播。\n\nCo-authored-by: Wang Wei <wei@example.com>", False, 0),
        ("合并提交", "Merge branch 'feature/x' into main", True, 0),
        ("Revert 不按包装长度算", 'Revert "%s"' % ("很" * 59), False, 0),
        ("空信息", "", False, 1),
        ("标题超长", "很" * 61, False, 1),
        ("标题两行", "第一行\n第二行", False, 1),
        ("正文两句", "标题\n\n第一句。\n第二句。", False, 1),
        ("正文一句太长", "标题\n\n" + "长" * 70, False, 1),
        ("AI 合作者尾注", "标题\n\nCo-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>", False, 1),
        ("生成声明和机器人", "标题\n\n\U0001F916 Generated with [Claude Code](https://claude.com/claude-code)", False, 1),
        ("会话尾注", "标题\n\nClaude-Session: https://claude.ai/code/session_01", False, 1),
        ("Codex 会话链接", "标题\n\nhttps://chatgpt.com/codex/tasks/task_e_123", False, 1),
        ("中文生成声明", "标题\n\n由 Claude Code 生成", False, 1),
        ("合并提交里的 AI 尾注", "Merge branch 'x'\n\nCo-authored-by: Codex <codex@openai.com>", True, 1),
    ]
    for label, text, is_merge, expected in cases:
        problems = commits.check_message(text, spec, is_merge)
        t.check("commit-message", label, len(problems) == expected, "：期望 %d 处，得到 %s" % (expected, problems))
    identities = [("Claude", "noreply@anthropic.com", 1), ("Claude Dupont", "claude@example.fr", 0),
                  ("copilot-swe-agent[bot]", "198982749+Copilot@users.noreply.github.com", 1),
                  ("github-actions[bot]", "41898282+github-actions[bot]@users.noreply.github.com", 0),
                  ("chenqi", "chenqi92104@icloud.com", 0), ("Codex CLI", "x@example.com", 1)]
    for name, email, expected in identities:
        t.check("commit-message", "身份 %s" % name, len(commits.identity_problems(spec, name, email)) == expected)
    t.check("commit-message", "去掉编辑器注释和剪刀线之后的内容",
            commits.clean_message("标题\n# 注释\n\n# ------------------------ >8 ------------------------\ndiff") == "标题")


def test_tests_with_code(t):
    config = t.config
    cases = [
        ("只改测试", ["AppTests/ATests.swift"], True),
        ("只改核心包测试和工程定义", ["Kit/Tests/KitTests/Audio/ATests.swift", "project.yml"], True),
        ("测试和代码一起", ["AppTests/ATests.swift", "App/A.swift"], False),
        ("只改代码", ["App/A.swift"], False),
        ("只改文档", ["Docs/notes.md"], False),
    ]
    for label, paths, expected in cases:
        only, _ = commits.test_only(config, paths)
        t.check("tests-with-code", label, only == expected)
    variable = config.rule("tests-with-code").get("override_env", "GATE_ALLOW_TEST_ONLY")
    previous = os.environ.get(variable)
    os.environ[variable] = "1"
    try:
        allowed = commits.check_staged_tests(config, [core.Change("M", "AppTests/ATests.swift")], None)
    finally:
        if previous is None:
            del os.environ[variable]
        else:
            os.environ[variable] = previous
    t.check("tests-with-code", "环境变量放行", allowed == [])
    blocked = commits.check_staged_tests(config, [core.Change("M", "AppTests/ATests.swift")], None)
    t.check("tests-with-code", "提示里写明环境变量", len(blocked) == 1 and variable in blocked[0].fix)


def test_plumbing(t):
    finding = core.Finding("file-size", "error", "A,b.swift", 3, "第一行\n50% 第二行", "改法")
    annotation = core.github_annotation(finding)
    t.check("format", "GitHub 注解转义", annotation.startswith("::error file=A%2Cb.swift,line=3,title=file-size::")
            and "%0A50%25" in annotation, annotation)
    t.check("format", "通配符 **/ 匹配零层目录", core.glob_match("x.swift", "**/x.swift") and
            core.glob_match("a/b/x.swift", "**/x.swift") and not core.glob_match("a/x.swifty", "**/x.swift"))
    t.check("format", "排除命中上层目录", core.matches_self_or_ancestor("Assets.xcassets/a/b.png", ["Assets.xcassets"]))
    parsed = formats.parse_yaml("a:\n  - path: X\n    excludes:\n      - \"**/y\"\n  - Z\nb: [1, 2]\nc: |\n  # 不是注释\n  x\n")
    t.check("format", "YAML 子集", parsed == {"a": [{"path": "X", "excludes": ["**/y"]}, "Z"], "b": ["1", "2"],
                                             "c": "# 不是注释\nx\n"}, str(parsed))
    old = core.Baseline.parse("b.tsv", ["path", "lines"], "# h\nA.swift\t10\nB.swift\t20\n")
    new = core.Baseline.parse("b.tsv", ["path", "lines"], "# h\nC.swift\t10\nB.swift\t21\n")
    grew = core.compare_baselines(old, new, {"C.swift": "A.swift"})
    t.check("format", "基线比较认改名、找出变大", grew == [(("B.swift",), 20, 21)], str(grew))
    tokens = swiftscan.tokenize('let a = "x\\(f("}"))y" /* /* */ } */ + #"\\(z)"# ; let r = /a\\/b/\n}')
    braces = [tok.text for tok in tokens if tok.kind == "punct" and tok.text in "{}"]
    t.check("format", "记号：插值、嵌套注释、原始字符串、正则", braces == ["}"], str(tokens))


def test_external(t):
    """外部脚本的接法：通过、没通过、缺工具时跳过。用临时目录里的两行 sh 脚本代替真的检查脚本。"""
    import shutil
    import tempfile
    directory = tempfile.mkdtemp(prefix="gate-selftest-")
    try:
        os.makedirs(os.path.join(directory, "scripts"))
        for name, body in (("ok.sh", "test -f README.md\n"), ("fail.sh", "echo 发现问题 >&2\nexit 1\n")):
            with open(os.path.join(directory, "scripts", name), "w") as handle:
                handle.write(body)
        with open(os.path.join(directory, "README.md"), "w") as handle:
            handle.write("x\n")
        config = copy.copy(t.config)
        config.data = copy.deepcopy(t.config.data)
        config.tool_root = directory
        base = {"severity": "error", "optional": True, "command": ["sh", "{script}"], "requires": ["sh"], "inputs": ["README.md"]}
        cases = [("通过", dict(base, script="scripts/ok.sh"), 0, None),
                 ("没通过", dict(base, script="scripts/fail.sh"), 1, None),
                 ("缺工具时跳过", dict(base, script="scripts/ok.sh", requires=["/nonexistent/tool"]), 0, "缺少"),
                 ("缺输入时跳过", dict(base, script="scripts/ok.sh", inputs=["Missing"]), 0, "缺少输入")]
        for label, spec, expected, skip in cases:
            config.data["rules"]["branding"] = spec
            ctx = rules.Context(config, core.WorkTree(directory, use_git=False), "all")
            try:
                findings = rules.run_external(ctx, "branding")
                ok = skip is None and len(findings) == expected and (not findings or "发现问题" in findings[0].message)
            except rules.Skip as error:
                ok = skip is not None and skip in str(error)
            t.check("external", label, ok)
        # CI 里关卡代码（基准分支那份）和被检查的树不在一处：脚本要按自己的位置找到被检查的树。
        tool = tempfile.mkdtemp(prefix="gate-selftest-tool-")
        try:
            os.makedirs(os.path.join(tool, "scripts"))
            with open(os.path.join(tool, "scripts", "sees-tree.sh"), "w") as handle:
                handle.write('root=$(cd "$(dirname "$0")/.." && pwd)\ntest -f "$root/README.md" && test ! -f "$root/scripts/ok.sh"\n')
            config.tool_root = tool
            config.data["rules"]["branding"] = dict(base, script="scripts/sees-tree.sh")
            ctx = rules.Context(config, core.WorkTree(directory, use_git=False), "all")
            t.check("external", "关卡代码与被检查的树不在一处", rules.run_external(ctx, "branding") == [])
        finally:
            shutil.rmtree(tool, ignore_errors=True)
    finally:
        shutil.rmtree(directory, ignore_errors=True)


def test_git_trees(t):
    """暂存区和提交里的树：先读文件、后列文件也要读得到（基线常常是第一个被读的文件）。"""
    import shutil
    import subprocess
    import tempfile
    if shutil.which("git") is None:
        t.check("format", "git 树（没有 git，跳过）", True)
        return
    directory = tempfile.mkdtemp(prefix="gate-selftest-git-")
    try:
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com", GIT_COMMITTER_NAME="t",
                   GIT_COMMITTER_EMAIL="t@example.com")
        for name, body in (("a.tsv", "x\t1\n"), ("b.swift", "let b = 1\n")):
            with open(os.path.join(directory, name), "w") as handle:
                handle.write(body)
        for command in (["init", "-q"], ["add", "-A"], ["commit", "-q", "--no-verify", "-m", "t"]):
            subprocess.run(["git", "-C", directory] + command, check=True, capture_output=True, env=env)
        for tree in (core.IndexTree(directory), core.CommitTree(directory, "HEAD")):
            text = tree.read("a.tsv")
            t.check("format", "%s 先读后列" % tree.label, text == "x\t1\n" and tree.exists("b.swift"), repr(text))
            tree.close()
    finally:
        shutil.rmtree(directory, ignore_errors=True)


def run(real_config, out):
    config = sample_config(real_config)
    runner = Runner(config, out)
    for test in (test_file_size, test_observable, test_library_scale, test_library_scale_generic, test_kit_layout, test_layering, test_project_file,
                 test_localization, test_baseline_integrity, test_commit_message, test_tests_with_code, test_external,
                 test_plumbing, test_git_trees):
        try:
            test(runner)
        except rules.Skip as skip:
            runner.check(test.__name__, "跳过", False, str(skip))
        except Exception as error:  # 自检本身出错也算失败
            runner.check(test.__name__, "异常", False, repr(error))
    total = sum(count for count, _ in runner.counts.values())
    for rule_id, (count, failed) in runner.counts.items():
        out.write("自检 %-22s %2d 条，%s\n" % (rule_id, count, "全部通过" if not failed else "失败 %d 条" % failed))
    out.write("自检共 %d 条，失败 %d 条\n" % (total, runner.failures))
    return 1 if runner.failures else 0
