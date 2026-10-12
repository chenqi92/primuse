#!/usr/bin/env python3
"""按线上真出过的闪退写法扫 Swift 源码,命中即失败。

每条规则都对应一次 Organizer 里的崩溃(见规则的 incident)。规则只认写法,
不懂类型,所以确认安全的命中要在同一行或上一行写明理由:

    // crash-pattern: allow <规则 id> <理由>

理由必填;没写理由的豁免照样算命中。

    scripts/check-crash-patterns.py              扫 git 跟踪的全部 .swift
    scripts/check-crash-patterns.py FILE...      只扫这些文件
    scripts/check-crash-patterns.py --list       列出规则
    scripts/check-crash-patterns.py --self-test  用内置样例自检规则

编译机的排队编译(primuse-ci)每次编译前跑一遍;仓库里没有这个脚本的老提交跳过。
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_PREFIXES = ("build/", "PrimuseKit/.build/", "Marketing/", "logs/")
ALLOW_RE = re.compile(r"//\s*crash-pattern:\s*allow\s+([\w-]+)\s+(\S.*)")


class Finding:
    def __init__(self, rule, path, line, text):
        self.rule, self.path, self.line, self.text = rule, path, line, text


def strip_comment(line):
    """去掉行尾 // 注释(不处理字符串里的 //,规则本身也不会匹配到字符串里)。"""
    index = line.find("//")
    return line if index < 0 else line[:index]


# ---------------------------------------------------------------------------
# 规则

RULES = {}


def rule(rule_id, summary, incident):
    def register(function):
        RULES[rule_id] = (summary, incident, function)
        return function
    return register


@rule("filehandle-legacy",
      "旧 FileHandle 接口读写出错时抛 Objective-C 异常,Swift 接不住;改用 read(upToCount:)、"
      "seekToEnd()、seek(toOffset:)、close() 这些 throws 版本",
      "fetchRange 读文件闪退,41caab1f")
def filehandle_legacy(lines):
    pattern = re.compile(r"\.(readData\(ofLength:|readDataToEndOfFile\(\)|seekToEndOfFile\(\)|"
                         r"seek\(toFileOffset:|closeFile\(\)|truncateFile\(atOffset:|"
                         r"synchronizeFile\(\))|\.availableData\b")
    for number, line in enumerate(lines, 1):
        if pattern.search(strip_comment(line)):
            yield number


@rule("avaudioengine-connect",
      "AVAudioEngine.connect 在节点不接受格式时抛 Objective-C 异常;改走 AudioEngine.connect(_:to:format:in:)"
      " 或 PrimuseConnectNodes",
      "91 号 AVAudioEngineGraph::Connect")
def avaudioengine_connect(lines):
    pattern = re.compile(r"\.connect\([^)]*\bto:[^)]*\bformat:")
    for number, line in enumerate(lines, 1):
        code = strip_comment(line)
        if pattern.search(code) and not re.search(r"\b(Self|AudioEngine)\.connect\(", code):
            yield number


@rule("audio-player-node-play",
      "AVAudioPlayerNode.play() 在引擎已停或节点没连好时抛 Objective-C 异常;改走 PrimuseStartPlayerNode",
      "Apple TV 直播电台启动闪退,8ac88b4d")
def audio_player_node_play(lines):
    declared = re.compile(r"\b(?:let|var)\s+(\w+)\s*(?::\s*AVAudioPlayerNode\b|=\s*AVAudioPlayerNode\(\))")
    names = {m.group(1) for line in lines for m in declared.finditer(strip_comment(line))}
    if not names:
        return
    pattern = re.compile(r"\b(%s)\??\.play\(" % "|".join(sorted(names)))
    for number, line in enumerate(lines, 1):
        if pattern.search(strip_comment(line)):
            yield number


@rule("frame-count-narrowing",
      "差值直接转成 32 位帧数,超出 UInt32 时溢出陷阱;先和上限取 min 再转",
      "超长有声书 runDecode 闪退,8218cc23")
def frame_count_narrowing(lines):
    pattern = re.compile(r"\b(AVAudioFrameCount|AVAudioPacketCount)\(([^()]|\([^()]*\))*\s-\s")
    for number, line in enumerate(lines, 1):
        code = strip_comment(line)
        match = pattern.search(code)
        if match and not re.search(r"\b(min|clamping|truncatingIfNeeded|exactly)\b", match.group(0)):
            yield number


LIBRARY_ARRAYS = r"(?:songs|visibleSongs|albums|artists|playlists)"


@rule("index-map-subscript",
      "按缓存的位置索引直接下标整库数组;原地改库的空窗里索引是满的、数组是空的,会越界。"
      "先 indices.contains 再核对 id(参考 lookupVisibleSong)",
      "100 号 MusicLibrary.song(id:) 越界")
def index_map_subscript(lines):
    one_line = re.compile(r"\w*IndexByID\[[^\]]+\]\.map\s*\{\s*" + LIBRARY_ARRAYS + r"\[\$0\]")
    binding = re.compile(r"\blet\s+(\w+)\s*=\s*\w*IndexByID\[")
    for number, line in enumerate(lines, 1):
        code = strip_comment(line)
        if one_line.search(code):
            yield number
            continue
        match = binding.search(code)
        if not match:
            continue
        name = match.group(1)
        window = " ".join(strip_comment(l) for l in lines[number - 1:number + 3])
        uses = re.search(r"(?<![\w.])" + LIBRARY_ARRAYS + r"\[" + name + r"\]", window)
        checked = re.search(r"indices\.contains\(\s*" + name + r"\s*\)", window)
        if uses and not checked:
            yield number


@rule("lazy-self-in-deinit",
      "deinit 里第一次访问 lazy 属性,初始化里对 self 建弱引用时 objc 直接终止;"
      "析构只碰已经建好的存储(改成可选存储属性)",
      "Apple TV SessionDelegateProxy.init 闪退,f1b875e8")
def lazy_self_in_deinit(lines):
    lazy = re.compile(r"\blazy\s+(?:(?:private|fileprivate|internal|public)(?:\(set\))?\s+)*var\s+(\w+)")
    candidates = {}
    for number, line in enumerate(lines, 1):
        match = lazy.search(strip_comment(line))
        if not match:
            continue
        body = []
        for later in lines[number - 1:number + 30]:
            body.append(strip_comment(later))
            if "}()" in later:
                break
        if re.search(r"\bself\b", " ".join(body)):
            candidates[match.group(1)] = number
    if not candidates:
        return
    text = [strip_comment(line) for line in lines]
    for index, line in enumerate(text):
        if not re.search(r"\bdeinit\s*\{", line):
            continue
        depth, body = 0, []
        for later in text[index:]:
            body.append(later)
            depth += later.count("{") - later.count("}")
            if depth <= 0:
                break
        joined = " ".join(body)
        for name, number in candidates.items():
            if re.search(r"\b" + name + r"\b", joined):
                yield number


# ---------------------------------------------------------------------------

def allowed(rule_id, lines, number):
    for candidate in (lines[number - 1], lines[number - 2] if number >= 2 else ""):
        match = ALLOW_RE.search(candidate)
        if match and match.group(1) == rule_id and match.group(2).strip():
            return True
    return False


def scan_text(path, text):
    lines = text.split("\n")
    findings = []
    for rule_id, (_, _, function) in RULES.items():
        for number in sorted(set(function(lines))):
            if not allowed(rule_id, lines, number):
                findings.append(Finding(rule_id, path, number, lines[number - 1].strip()))
    return findings


def tracked_swift_files():
    output = subprocess.run(["git", "-C", ROOT, "ls-files", "-z", "--", "*.swift"],
                            capture_output=True, check=True).stdout.decode()
    return [p for p in output.split("\0") if p and not p.startswith(SKIP_PREFIXES)]


def run(paths):
    findings = []
    for path in paths:
        full = path if os.path.isabs(path) else os.path.join(ROOT, path)
        try:
            with open(full, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError as error:
            print("读不了 %s: %s" % (path, error), file=sys.stderr)
            return 2
        findings.extend(scan_text(path, text))
    for finding in findings:
        print("%s:%d: [%s] %s" % (finding.path, finding.line, finding.rule, finding.text[:160]))
    if findings:
        print()
        for rule_id in sorted({f.rule for f in findings}):
            summary, incident, _ = RULES[rule_id]
            print("[%s] %s(来源:%s)" % (rule_id, summary, incident))
        print("\n共 %d 处。确认安全的在同一行或上一行写 `// crash-pattern: allow <规则> <理由>`。" % len(findings))
        return 1
    print("check-crash-patterns: %d 个文件,没有命中" % len(paths))
    return 0


SELF_TEST = [
    ("filehandle-legacy", "let data = handle.readData(ofLength: 4096)", True),
    ("filehandle-legacy", "let data = try handle.read(upToCount: 4096) ?? Data()", False),
    ("filehandle-legacy", "// `readData(ofLength:)` raises", False),
    ("avaudioengine-connect", "eng.connect(playerA, to: eng.outputNode, format: format)", True),
    ("avaudioengine-connect", "try Self.connect(playerA, to: eng.outputNode, format: format, in: eng)", False),
    ("avaudioengine-connect", "try AudioEngine.connect(input, to: reverb, format: f, in: engine)", False),
    ("avaudioengine-connect", "socket.connect(to: host)", False),
    ("audio-player-node-play", "let node = AVAudioPlayerNode()\nnode.play()", True),
    ("audio-player-node-play", "private var playerNode: AVAudioPlayerNode?\nplayerNode?.play()", True),
    ("audio-player-node-play", "let player = AVPlayer()\nplayer.play()", False),
    ("frame-count-narrowing", "let n = AVAudioFrameCount(totalFrames - position)", True),
    ("frame-count-narrowing", "let n = AVAudioFrameCount(min(totalFrames - position, 8192))", False),
    ("frame-count-narrowing", "let n = AVAudioFrameCount(buffer.frameLength)", False),
    ("index-map-subscript", "guard let index = songIndexByID[id] else { return nil }\n"
                            "return songs[index]", True),
    ("index-map-subscript", "if let index = songIndexByID[id] { return songs[index] }", True),
    ("index-map-subscript", "guard let index = songIndexByID[id] else { return nil }\n"
                            "let songs = songsReference.value\n"
                            "guard songs.indices.contains(index) else { return nil }", False),
    ("index-map-subscript", "songIndexByID[id].map { songs[$0] }", True),
    ("index-map-subscript", "let index = songIndexByID[id]!\nreturn songs[index]", True),
    ("index-map-subscript", "let index = songIndexByID[id]!\n"
                            "guard songs.indices.contains(index) else { return nil }\nreturn songs[index]", False),
    ("lazy-self-in-deinit", "lazy var session: URLSession = {\n"
                            "  URLSession(configuration: .default, delegate: Proxy(self), delegateQueue: nil)\n"
                            "}()\ndeinit {\n  session.invalidateAndCancel()\n}", True),
    ("lazy-self-in-deinit", "private var sessionStorage: URLSession?\n"
                            "deinit {\n  sessionStorage?.invalidateAndCancel()\n}", False),
    ("lazy-self-in-deinit", "lazy var formatter: DateFormatter = {\n  DateFormatter()\n}()\n"
                            "deinit {\n  print(formatter)\n}", False),
    ("filehandle-legacy", "// crash-pattern: allow filehandle-legacy 只在测试里造异常\n"
                          "handle.closeFile()", False),
    ("filehandle-legacy", "handle.closeFile() // crash-pattern: allow filehandle-legacy", True),
]


def self_test():
    failures = 0
    for rule_id, snippet, expected in SELF_TEST:
        hits = [f for f in scan_text("<self-test>", snippet) if f.rule == rule_id]
        if bool(hits) != expected:
            failures += 1
            print("自检失败 [%s] 期望%s命中:\n%s\n" % (rule_id, "" if expected else "不", snippet))
    print("自检 %d 条,失败 %d 条" % (len(SELF_TEST), failures))
    return 1 if failures else 0


def main(argv):
    if argv[:1] == ["--list"]:
        for rule_id, (summary, incident, _) in RULES.items():
            print("%-24s %s(来源:%s)" % (rule_id, summary, incident))
        return 0
    if argv[:1] == ["--self-test"]:
        return self_test()
    return run(argv or tracked_swift_files())


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
