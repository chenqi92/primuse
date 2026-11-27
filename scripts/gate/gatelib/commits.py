"""提交信息与「测试跟着代码走」两条规则。"""
import os
import re

from . import core
from .core import Finding

TRAILER_RE = re.compile(r"^([A-Za-z][A-Za-z0-9-]*)\s*:\s+\S")
HUMAN_TRAILERS = {"co-authored-by", "signed-off-by", "reviewed-by", "acked-by", "tested-by", "reported-by",
                  "helped-by", "suggested-by", "fixes", "closes", "refs", "resolves", "cc"}


def _names_pattern(names):
    return "(?:" + "|".join(names) + ")"


def attribution_patterns(spec):
    """匹配署名写法而不是单词：产品名出现在功能描述里（「接入 Claude API」）不算。"""
    names = _names_pattern(spec.get("ai_names", []))
    session_words = _names_pattern(spec.get("session_words", ["Session", "Session-Id", "Session-URL", "Task", "Run",
                                                              "Agent", "Conversation", "Chat", "Link", "Trace"]))
    patterns = [
        ("署名尾注", re.compile(r"(?im)^[ \t]*(?:Co-Authored-By|Signed-off-by|Assisted-by|Generated-by|Authored-by|Written-by|"
                                r"Created-by|Made-with|Generated-with|AI-Assisted|AI-Generated|Reviewed-by|Suggested-by|Helped-by)"
                                r"\s*:.*\b" + names + r"\b")),
        ("会话尾注", re.compile(r"(?im)^[ \t]*" + names + r"[- ]?" + session_words + r"[ \t]*:")),
        ("生成声明", re.compile(r"(?im)^[^\w\n]*(?:generated|created|written|authored|made|built|produced|assisted|"
                                r"co-?authored)\s+(?:with|by|using|via)\s+\[?\s*" + names)),
        ("生成声明", re.compile(r"(?m)^[^\w\n]*(?:本次|此|这个|这次)?(?:提交|改动|代码|补丁)?\s*(?:由|借助|使用)\s*" + names +
                                r"(?:\s*Code)?\s*(?:生成|编写|撰写|协助|辅助|代写)\S{0,6}\s*$")),
        ("会话链接", re.compile(r"(?i)(?:claude\.ai/(?:code|chat|share|session)|chatgpt\.com/(?:codex|share|c)/|"
                                r"chat\.openai\.com/|gemini\.google\.com/(?:app|share)/|copilot-workspace\.githubnext\.com|"
                                r"cursor\.com/(?:agents|background)|claude\.com/claude-code)")),
        ("机器人标记", re.compile("\U0001F916")),
        ("AI 邮箱", re.compile(r"(?i)noreply@anthropic\.com|@openai\.com\b|copilot@github\.com|codex@")),
    ]
    return patterns


def find_attribution(text, spec):
    """[(行号, 种类, 那一行)]：同一行命中几种写法只算一处。"""
    by_line = {}
    for label, pattern in attribution_patterns(spec):
        for match in pattern.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            labels = by_line.setdefault(line, [])
            if label not in labels:
                labels.append(label)
    rows = text.split("\n")
    return [(line, "、".join(labels), rows[line - 1].strip()[:100]) for line, labels in sorted(by_line.items())]


def clean_message(text, comment_char="#"):
    """去掉 git 编辑器里的注释行和 `--verbose` 的剪刀线之后的内容。"""
    lines = []
    for line in text.replace("\r\n", "\n").split("\n"):
        if line.startswith(comment_char + " ------------------------ >8 ------------------------"):
            break
        if comment_char and line.startswith(comment_char):
            continue
        lines.append(line.rstrip())
    while lines and not lines[-1].strip():
        lines.pop()
    while lines and not lines[0].strip():
        lines.pop(0)
    return "\n".join(lines)


def check_message(text, spec, is_merge=False):
    """返回 [(问题, 改法)]。"""
    problems = []
    lines = text.split("\n") if text else []
    for line, label, excerpt in find_attribution(text, spec):
        problems.append(("提交信息带了 AI 署名（%s，第 %d 行：%s）" % (label, line, excerpt),
                         "删掉这一行；提交里不写工具或模型的署名、生成声明和会话链接"))
    if is_merge:
        return problems
    subject = lines[0] if lines else ""
    if not subject.strip():
        problems.append(("提交信息是空的", "写一行说明这次改了什么（对用户或对 App）"))
        return problems
    limit = int(spec.get("subject_max_bytes", 180))
    measured = subject
    revert = re.match(r'^Revert "(.*)"$', subject)
    if revert:
        measured = revert.group(1)
    size = len(measured.encode("utf-8"))
    if size > limit:
        problems.append(("标题 %d 字节，超过 %d 字节（约 %d 个汉字）" % (size, limit, limit // 3),
                         "只写对用户或对 App 改了什么，细节留给交接文档"))
    if len(lines) > 1 and lines[1].strip():
        problems.append(("标题占了不止一行", "标题只写一行；需要补一句时空一行再写"))
    body = [line for line in lines[1:] if line.strip()]
    trailers = [line for line in body if TRAILER_RE.match(line) and TRAILER_RE.match(line).group(1).lower() in HUMAN_TRAILERS]
    prose = [line for line in body if line not in trailers]
    max_lines = int(spec.get("body_max_lines", 1))
    line_limit = int(spec.get("body_line_max_bytes", 200))
    if len(prose) > max_lines:
        problems.append(("正文有 %d 行，最多 %d 行" % (len(prose), max_lines),
                         "提交信息一行说明改了什么，至多再补一句；验证过程、测试数字和文件清单写进交接文档"))
    for line in prose[:max_lines]:
        size = len(line.encode("utf-8"))
        if size > line_limit:
            problems.append(("正文那一句 %d 字节，超过 %d 字节" % (size, line_limit), "正文只补一句短话，细节写进交接文档"))
    return problems


def merge_in_progress(root):
    if root is None:
        return False
    git_dir = core.git_text(root, "rev-parse", "--git-dir", check=False).strip()
    if not git_dir:
        return False
    if not os.path.isabs(git_dir):
        git_dir = os.path.join(root, git_dir)
    return os.path.exists(os.path.join(git_dir, "MERGE_HEAD"))


def test_only(config, paths):
    spec = config.rule("tests-with-code")
    neutral = spec.get("neutral_globs", [])
    tests = [p for p in paths if config.is_test(p)]
    others = [p for p in paths if not config.is_test(p) and not core.matches_any(p, neutral)]
    return bool(tests) and not others, tests


def tests_with_code_finding(config, tests, subject=None):
    spec = config.rule("tests-with-code")
    variable = spec.get("override_env", "GATE_ALLOW_TEST_ONLY")
    sample = "、".join(tests[:3]) + ("……" if len(tests) > 3 else "")
    return Finding("tests-with-code", config.severity("tests-with-code"), None, None,
                   "这次提交只改了测试（%s）" % sample,
                   "测试和它覆盖的代码放进同一个提交；只改测试的改动并进下一个相关的功能提交。"
                   "确属例外（例如只修一个坏掉的测试）时设环境变量 %s=1 再提交" % variable, subject=subject)


def check_staged_tests(config, changes, root):
    spec = config.rule("tests-with-code")
    if os.environ.get(spec.get("override_env", "GATE_ALLOW_TEST_ONLY")) == "1" or merge_in_progress(root):
        return []
    paths = []
    for change in changes:
        paths.append(change.path)
        if change.old_path:
            paths.append(change.old_path)
    only, tests = test_only(config, paths)
    return [tests_with_code_finding(config, tests, subject="暂存的改动")] if only else []


def identity_problems(spec, name, email):
    """作者或提交者是 AI 的身份：AI 厂商的邮箱，或者名字就是 AI 产品名（「Claude」「Codex CLI」「copilot-swe-agent[bot]」）。
    名字里只是含有这个词的人（例如名叫 Claude 的人带着姓）不算。"""
    names = _names_pattern(spec.get("ai_names", []))
    by_email = re.search(r"(?i)noreply@anthropic\.com|@anthropic\.com$|@openai\.com$", email or "")
    by_name = re.match(r"(?i)^\s*" + names + r"(?:[\s-]+(?:code|agent|cli|assistant|ai|swe-agent|coding-agent))*"
                       r"\s*(?:\[bot\])?\s*$", name or "")
    if by_email or by_name:
        return [("作者或提交者是 AI 身份（%s <%s>）" % (name, email),
                 "用仓库所有者自己的 Git 身份提交（git config user.name / user.email）")]
    return []


def check_commits(config, root, spec_range, stream=None):
    """--commits A..B：逐个检查范围里的提交（B 有、A 没有的）。"""
    findings = []
    base_spec, head_spec = spec_range.split("..", 1)
    head = core.rev_parse(root, head_spec or "HEAD")
    if head is None:
        raise core.GateError("找不到提交 %s" % head_spec)
    if base_spec and not core.is_zero_sha(base_spec):
        base = core.rev_parse(root, base_spec)
        if base is None:
            raise core.GateError("找不到提交 %s（CI 里要 fetch-depth: 0）" % base_spec)
        revs = core.git_text(root, "rev-list", "--reverse", "%s..%s" % (base, head)).split()
    else:
        revs = core.git_text(root, "rev-list", "--reverse", head).split()
    message_spec = config.rule("commit-message")
    override = os.environ.get(config.rule("tests-with-code").get("override_env", "GATE_ALLOW_TEST_ONLY")) == "1"
    for rev in revs:
        raw = core.git(root, "log", "-1", "--format=%P%x00%an%x00%ae%x00%cn%x00%ce%x00%B", rev).stdout.decode("utf-8", "replace")
        parents, author, author_email, committer, committer_email, message = raw.split("\x00", 5)
        is_merge = len(parents.split()) > 1
        subject = "%s「%s」" % (rev[:9], message.split("\n", 1)[0][:40])
        if config.enabled("commit-message"):
            problems = check_message(message.strip("\n"), message_spec, is_merge)
            problems += identity_problems(message_spec, author, author_email)
            if committer_email != author_email:
                problems += identity_problems(message_spec, committer, committer_email)
            for problem, fix in problems:
                findings.append(Finding("commit-message", config.severity("commit-message"), None, None, problem, fix,
                                        subject=subject))
        if config.enabled("tests-with-code") and not is_merge and not override:
            changed = core.git_text(root, "diff-tree", "--no-commit-id", "--name-only", "-r", "-z", "--root", rev).split("\0")
            only, tests = test_only(config, [p for p in changed if p])
            if only:
                findings.append(tests_with_code_finding(config, tests, subject=subject))
    return findings, revs
