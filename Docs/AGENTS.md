# 跨端功能交付

- 修改卡拉OK等手机与 Apple TV 各有独立会话、界面或播放路径的功能时，先核对两端的对应实现；共享算法的更新不等于电视会话和界面已经接入。
- 卡拉OK功能记录维护在 [KARAOKE.md](KARAOKE.md)。新增、变更或暂缓一端功能时，同批更新平台状态、限制及待验证项。
- 这类功能记录、QA 与说明文档一律放在 `Docs/` 下；`Docs/` 在 .gitignore 里，新建的文档不纳入 Git 跟踪，只有已跟踪的文档继续随提交更新。
- 交付必须单独说明 Apple TV 做了什么、未做什么及原因；编译、本地化或算法测试通过不能替代跨端功能覆盖与实际界面验证。

# 大曲库内存纪律

- 曲库数据以 `library-catalog.sqlite`（`PrimuseKit/Sources/PrimuseKit/Catalog/`）为准，内存里只留有界的窗口与缓存。新代码不新建整库规模的 `[Song]`、`[String: Song]` 或整库 id 集合：整范围用 `LibraryRowList` 行号列表或在主线程外流式遍历，物化 `Song` 必须带上限（`LibraryScale.maxMaterializedRows`，5000）。
- 读曲库走 `LibraryCatalogReader`、`LibraryListModel`、按 id 取和目录计数。`visibleSongs`、`musicSongs`、`spokenWordSongs`、`visibleAlbums`、`visibleArtists`、`library.songs`、`visibleSongLookup` 等整库接口会被删除，不要新增调用。
- 目录表（`song`、`album`、`artist`、`folder` 等）以及旧歌曲库 `librarySongRecords` 的 SQL 只写在 `PrimuseKit/Sources/PrimuseKit/Catalog/` 里，别处通过目录接口读写。
- 曲库以外随歌曲数增长的常驻状态（扫描索引、补全状态、离线状态、文件夹索引、排序缓存）放 SQLite 表或映射文件，不放内存字典；退到后台时只保留正在播放的封面。
- `scripts/check-crash-patterns.py` 在编译机每次编译前运行，其中四条规则守着这几条纪律：`library-array-property`、`song-id-collection-property`、`catalog-sql-outside-catalog`、`legacy-library-api`。迁移期间它们按棘轮执行：现有命中按文件记在 `scripts/library-scale-baseline.tsv`，某个文件的命中数超过基线就失败。确有上界的属性在同一行或上一行写 `// crash-pattern: allow <规则> <上界与理由>`。命中减少后运行 `python3 -I scripts/check-crash-patterns.py --update-baseline` 收紧基线，基线只许减少。测试目录不检查。
- 规模预算：曲库目录规模门 `LibraryCatalogScaleTests` 单独成包 `PrimuseKit/ScaleGate/`（只编 PrimuseKit、GRDB 和这一组），编译机每次跑 Kit 单测时在 Debug 全量之后单跑一次 Release（10 万首）：在 `PrimuseKit/ScaleGate` 目录里 `swift test -c release -Xswiftc -enable-testing --no-parallel`。`PrimuseKit` 目录里的 `swift test` 不再包含这一组；要看 Debug 下的数字，在 `PrimuseKit/ScaleGate` 里不带 `-c release` 跑（迁移时长只在优化编译里判失败）。全量验收设 `PRIMUSE_CATALOG_SCALE_SONGS=500000`。预算常量集中在 `PrimuseKit/ScaleGate/Tests/ScaleGateTests/LibraryCatalogScaleBudgets.swift`，调整时要写明理由。合成曲库、进程测量和 `CatalogTestRandom` 只有一份，在 `PrimuseKit/Tests/PrimuseKitTests/Support/`，规模门经 `Tests/ScaleGateTests/Shared/` 下的相对符号链接编它们；`LibraryFolderCatalogScaleTests` 留在 PrimuseKitTests 的 Debug 全量里。App 侧大库常驻内存用 `PrimuseTests/LibraryStartupHarnessTests` 的规模夹具测量：先设 `TEST_RUNNER_PRIMUSE_SCALE_DIR` 和 `TEST_RUNNER_PRIMUSE_SCALE_SONGS`，运行 `testBuildScaleFixture`，再运行 `testScaleFixtureFootprint`。
