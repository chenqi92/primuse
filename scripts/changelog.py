#!/usr/bin/env python3
"""从 Git 提交维护 CHANGELOG，并为发布流程提供版本信息。

子命令：
  version   输出 project.yml 中的 MARKETING_VERSION 与 CURRENT_PROJECT_VERSION
  versions  列出历史上的版本区间，并标出尚未写进 CHANGELOG 的版本
  is-bump   判断某个提交是否改动了版本号或构建号
  draft     按提交记录生成指定版本的更新日志草稿（Markdown 段落）
  sanitize  校正模型输出的段落格式，不可用时以非零退出码交回调用方
  apply     把段落写入 CHANGELOG.md 或 CHANGELOG.en.md，已存在则替换
  extract   从 CHANGELOG 中取出指定版本的段落正文
"""

from __future__ import annotations

import argparse
import functools
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT_YML = ROOT / "project.yml"
CHANGELOG_ZH = ROOT / "CHANGELOG.md"
CHANGELOG_EN = ROOT / "CHANGELOG.en.md"

# 纯版本提交的前缀，例如「发布 1.9.7（74）」「更新 1.9.6 构建 72 并保留 Siri 名称识别」
VERSION_PREFIX = re.compile(
    r"^(?:发布|更新至|更新|升级到|bump|chore\(release\):?)\s*v?\d+[\d.]*"
    r"\s*(?:构建\s*\d+|build\s*\d+|[（(]\s*(?:构建\s*|build\s*)?\d+\s*[)）])?\s*",
    re.IGNORECASE,
)
# 结尾的 issue 引用，例如「refs #107 #103」
ISSUE_SUFFIX = re.compile(r"\s*(?:refs?|closes?d?|fixe[sd]?)\s+((?:#\d+[\s,，]*)+)$", re.IGNORECASE)
ISSUE_NUMBER = re.compile(r"#\d+")
# git 自动生成的合并与回滚提交；中文提交里的「合并」多半是功能描述，不能一并挡掉
NOISE = re.compile(r"^(?:Merge |Revert )")

# 判定顺序即优先级：修复 > 新增 > 性能 > 其余归入 Changed
CATEGORY_RULES: list[tuple[str, re.Pattern[str]]] = [
    ("Fixed", re.compile(r"^(?:修复|修正|解决|fix)", re.IGNORECASE)),
    ("Added", re.compile(r"^(?:接入|引入|feat)|(?:新增|新加|增加|支持)", re.IGNORECASE)),
    ("Performance", re.compile(r"(?:性能|卡顿|提速|加速|内存占用|耗电)")),
]
CATEGORY_ORDER = ["Added", "Changed", "Fixed", "Performance"]

SECTION_HEADING = re.compile(r"^## \[([^\]]+)\]", re.MULTILINE)


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True
    ).stdout.strip()


def read_version(text: str, key: str) -> str | None:
    """取 project.yml 顶层 settings 的版本值，跳过 $(inherited) 等占位。"""
    for match in re.finditer(rf'^\s*{key}:\s*"?([^"\n]+?)"?\s*$', text, re.MULTILINE):
        value = match.group(1).strip()
        if value and "$(" not in value:
            return value
    return None


def current_version() -> tuple[str, str]:
    text = PROJECT_YML.read_text(encoding="utf-8")
    marketing = read_version(text, "MARKETING_VERSION")
    build = read_version(text, "CURRENT_PROJECT_VERSION")
    if not marketing or not build:
        sys.exit("project.yml 中找不到 MARKETING_VERSION 或 CURRENT_PROJECT_VERSION")
    return marketing, build


@functools.lru_cache(maxsize=None)
def version_at(commit: str) -> tuple[str | None, str | None]:
    try:
        text = git("show", f"{commit}:project.yml")
    except subprocess.CalledProcessError:
        return None, None
    return read_version(text, "MARKETING_VERSION"), read_version(text, "CURRENT_PROJECT_VERSION")


def timeline(head: str = "HEAD") -> list[dict]:
    """按时间从旧到新切分版本区间。

    只有版本号或构建号相对父提交发生变化的提交才算发布提交；新增源文件同样会改动
    project.yml，不能仅凭「最后一次改动 project.yml」来划界。一个版本的改动范围是
    「上一次发布提交之后」直到「本版本最后一次发布提交」。
    """
    groups: list[dict] = []
    for commit in git("log", "--format=%H", "--reverse", head, "--", "project.yml").splitlines():
        marketing, build = version_at(commit)
        if not marketing or (marketing, build) == version_at(f"{commit}~1"):
            continue
        if groups and groups[-1]["version"] == marketing:
            groups[-1]["last"] = commit
        else:
            groups.append({"version": marketing, "first": commit, "last": commit, "builds": set()})
        if build and build.isdigit():
            groups[-1]["builds"].add(int(build))
    return groups


def version_span(version: str, head: str = "HEAD") -> tuple[str | None, str, set[int]]:
    """返回该版本的 (排除起点, 终点, 构建号集合)。"""
    groups = timeline(head)
    # 历史上个别版本号被改回过，同一版本可能出现多段；以最后一段为准，构建号取并集
    indexes = [index for index, group in enumerate(groups) if group["version"] == version]
    if not indexes:
        sys.exit(f"project.yml 历史中找不到版本 {version}")
    index = indexes[-1]
    # 区间语义是「上一次发布之后到本次发布」，两端都以该版本最后一次版本号变更为界
    start = groups[index - 1]["last"] if index > 0 else None
    end = groups[index]["last"] if index + 1 < len(groups) else head
    builds: set[int] = set()
    for position in indexes:
        builds |= groups[position]["builds"]
    return start, end, builds


def format_builds(builds: set[int], fallback: str) -> str:
    if not builds:
        return fallback
    low, high = min(builds), max(builds)
    return str(low) if low == high else f"{low}-{high}"


def classify(subject: str) -> str:
    for name, pattern in CATEGORY_RULES:
        if pattern.search(subject):
            return name
    return "Changed"


def normalize(subject: str) -> tuple[str, str] | None:
    """把提交标题化为条目文本，返回 (正文, issue 后缀)；无内容时返回 None。"""
    subject = subject.strip()
    if not subject or NOISE.match(subject):
        return None

    issues = ""
    issue_match = ISSUE_SUFFIX.search(subject)
    if issue_match:
        numbers = ISSUE_NUMBER.findall(issue_match.group(1))
        issues = " (" + " ".join(dict.fromkeys(numbers)) + ")" if numbers else ""
        subject = subject[: issue_match.start()].strip()

    version_match = VERSION_PREFIX.match(subject)
    if version_match:
        subject = subject[version_match.end() :].lstrip("并，,、 ").strip()
        if len(subject) < 6:
            return None

    return (subject, issues) if subject else None


def collect(start: str | None, head: str) -> dict[str, list[str]]:
    span = f"{start}..{head}" if start else head
    entries: dict[str, list[str]] = {name: [] for name in CATEGORY_ORDER}
    seen: set[str] = set()
    for subject in git("log", "--no-merges", "--reverse", "--format=%s", span).splitlines():
        normalized = normalize(subject)
        if not normalized:
            continue
        body, issues = normalized
        if body in seen:
            continue
        seen.add(body)
        entries[classify(body)].append(f"- {body}{issues}")
    return entries


def render(version: str, builds: str, date: str, entries: dict[str, list[str]], summary: str) -> str:
    lines = [f"## [{version}] (build {builds}) - {date}", "", summary, ""]
    for name in CATEGORY_ORDER:
        if not entries[name]:
            continue
        lines += [f"### {name}", ""]
        lines += entries[name]
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def split_document(path: Path) -> tuple[str, list[tuple[str, str]]]:
    """把 CHANGELOG 拆成文件头与 [(版本号, 段落原文), ...]。"""
    text = path.read_text(encoding="utf-8")
    matches = list(SECTION_HEADING.finditer(text))
    if not matches:
        return text, []
    header = text[: matches[0].start()]
    sections: list[tuple[str, str]] = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        sections.append((match.group(1), text[match.start() : end]))
    return header, sections


def strip_trailing_rule(section: str) -> str:
    """去掉段落末尾的分隔线，只留正文。"""
    return re.sub(r"\n+---\s*\n*$", "\n", section).rstrip() + "\n"


def cmd_version(_: argparse.Namespace) -> None:
    marketing, build = current_version()
    print(f"marketing={marketing}")
    print(f"build={build}")


def cmd_draft(args: argparse.Namespace) -> None:
    marketing, build = current_version()
    version = args.version or marketing
    start, end, builds = version_span(version, args.head)
    if args.since:
        start = args.since
    if args.end:
        end = args.end

    entries = collect(start, end)
    total = sum(len(items) for items in entries.values())
    if total == 0 and not args.allow_empty:
        sys.exit(f"{start or '仓库起点'}..{end} 之间没有可写入更新日志的提交")

    section_builds = args.builds or format_builds(builds, build if version == marketing else "?")
    date = args.date or git("log", "-1", "--format=%cs", end)
    summary = args.summary or f"本版本包含 {total} 项改动。"
    section = render(version, section_builds, date, entries, summary)
    if args.output:
        Path(args.output).write_text(section, encoding="utf-8")
    else:
        sys.stdout.write(section)


def cmd_versions(args: argparse.Namespace) -> None:
    documented = {name for name, _ in split_document(CHANGELOG_ZH)[1]} if CHANGELOG_ZH.exists() else set()
    for group in reversed(timeline()):
        version = group["version"]
        if args.missing and version in documented:
            continue
        mark = " " if version in documented else "*"
        date = git("log", "-1", "--format=%cs", group["last"])
        print(f'{mark} {version:<8} build {format_builds(group["builds"], "?"):<8} {date}')


def cmd_is_bump(args: argparse.Namespace) -> None:
    """判断某个提交是否改动了版本号或构建号，供发布流程决定是否继续。"""
    print("true" if version_at(args.commit) != version_at(f"{args.commit}~1") else "false")


def cmd_sanitize(args: argparse.Namespace) -> None:
    """校正模型输出：剥掉代码围栏与前言，并以参照段落的标题行为准。"""
    raw = Path(args.file).read_text(encoding="utf-8") if Path(args.file).exists() else ""
    body = re.sub(r"^\s*```[a-zA-Z]*\s*\n", "", raw)
    body = re.sub(r"\n\s*```\s*$", "\n", body).strip()

    reference = Path(args.reference).read_text(encoding="utf-8")
    reference_heading = SECTION_HEADING.search(reference)
    if not reference_heading:
        sys.exit(f"参照文件 {args.reference} 里没有版本标题行")
    heading_line = reference.splitlines()[reference[: reference_heading.start()].count("\n")]

    heading = SECTION_HEADING.search(body)
    if heading:
        body = body[heading.start() :]
        body = body.split("\n", 1)[1] if "\n" in body else ""
    section = f"{heading_line}\n{body}".rstrip() + "\n"

    # 模型偶尔会回成一句解释或空串，这种结果不可用，交回调用方回退到草稿
    if not re.search(r"^### \w", section, re.MULTILINE) or not re.search(r"^- \S", section, re.MULTILINE):
        sys.exit("模型输出不是可用的更新日志段落")

    Path(args.output).write_text(section, encoding="utf-8")
    print(f"已生成 {args.output}")


def cmd_apply(args: argparse.Namespace) -> None:
    path = CHANGELOG_EN if args.lang == "en" else CHANGELOG_ZH
    section = strip_trailing_rule(Path(args.section).read_text(encoding="utf-8"))
    version = args.version or SECTION_HEADING.match(section).group(1)

    header, sections = split_document(path)
    rebuilt = [f"{section}\n---\n\n" if name == version else body for name, body in sections]
    if not any(name == version for name, _ in sections):
        rebuilt.insert(0, f"{section}\n---\n\n")

    path.write_text(header + "".join(rebuilt), encoding="utf-8")
    print(f"已写入 {path.name} 的 {version} 段落")


def cmd_extract(args: argparse.Namespace) -> None:
    path = CHANGELOG_EN if args.lang == "en" else CHANGELOG_ZH
    if not path.exists():
        sys.exit(f"{path.name} 不存在")
    for name, body in split_document(path)[1]:
        if name == args.version:
            body = strip_trailing_rule(body)
            if args.without_heading:
                body = body.split("\n", 1)[1].lstrip("\n") if "\n" in body else ""
            if args.output:
                Path(args.output).write_text(body, encoding="utf-8")
            else:
                sys.stdout.write(body)
            return
    sys.exit(f"{path.name} 中没有 {args.version} 段落")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("version", help="输出当前版本号与构建号").set_defaults(func=cmd_version)

    versions = sub.add_parser("versions", help="列出 project.yml 历史中的版本区间")
    versions.add_argument("--missing", action="store_true", help="只列出尚未写进 CHANGELOG.md 的版本")
    versions.set_defaults(func=cmd_versions)

    draft = sub.add_parser("draft", help="生成更新日志草稿")
    draft.add_argument("--version", help="版本号，默认取 project.yml")
    draft.add_argument("--build", help="构建号，默认取 project.yml")
    draft.add_argument("--builds", help="标题中的构建号区间，默认按版本区间推导")
    draft.add_argument("--since", help="提交范围的排除起点，默认按版本号变更推导")
    draft.add_argument("--head", default="HEAD", help="推导版本区间时的历史终点，默认 HEAD")
    draft.add_argument("--end", help="提交范围的终点，默认按版本区间推导")
    draft.add_argument("--date", help="发布日期，默认今天")
    draft.add_argument("--summary", help="概述句，默认按改动条数生成")
    draft.add_argument("--output", help="写入文件，默认输出到标准输出")
    draft.add_argument("--allow-empty", action="store_true", help="没有提交时也生成空段落")
    draft.set_defaults(func=cmd_draft)

    apply_cmd = sub.add_parser("apply", help="把段落写入 CHANGELOG")
    apply_cmd.add_argument("section", help="段落文件路径")
    apply_cmd.add_argument("--lang", choices=["zh", "en"], default="zh")
    apply_cmd.add_argument("--version", help="版本号，默认从段落标题解析")
    apply_cmd.set_defaults(func=cmd_apply)

    is_bump = sub.add_parser("is-bump", help="判断提交是否改动了版本号或构建号")
    is_bump.add_argument("commit", nargs="?", default="HEAD")
    is_bump.set_defaults(func=cmd_is_bump)

    sanitize = sub.add_parser("sanitize", help="校正模型输出的段落格式")
    sanitize.add_argument("file", help="模型输出文件")
    sanitize.add_argument("--reference", required=True, help="提供标题行的参照段落")
    sanitize.add_argument("--output", required=True, help="写入的目标文件")
    sanitize.set_defaults(func=cmd_sanitize)

    extract = sub.add_parser("extract", help="取出指定版本的段落")
    extract.add_argument("version")
    extract.add_argument("--lang", choices=["zh", "en"], default="zh")
    extract.add_argument("--without-heading", action="store_true", help="去掉 ## 标题行")
    extract.add_argument("--output", help="写入文件，默认输出到标准输出")
    extract.set_defaults(func=cmd_extract)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
