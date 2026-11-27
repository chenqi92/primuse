# 给在本仓库工作的人和 AI 代理

规则的全文与理由在 [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md)，跨端交付与大曲库内存纪律的细则在 [Docs/AGENTS.md](Docs/AGENTS.md)。这里只写每次都要做的事。

## 架构关卡

`scripts/gate/gate.py` 用一条命令检查这些规则，提交钩子、推送钩子和 GitHub 上的拉取请求检查跑的都是它。只用 Python 标准库，只读文件。

- 提交前：`python3 -I scripts/gate/gate.py`（整个工作区，约 10–25 秒）；只看暂存的改动用 `--staged`。
- 装钩子（每个检出一次）：`sh scripts/install-git-hooks.sh`。之后 pre-commit 查暂存的改动，commit-msg 查提交信息，pre-push 查要推送的提交。
- 规则清单：`python3 -I scripts/gate/gate.py --list-rules`；规则本身的自检：`--self-test`。
- 配置（路径、阈值、名单、每条规则是错误还是警告）在 `scripts/gate/gate.config.json`，基线在 `scripts/gate/baselines/` 和 `scripts/library-scale-baseline.tsv`。

## 最常被违反的几条

1. 新的 Swift 文件不超过 1,000 行；已经超过的大文件记在基线里，只许变短。新代码放进新文件，大类型的扩展按职责拆成 `类型+职责.swift`。
2. `@Observable` 类的类体只放实例存储属性、指定初始化方法和 `deinit`；方法、计算属性、嵌套类型、类型别名、静态属性写在紧随其后的同文件 `extension` 里。
3. 不新建整库规模的内存结构（`[Song]`、整库字典、整库 id 集合）。整范围用行号列表或在主线程外流式遍历，物化要有上限；曲库表的 SQL 只写在 `PrimuseKit/Sources/PrimuseKit/Catalog/`。
4. `PrimuseKit/Sources` 不导入 SwiftUI、UIKit、AppKit；Kit 的文件放进领域子目录，测试目录与源目录镜像。
5. 不手改 `Primuse.xcodeproj`：改 `project.yml`，在构建机上用 XcodeGen 2.46.0 重新生成（`xcodegen generate --spec project.yml`）。新加或删掉 Swift 文件之后不重新生成，关卡会报。
6. 测试和它覆盖的代码在同一个提交里；只改测试的提交会被拦下。
7. 提交信息一行中文，说明对用户或对 App 改了什么，有议题时结尾写 `refs #NNN`；至多再空一行补一句短话。验证证据写进交接文档，不写进提交。
8. 提交信息、代码注释和拉取请求里不写 AI 署名：不加 `Co-Authored-By` AI、`Generated with …`、会话链接或机器人标记。功能描述里出现产品名（例如接入某个 AI 接口）不算署名。

## 关卡没通过时

- 按每条发现后面的「改法」修代码，再跑一遍。不要用 `git commit --no-verify` 或 `git push --no-verify` 跳过。
- 基线只许收紧：代码改好、命中变少之后运行 `python3 -I scripts/gate/gate.py --update-baseline`，把收紧的基线和代码一起提交。
- 不要为了通过而放宽基线、改阈值或把规则改成警告。确实需要放宽时停下来问仓库所有者；放宽由所有者在 main 上用 `--update-baseline --allow-growth "理由"` 做，理由会记进基线文件。拉取请求里的基线放宽一律不通过。
- `SKIPPED` 表示本机缺少那条检查要的工具（例如 Ruby、XcodeGen、plutil 只在构建机上有），不是通过；在报告里如实写「没有验证」。
