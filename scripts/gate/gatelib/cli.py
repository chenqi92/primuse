"""命令行：选出要查的树和改动，跑规则，输出，决定退出码。"""
import argparse
import datetime
import os
import sys
import time

from . import commits, core, rules
from .core import GateError

USAGE = """\
架构关卡：一条命令检查本仓库定下的架构规则。

  gate.py [--all]                    查整个工作区（默认）
  gate.py --staged                   只查暂存的改动（pre-commit 用，要快）
  gate.py --range BASE..HEAD         查这段范围改到的文件，加上全局的基线检查（CI、pre-push 用）
  gate.py --commits BASE..HEAD       逐个检查这段范围里的提交信息与「测试跟着代码走」
  gate.py --commit-msg FILE          检查一条提交信息（commit-msg 用）
  gate.py --pre-push REMOTE          读 git 在标准输入给的推送行，逐个分支查（pre-push 用）
  gate.py --update-baseline [--allow-growth "理由"]  按现状重写基线；基线只许变小
  gate.py --self-test | --list-rules
"""


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="gate.py", description=USAGE, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--all", action="store_true", help="查整个工作区")
    mode.add_argument("--staged", action="store_true", help="只查暂存区")
    mode.add_argument("--range", metavar="BASE..HEAD", help="查一段提交范围")
    mode.add_argument("--commit-msg", metavar="FILE", help="检查一条提交信息")
    mode.add_argument("--pre-push", metavar="REMOTE", help="pre-push 钩子：从标准输入读推送的分支")
    mode.add_argument("--update-baseline", action="store_true", help="按现状重写基线（只许变小）")
    mode.add_argument("--self-test", action="store_true", help="用内置样例自检每条规则")
    mode.add_argument("--list-rules", action="store_true", help="列出规则")
    parser.add_argument("--commits", metavar="BASE..HEAD", help="同时检查这段范围里的提交")
    parser.add_argument("--format", choices=("text", "github"), default="text")
    parser.add_argument("--require-all", action="store_true", help="有规则因为缺工具跳过时也算失败（CI 用）")
    parser.add_argument("--strict-baselines", action="store_true", help="基线变大一律算错，不认放宽记录（拉取请求用）")
    parser.add_argument("--allow-growth", metavar="理由", help="和 --update-baseline 一起用：允许基线变大并记下理由")
    parser.add_argument("--root", help="被检查的仓库（默认是关卡所在的仓库）")
    parser.add_argument("--config", help="配置文件（默认是 gate.py 旁边的 gate.config.json）")
    parser.add_argument("--only", help="只跑这些规则，逗号分隔")
    parser.add_argument("--quiet", action="store_true", help="全部通过时什么都不打印（钩子用）")
    return parser.parse_args(argv)


def default_config_path():
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "gate.config.json")


def selected_rules(config, mode, only):
    wanted = set(only.split(",")) if only else None
    result = []
    for info in rules.REGISTRY:
        if not config.enabled(info.id):
            continue
        if wanted is not None and info.id not in wanted:
            continue
        if mode not in info.modes:
            continue
        result.append(info)
    return result


def worktree_clean(root):
    output = core.git(root, "status", "--porcelain", "--untracked-files=no", check=False).stdout
    return not output.strip()


def build_context(config, root, mode, range_spec=None, strict=False):
    use_git = core.is_git_repo(root)
    if mode == "all":
        tree = core.WorkTree(root, use_git)
        head = core.rev_parse(root, "HEAD") if use_git else None
        base_tree = core.CommitTree(root, head) if head else None
        ctx = rules.Context(config, tree, "all", None, base_tree, strict, root)
        if use_git:
            ctx.renames = {c.path: c.old_path for c in core.worktree_changes(root) if c.status == "R"}
        return ctx, "工作区"
    if not use_git:
        raise GateError("%s 不是 git 仓库，--staged 和 --range 用不了" % root)
    if mode == "staged":
        tree = core.IndexTree(root)
        changes = core.staged_changes(root)
        head = core.rev_parse(root, "HEAD")
        base_tree = core.CommitTree(root, head) if head else None
        return rules.Context(config, tree, "staged", changes, base_tree, strict, root), "暂存区"
    merge_base, head, _ = core.resolve_range(root, range_spec)
    tree = core.CommitTree(root, head)
    if core.rev_parse(root, "HEAD") == head and worktree_clean(root):
        tree.disk_root = root
    changes = core.range_changes(root, merge_base, head)
    base_tree = core.CommitTree(root, merge_base)
    return rules.Context(config, tree, "range", changes, base_tree, strict, root), "范围 %s..%s" % (merge_base[:10], head[:10])


def run_rules(ctx, infos, report):
    for info in infos:
        severity = ctx.config.severity(info.id)
        report.ran.append((info.id, severity))
        try:
            report.add(info.function(ctx))
        except rules.NotApplicable:
            report.not_applicable.append(info.id)
        except rules.Skip as skip:
            report.skip(info.id, str(skip), bool(ctx.config.rule(info.id).get("optional", False)))


def add_tighten_note(ctx, report, limit=10):
    if not ctx.tighten:
        return
    report.note("可以收紧的基线 %d 项（运行 python3 -I scripts/gate/gate.py --update-baseline）：" % len(ctx.tighten))
    for rule_id, key, before, after in ctx.tighten[:limit]:
        report.note("  %s %s %d → %d" % (rule_id, "/".join(key), before, after))
    if len(ctx.tighten) > limit:
        report.note("  ……")


def static_run(config, root, mode, args, report, range_spec=None):
    ctx, label = build_context(config, root, mode, range_spec, args.strict_baselines)
    try:
        infos = selected_rules(config, mode, args.only)
        run_rules(ctx, infos, report)
        add_tighten_note(ctx, report)
        files = len(ctx.swift_files())
        return "%s，%s 个 Swift 文件" % (label, "{:,}".format(files))
    finally:
        ctx.tree.close()
        if ctx.base_tree is not None:
            ctx.base_tree.close()


def commits_run(config, root, range_spec, report, only=None):
    wanted = set(only.split(",")) if only else None
    if wanted is not None and not wanted & {"commit-message", "tests-with-code"}:
        return "提交 0 个"
    for rule_id in ("commit-message", "tests-with-code"):
        if config.enabled(rule_id):
            report.ran.append((rule_id, config.severity(rule_id)))
    findings, revs = commits.check_commits(config, root, range_spec)
    if wanted is not None:
        findings = [f for f in findings if f.rule in wanted]
    report.add(findings)
    return "%d 个提交" % len(revs)


def commit_msg_run(config, root, path, report):
    with open(path, encoding="utf-8", errors="replace") as handle:
        raw = handle.read()
    comment = "#"
    if core.is_git_repo(root):
        configured = core.git_text(root, "config", "--get", "core.commentChar", check=False).strip()
        if configured and configured != "auto":
            comment = configured
    text = commits.clean_message(raw, comment)
    is_merge = commits.merge_in_progress(root) if core.is_git_repo(root) else False
    report.ran.append(("commit-message", config.severity("commit-message")))
    for problem, fix in commits.check_message(text, config.rule("commit-message"), is_merge):
        report.add([core.Finding("commit-message", config.severity("commit-message"), None, None, problem, fix,
                                 subject="提交信息")])
    return "提交信息"


def staged_extra(config, root, report):
    """--staged 时再查「测试跟着代码走」。"""
    if not config.enabled("tests-with-code"):
        return
    report.ran.append(("tests-with-code", config.severity("tests-with-code")))
    report.add(commits.check_staged_tests(config, core.staged_changes(root), root))


def push_base(config, root, remote, local_sha, remote_sha):
    if not core.is_zero_sha(remote_sha) and core.rev_parse(root, remote_sha):
        return remote_sha
    branch = config.data.get("default_branch", "main")
    for candidate in ("refs/remotes/%s/%s" % (remote, branch), "refs/remotes/%s/HEAD" % remote):
        if core.rev_parse(root, candidate):
            merge_base = core.git_text(root, "merge-base", local_sha, candidate, check=False).strip()
            if merge_base:
                return merge_base
    fresh = core.git_text(root, "rev-list", "--reverse", local_sha, "--not", "--remotes=%s" % remote, check=False).split()
    if not fresh:
        return local_sha
    parent = core.rev_parse(root, fresh[0] + "^")
    return parent or ""


def pre_push_run(config, root, remote, args, report, stdin):
    labels = []
    for line in stdin.read().split("\n"):
        parts = line.split()
        if len(parts) != 4:
            continue
        local_ref, local_sha, remote_ref, remote_sha = parts
        if core.is_zero_sha(local_sha):
            labels.append("删除 %s，不用查" % remote_ref)
            continue
        if remote_ref.startswith("refs/tags/"):
            continue
        base = push_base(config, root, remote, local_sha, remote_sha)
        if base == local_sha:
            labels.append("%s 没有新提交" % remote_ref)
            continue
        spec = "%s..%s" % (base, local_sha)
        label = static_run(config, root, "range", args, report, spec)
        label += "，" + commits_run(config, root, spec, report, args.only)
        labels.append("推送 %s：%s" % (remote_ref.replace("refs/heads/", ""), label))
    return "；".join(labels) or "没有要推送的分支"


# ---------------------------------------------------------------------------
# --update-baseline

DEFAULT_HEADERS = {
    "file-size": "# file-size 的棘轮基线：文件\t行数。超过上限的文件只许变短；由 python3 -I scripts/gate/gate.py --update-baseline 生成。",
    "observable-class-body": "# observable-class-body 的棘轮基线：文件\t类\t类体里该放进扩展的成员数。只许变少；由 python3 -I scripts/gate/gate.py --update-baseline 生成。",
    "layering": "# layering 的棘轮基线：文件\t导入界面框架的次数。只许变少；由 python3 -I scripts/gate/gate.py --update-baseline 生成。",
}


def update_baseline(config, root, reason, out):
    ctx, _ = build_context(config, root, "all")
    growth_total = []
    plans = []
    for rule_id, columns in rules.BASELINE_COLUMNS.items():
        if not config.enabled(rule_id) or not ctx.baseline_path(rule_id):
            continue
        info = rules.rule_info(rule_id)
        try:
            info.function(ctx)
        except rules.Skip as skip:
            out.write("SKIPPED %s: %s（基线不动）\n" % (rule_id, skip))
            continue
        old = ctx.baseline(rule_id)
        creating = ctx.tree.read(old.path) is None
        new = core.Baseline(old.path, columns, list(old.header) or [DEFAULT_HEADERS.get(rule_id, "# %s" % rule_id)])
        new.notes = list(old.notes)
        new.entries = dict(ctx.counts.get(rule_id, {}))
        grew = [] if creating else core.compare_baselines(old, new, ctx.renames)
        growth_total.extend((rule_id, key, before, after) for key, before, after in grew)
        plans.append((rule_id, old, new, grew))
    ctx.tree.close()
    if growth_total and not reason:
        out.write("基线不能变大，没有写入。变大的项：\n")
        for rule_id, key, before, after in growth_total:
            out.write("  %s %s %d → %d\n" % (rule_id, "/".join(key), before, after))
        out.write("先修代码让它回到基线以内；确需放宽由仓库所有者加 --allow-growth \"理由\" 重跑。\n")
        return 1
    today = datetime.datetime.utcnow().strftime("%Y-%m-%d")
    for rule_id, old, new, grew in plans:
        if grew:
            detail = "；".join("%s %d → %d" % ("/".join(key), before, after) for key, before, after in grew)
            new.notes.append("%s%s %s（%s）" % (core.GROWTH_NOTE_PREFIX, today, reason.strip(), detail))
        if new.render() == (old.render() if old.entries or old.header else ""):
            out.write("%s：没有变化（%d 项，共 %d）\n" % (rule_id, len(new.entries), new.total()))
            continue
        removed = [k for k in old.entries if k not in new.entries]
        shrunk = [k for k in new.entries if k in old.entries and new.entries[k] < old.entries[k]]
        target = os.path.join(root, new.path)
        if not os.path.isdir(os.path.dirname(target)):
            os.makedirs(os.path.dirname(target))
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(new.render())
        out.write("%s：写入 %s，%d 项，共 %d（收紧 %d 项，删掉 %d 项%s）\n" % (
            rule_id, new.path, len(new.entries), new.total(), len(shrunk), len(removed),
            "，放宽 %d 项" % len(grew) if grew else ""))
    return 0


# ---------------------------------------------------------------------------

def main(argv, stdin=None, stdout=None):
    stdout = stdout or sys.stdout
    args = parse_args(argv)
    config = core.Config(args.config or default_config_path())
    root = os.path.abspath(args.root) if args.root else config.tool_root
    if args.list_rules:
        for info in rules.REGISTRY + [rules.RuleInfo("commit-message", "提交信息一行、不超长、不带 AI 署名", "message", None, ()),
                                      rules.RuleInfo("tests-with-code", "不提交只改测试的提交", "message", None, ())]:
            spec = config.rule(info.id)
            state = "关" if not config.enabled(info.id) else spec.get("severity", "error")
            optional = "，可选" if spec.get("optional") else ""
            stdout.write("%-24s %-6s %-9s %s%s\n" % (info.id, state, info.kind, info.title, optional))
        return 0
    if args.self_test:
        from . import selftest
        return selftest.run(config, stdout)
    try:
        if args.update_baseline:
            return update_baseline(config, root, args.allow_growth, stdout)
        started = time.time()
        report = core.Report(args.format, stdout)
        parts = []
        if args.commit_msg:
            parts.append(commit_msg_run(config, root, args.commit_msg, report))
        elif args.pre_push:
            parts.append(pre_push_run(config, root, args.pre_push, args, report, stdin or sys.stdin))
        else:
            if args.staged:
                parts.append(static_run(config, root, "staged", args, report))
                staged_extra(config, root, report)
            elif args.range:
                parts.append(static_run(config, root, "range", args, report, args.range))
            elif not args.commits:
                parts.append(static_run(config, root, "all", args, report))
            if args.commits:
                parts.append(commits_run(config, root, args.commits, report, args.only))
        header = "架构关卡（%s，用时 %.1f 秒）" % ("；".join(parts), time.time() - started)
        failed = report.emit(args.require_all, header, quiet_pass=args.quiet)
        return 1 if failed else 0
    except GateError as error:
        stdout.write("架构关卡出错：%s\n" % error)
        return 1
