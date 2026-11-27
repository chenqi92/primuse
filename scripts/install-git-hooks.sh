#!/bin/sh
# 把仓库里跟踪的 scripts/git-hooks 设为当前检出的 git 钩子目录（core.hooksPath，只写本检出的 .git/config）。
# 可以重复运行；已经有别的 core.hooksPath 时不覆盖，除非加 --force。
# 撤销：git config --local --unset core.hooksPath
set -eu

force=0
case "${1:-}" in
  --force) force=1 ;;
  "") ;;
  *) echo "用法：sh scripts/install-git-hooks.sh [--force]" >&2; exit 2 ;;
esac

root=$(git rev-parse --show-toplevel)
want="scripts/git-hooks"
hooks="$root/$want"
[ -d "$hooks" ] || { echo "找不到 $hooks，这个检出里还没有关卡的钩子。" >&2; exit 1; }
for hook in pre-commit commit-msg pre-push; do
  if [ ! -x "$hooks/$hook" ]; then
    echo "$want/$hook 没有执行权限，git 不会运行它。检出时应当带着 755；可以运行 chmod +x $want/$hook" >&2
    exit 1
  fi
done

current=$(git -C "$root" config --local --get core.hooksPath || true)
if [ "$current" = "$want" ]; then
  echo "已经装好：$root 的 core.hooksPath = $want（pre-commit、commit-msg、pre-push）。"
  exit 0
fi
if [ -n "$current" ] && [ "$force" -ne 1 ]; then
  echo "这个检出的 core.hooksPath 已经是 $current，没有覆盖。确认不再需要那里的钩子后加 --force 重跑。" >&2
  exit 1
fi

old_hooks="$(git -C "$root" rev-parse --git-common-dir)/hooks"
case "$old_hooks" in /*) ;; *) old_hooks="$root/$old_hooks" ;; esac
if [ -d "$old_hooks" ]; then
  others=$(find "$old_hooks" -maxdepth 1 -type f -perm -u+x ! -name '*.sample' -exec basename {} \; 2>/dev/null | sort | tr '\n' ' ')
  if [ -n "$others" ]; then
    echo "注意：$old_hooks 里的这些钩子之后不再运行：$others"
  fi
fi
global=$(git config --global --get core.hooksPath || true)
if [ -n "$global" ]; then
  echo "注意：全局 core.hooksPath 是 $global，这个检出改用本仓库的钩子。"
fi

git -C "$root" config --local core.hooksPath "$want"
if [ -n "$current" ]; then
  echo "已把 $root 的 core.hooksPath 从 $current 改成 $want。"
else
  echo "已设置 $root 的 core.hooksPath = $want。"
fi
echo "之后每次提交查暂存的改动和提交信息，每次推送查要推送的提交。撤销：git config --local --unset core.hooksPath"
