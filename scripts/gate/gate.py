#!/usr/bin/env python3
"""架构关卡：一条命令检查本仓库定下的架构规则（规则说明见 AGENTS.md 与 Docs/ARCHITECTURE.md）。

    python3 -I scripts/gate/gate.py                 查整个工作区
    python3 -I scripts/gate/gate.py --staged        提交前只查暂存的改动
    python3 -I scripts/gate/gate.py --range A..B    查一段提交范围（CI、pre-push）
    python3 -I scripts/gate/gate.py --help          全部用法

只用 Python 标准库（3.9 起），只读文件、只跑 git 的只读命令；仓库里的代码一律不执行。
项目相关的路径、阈值和名单都在旁边的 gate.config.json 里。
"""
import os
import sys

sys.dont_write_bytecode = True  # 钩子和 CI 不在仓库里留下 __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gatelib import cli  # noqa: E402

if __name__ == "__main__":
    sys.exit(cli.main(sys.argv[1:]))
