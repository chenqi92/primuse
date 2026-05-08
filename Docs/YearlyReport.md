# Primuse 年度音乐报告 — 设计与开发文档

> 类似 Spotify Wrapped / Apple Music Replay / 网易云年度听歌报告 / 支付宝年度账单。
>
> 本文档同时作为：① 工程实现规范，② 美术插图绘制需求清单。

---

## 目录

- [一、总体设计](#一总体设计)
- [二、数据来源与归档机制](#二数据来源与归档机制)
- [三、卡片清单（12 张）](#三卡片清单12-张)
- [四、音乐人格 16 型](#四音乐人格-16-型)
- [五、插图绘制需求清单 ⭐](#五插图绘制需求清单-)
- [六、风格约束](#六风格约束)
- [七、文件命名规范](#七文件命名规范)
- [八、技术实现要点](#八技术实现要点)
- [九、占位渲染（插图缺失时）](#九占位渲染插图缺失时)

---

## 一、总体设计

### 形态

类 Stories 的横滑卡片浏览器，**12 张卡片**串成一个完整的年度故事。每张卡片：

- 全屏占用（顶到底）
- 顶部进度条（12 个 segment，类似 Instagram Stories）
- 自动播放（5-7s 一张），点击屏幕左 / 右翻页
- 长按暂停
- 右上角 X 退出，分享按钮在每张卡片右下角

### 故事节奏

```
开场（封面）→ 总览数据 → 第一首歌（怀旧）→
  Top 排行（高潮）→ 专属时刻（成就感）→
  时段画像（自我认知）→ 音乐人格（高潮再起）→
  音乐源 / 月份（细节）→ 年终感言（落幕）
```

### 入口

- **主入口**：Stats（听歌统计）页顶部，时间敏感入口
- **触发提示**：1/1 - 1/31 期间在 Library / Home 加显眼 banner "你的 N 年度报告已生成"
- **平时**：藏在 Stats 页右上角小图标，不打扰非节庆场景

---

## 二、数据来源与归档机制

### 现状

- `PlayHistoryStore` 本地 JSON, 上限 5000 条 FIFO evict
- 每条 `Entry` 含 `songID, title, artist, album, playedAt, listenedSec, sourceID`
- 跨设备 **不同步**（之前的设计选择，保护隐私）

### 跨年风险

5000 条上限，重度听歌用户半年就满，老数据会被裁。**不归档则跨年报告早期月份缺数据**。

### 归档策略

- 文件位置：`Application Support/Primuse/yearly-archives/year-<YYYY>.json`
- 触发时机：
  1. App 启动时检测：若上次启动年份 < 当前年份 → 归档上一年
  2. 12 月 28 日后任何启动都触发一次预归档（防止 12/31 用户没开 app）
- 归档内容：把 entries 按年份分组，写入对应文件
- 报告读取：`year-2026.json` 优先，没有 archive 才读 live entries

### 归档文件格式

```json
{
  "year": 2026,
  "entries": [...],          // 同 PlayHistoryStore.Entry 结构
  "archivedAt": "2026-12-31T16:00:00Z"
}
```

---

## 三、卡片清单（12 张）

每张包含：**数据 / 文案 / 视觉布局 / 插图位**。

| # | 卡名 | 数据来源 | 关键文案 |
|---|---|---|---|
| 1 | 封面 / Hero | 当前年 + 人格名 | "你的 2026 音乐报告" |
| 2 | 总览 | 总秒数 / 歌数 / 艺术家数 / 同比 | "今年你听了 X 小时" |
| 3 | 首播之歌 | 全年第一条 entry | "你的 2026 是从这首歌开始的" |
| 4 | Top 艺术家 (No.1) | groupBy artist, 取 No.1 | "你最爱的是 X" |
| 5 | Top 艺术家 (2-5) | 同上, 取 2-5 | "另外 4 位常驻" |
| 6 | Top 歌曲 | groupBy song, Top 10 | "你今年的循环榜" |
| 7 | 专属时刻 | 单歌最多次 / 最长连听 / 最晚一次 | "你的高光时刻" |
| 8 | 时段画像 | 24h 分布 + 主导时段 | "你最常在 X 点听音乐" |
| 9 | 音乐人格 | 4 维度 → 16 型映射 | "你是 [人格名]" |
| 10 | 音乐源画像 | groupBy sourceID | "X% 来自 NAS / 云端 / 本地" |
| 11 | 代表月份 | groupBy month, 取 max | "X 月是你的音乐月" |
| 12 | 年终感言 | 总秒数感谢句 | "感谢你今年与音乐 X 小时" |

---

## 四、音乐人格 16 型

按 **4 个维度** 二值化分类，类似 MBTI。

### 维度定义

| 维度 | 字母 | 极端 A | 极端 B | 算法 |
|---|---|---|---|---|
| 探索 vs 死忠 | **E / L** | E (Explorer) | L (Loyalist) | Top 5 艺术家累计听歌占比 < 35% → E，否则 L |
| 杂食 vs 专精 | **O / F** | O (Omnivore) | F (Focus) | 不同 genre 数 ≥ 6 → O，否则 F |
| 追新 vs 怀旧 | **N / V** | N (New) | V (Vintage) | year 中位数 ≥ (currentYear - 5) → N，否则 V |
| 昼伏 vs 夜行 | **D / M** | D (Day) | M (Moon) | 18:00-06:00 时段播放占比 > 55% → M |

### 16 种组合（必读，每一种对应一张插图）

| 代码 | 中文名 | 英文名 | 一句话画像 |
|---|---|---|---|
| **EOND** | 城市漫游者 | Urban Wanderer | 白天什么风格的新歌都听一耳朵，停不下来探索 |
| **EONM** | 夜行探险家 | Night Explorer | 深夜耳机里永远是新发现，听过的就翻篇 |
| **EOVD** | 复古拓荒人 | Vintage Pioneer | 白天挖掘各种老歌冷门曲，每首都新鲜 |
| **EOVM** | 月光档案员 | Moonlit Archivist | 深夜在年代灰尘里淘宝，杂食且嗜旧 |
| **EFND** | 阳光浪客 | Daylight Drifter | 一种风格里挑各种新歌，白天听 |
| **EFNM** | 暗夜浪客 | Nightfall Drifter | 一种风格里挑各种新歌，深夜听 |
| **EFVD** | 怀旧浪客 | Sunlit Reminiscer | 守一种老风格，白天里轻盈漫步 |
| **EFVM** | 黑胶夜游 | Vinyl Nightowl | 守一种老风格，深夜独酌 |
| **LOND** | 阳光博物者 | Sunny Eclectic | 围绕几个偏爱艺术家但风格多元，新歌为主，白天听 |
| **LONM** | 午夜博物者 | Midnight Eclectic | 同上，深夜版 |
| **LOVD** | 故纸学究 | Daylight Scholar | 几个老艺术家循环到死，白天的图书馆感 |
| **LOVM** | 月下守夜人 | Midnight Devotee | 几个老艺术家循环到死，深夜守候 |
| **LFND** | 阳光专一派 | Daylight Devotee | 死忠少数艺术家 + 单一风格 + 新歌 + 白天 |
| **LFNM** | 月夜专一派 | Moonlight Devotee | 死忠 + 单一 + 新歌 + 深夜 |
| **LFVD** | 复古铁粉 | Daylight Loyalist | 死忠 + 单一 + 老歌 + 白天 |
| **LFVM** | 黑胶守夜人 | Vinyl Devotee | 死忠 + 单一 + 老歌 + 深夜 |

> 名字偏文艺方向。如果你想偏搞笑（"凌晨三点的牛马打工人"），告诉我重写。

---

## 五、插图绘制需求清单 ⭐

> **这部分是给绘图的**。所有插图遵循 [§六 风格约束](#六风格约束)。
>
> 每张图都要：透明背景 PNG / 主体居中 / 不带文字 / 三个分辨率（@1x @2x @3x）。

### 5.1 核心刚需（**必须完整**）

#### 5.1.1 16 种音乐人格（16 张）

| 文件名 | 人格 | 主体描述（需画的内容） | 调性 |
|---|---|---|---|
| `personality_EOND.png` | 城市漫游者 | 一个戴耳机的人，背着小背包在霓虹街道上行走，脚步轻快，多种音乐符号从耳机散开（流行/电子/民谣等不同符号） | 明亮、好奇、阳光 |
| `personality_EONM.png` | 夜行探险家 | 月光下戴耳机的人，前方一片星空 + 不同的音乐风格图标如星座般散开 | 神秘、探索、深邃 |
| `personality_EOVD.png` | 复古拓荒人 | 阳光下，一人在老唱片货架前翻找，戴老式耳机，背景是一架架黑胶 | 古朴、阳光、好奇 |
| `personality_EOVM.png` | 月光档案员 | 深夜书房，一人在灯下整理黑胶档案，窗外月亮 | 内敛、博识、夜深 |
| `personality_EFND.png` | 阳光浪客 | 阳光草地，戴耳机的少年躺着，云彩里飘出几个相似的音符（同色系） | 自由、惬意、白昼 |
| `personality_EFNM.png` | 暗夜浪客 | 城市天台，戴耳机的人靠栏杆远眺，霓虹倒影在地上 | 夜色、孤独感、自由 |
| `personality_EFVD.png` | 怀旧浪客 | 复古咖啡馆，阳光透过窗，耳机老式磁带 | 怀旧、温暖、白昼 |
| `personality_EFVM.png` | 黑胶夜游 | 深夜小酒馆桌上，黑胶机在转，耳机一杯酒 | 复古、夜深、孤酌 |
| `personality_LOND.png` | 阳光博物者 | 阳光房，几本不同风格的乐谱叠在桌上，耳机和咖啡 | 杂学、阳光 |
| `personality_LONM.png` | 午夜博物者 | 深夜书桌，多种音乐 CD 散开，台灯光晕 | 杂学、夜深 |
| `personality_LOVD.png` | 故纸学究 | 阳光下的图书馆角落，一摞古旧黑胶 + 老式耳机 + 戴眼镜的人侧脸 | 学术、古朴、白昼 |
| `personality_LOVM.png` | 月下守夜人 | 月夜阁楼，独坐听老唱片机，旁边几本旧书 | 守夜、忠诚、神秘 |
| `personality_LFND.png` | 阳光专一派 | 阳光下举着一张专辑封面（无具体内容，纯白唱片）的人，单一色调 | 专一、明朗 |
| `personality_LFNM.png` | 月夜专一派 | 深夜坐在窗台抱着一张专辑，月光打在脸上 | 专一、深情、夜 |
| `personality_LFVD.png` | 复古铁粉 | 阳光下穿复古衫举着旧式磁带 | 怀旧、忠诚、白昼 |
| `personality_LFVM.png` | 黑胶守夜人 | 月夜烛光，黑胶机正缓缓转动，一个人闭眼聆听 | 守夜、虔诚、深邃 |

**尺寸**：840 × 840 px（@3x，对应 280 × 280pt）。圆形或矩形构图都行，但主体集中在中央 280×280 区域内（边缘 30px 留 padding）。

#### 5.1.2 4 个时段插图（4 张）

每张表示一个时段，用于"时段画像"卡片背景 + 人格卡的辅助元素。

| 文件名 | 时段 | 主体描述 |
|---|---|---|
| `timeofday_dawn.png` | 清晨 (5-9 时) | 日出地平线，一束橙红光，远处剪影房屋 / 树 |
| `timeofday_noon.png` | 正午 (10-14 时) | 蓝天白云 + 太阳直射 / 城市轮廓 |
| `timeofday_dusk.png` | 黄昏 (15-18 时) | 落日金黄 + 紫色天空 + 城市远景 |
| `timeofday_night.png` | 深夜 (19-4 时) | 星空 + 月亮 + 城市灯光 |

**尺寸**：960 × 360 px（@3x，对应 320 × 120pt 横幅）。

#### 5.1.3 12 个月份插图（12 张）

| 文件名 | 月份 | 主题（中国语境） |
|---|---|---|
| `month_01.png` | 一月 | 雪 / 冬日 / 新年灯笼 |
| `month_02.png` | 二月 | 红梅 / 春节 / 鞭炮 |
| `month_03.png` | 三月 | 樱花 / 春耕 / 嫩绿 |
| `month_04.png` | 四月 | 杨柳依依 / 雨水 |
| `month_05.png` | 五月 | 麦田 / 假日出游 |
| `month_06.png` | 六月 | 夏雨 / 龙舟 |
| `month_07.png` | 七月 | 暑天 / 西瓜 / 海边 |
| `month_08.png` | 八月 | 烟花 / 夏夜 / 萤火虫 |
| `month_09.png` | 九月 | 秋桂 / 月饼 / 秋月 |
| `month_10.png` | 十月 | 红叶 / 国庆 / 收割 |
| `month_11.png` | 十一月 | 落叶 / 秋深 / 围炉 |
| `month_12.png` | 十二月 | 雪花 / 圣诞 / 灯火 |

**尺寸**：1242 × 600 px（@3x，对应全宽 ×200pt 横幅）。

> 中国语境优先（春节、月饼、雪），不是日历语境。如果你想要更通用一些（去节日符号），告诉我。

### 5.2 装饰元素（**建议都画**, 不画 UI 用占位兜底）

| 文件名 | 用途 | 主体描述 | 尺寸（@3x） |
|---|---|---|---|
| `decor_overview_hourglass.png` | 总览卡 | 沙漏，里面流的是音符 | 600 × 600 |
| `decor_first_song.png` | 首播卡 | 老电影开场打板 / 序幕字样的图形元素 | 540 × 720 |
| `decor_trophy.png` | Top 艺术家 No.1 卡 | 唱片造型的奖杯 | 720 × 720 |
| `decor_artists_chorus.png` | Top 艺术家 2-5 卡 | 4 个不同身形 / 不同乐器姿态的艺术家剪影并排（合唱团/乐队感），保持抽象不要细节五官 | 600 × 360 |
| `decor_record_stack.png` | Top 歌曲（循环榜）卡 | 一摞黑胶 / CD 堆积 | 600 × 960 |
| `decor_badge_moment.png` | 专属时刻卡 | 勋章 / 徽章造型 | 720 × 720 |
| `decor_sources_pipeline.png` | 音乐源画像卡 | 多个源（NAS 盒、云朵、手机）通过几条流动的"音乐线"汇聚到中央，体现"音乐从哪儿来" | 660 × 330 |
| `decor_source_nas.png` | 音乐源（备用）| NAS 盒子 / 服务器图标 | 540 × 540 |
| `decor_source_cloud.png` | 音乐源（备用）| 云朵图形 | 540 × 540 |
| `decor_source_local.png` | 音乐源（备用）| 手机 / 本地存储图形 | 540 × 540 |
| `decor_curtain_close.png` | 年终感言卡 | 落幕的舞台帷幕 / 谢幕字 | 1242 × 660 |

---

## 六、风格约束

> **所有 41 张图共用同一套视觉语言。** 这是确保 12 张卡滑过去时不"撞风格"的唯一手段。

### 必须遵守

- **风格类别**：**扁平卡通插画**（Apple Health / Spotify Wrapped 同类型）
  - 几何感强但保留手绘笔触
  - 不要写实 / 不要 3D 渲染 / 不要像素风
- **色彩**：
  - **主色一：** 跟 app `accentColor`（紫蓝调）协调，可以用其变体
  - **主色二：** 暖橙 / 米黄做对比
  - **辅助：** 白 / 灰 / 黑 / 浅蓝
  - 单张图主色不超过 4 个，全套图色板尽量一致
- **背景**：**纯透明 PNG**。背景色由 app 渐变层提供，不要画背景
- **不带文字**：所有图都不要带任何字，文案由 app 加
- **主体居中**：每张图中心 80% 区域是主体，外圈 20% padding
- **线条粗细统一**：所有图用同一支"笔"
- **人物面部**：抽象（点 + 线 + 圆，类似 Toca Boca / 知乎插画风），不要细节五官

### 强烈建议

- **氛围 / 情绪** > **细节准确**。例如"夜行探险家"画一个抬头看星空的剪影就够了，不需要画清晰人脸
- 多用**留白**，宁缺勿满
- 元素少，构图简单，**远观能一眼看懂**
- 16 种人格之间应有明显区分（颜色 / 主体姿态），不要看着像同一张图

### 禁止

- ❌ 知名 IP / 明星脸（版权）
- ❌ 现代 logo / 品牌（Apple / Spotify / 任何耳机品牌）
- ❌ 文字（除了图形元素里抽象的字符笔触）
- ❌ 任何人物细致的脸部表情（统一用抽象表达）

---

## 七、文件命名规范

```
插图资源放在: Primuse/Resources/Assets.xcassets/YearlyReport/

人格:    personality_<CODE>.imageset/
         personality_<CODE>.png
         personality_<CODE>@2x.png
         personality_<CODE>@3x.png

时段:    timeofday_<dawn|noon|dusk|night>.imageset/...
月份:    month_<01..12>.imageset/...
装饰:    decor_<name>.imageset/...
```

CODE 严格匹配 [§四 16 型表](#四音乐人格-16-型) 第一列（4 个大写字母，例 `EOND`）。

---

## 八、技术实现要点

### 模块拆分

```
Primuse/Services/Stats/
├── PlayHistoryArchiver.swift      // 年度归档
├── YearlyReportAnalyzer.swift     // 数据派生
└── MusicPersonality.swift         // 16 型枚举 + 判定

Primuse/Views/YearlyReport/
├── YearlyReportView.swift         // 主容器（横滑 / 进度条）
├── YearlyReportData.swift         // ViewModel
├── Cards/
│   ├── HeroCard.swift
│   ├── OverviewCard.swift
│   ├── FirstSongCard.swift
│   ├── TopArtistHeroCard.swift
│   ├── TopArtistsListCard.swift
│   ├── TopSongsCard.swift
│   ├── MomentsCard.swift
│   ├── TimeOfDayCard.swift
│   ├── PersonalityCard.swift
│   ├── SourcesCard.swift
│   ├── PeakMonthCard.swift
│   └── ClosingCard.swift
└── ShareImageRenderer.swift       // 分享生成 PNG
```

### 关键算法

```swift
// 人格判定
struct MusicPersonality {
    enum Exploration { case explorer, loyalist }   // E / L
    enum Diversity   { case omnivore, focused }    // O / F
    enum Recency     { case new, vintage }         // N / V
    enum DayCycle    { case day, moon }            // D / M

    // 4 维度 → 16 个 case 的查表
    var code: String { ... }     // "EOND"
    var name: LocalizedStringKey // 中文名 / 英文名

    static func from(stats: YearlyStats) -> MusicPersonality { ... }
}
```

### 性能

- 所有派生在 `Task.detached` 后台算（1w 条 entries × 12 个指标也就 < 100ms）
- 进入页前 prepare 一次，缓存到 ViewModel
- 卡片切换时只 swap 数据，不重新分析

### 触发逻辑

- App 启动时 `PlayHistoryArchiver.runIfNeeded()`：
  - 检查 `lastArchivedYear` UserDefaults
  - 若 < currentYear - 1 → 归档每个缺失的年
- 12/28+ 启动 → 预归档当前年

---

## 九、占位渲染（插图缺失时）

美术阶段插图未到位时，UI 不能空。每张缺失的图用：

```
RoundedRectangle(cornerRadius: 16)
    .fill(LinearGradient(...))
    .overlay(
        VStack {
            Image(systemName: <相关 SF Symbol>)
                .font(.system(size: 60))
            Text(<人格 CODE / 月份 / 时段名>)
                .font(.title2.weight(.bold))
        }
        .foregroundStyle(.white)
    )
```

每张占位的 fallback：

| 类别 | 颜色 | SF Symbol | 文字 |
|---|---|---|---|
| 人格 | accentColor + 紫 | `person.fill` | "EOND" |
| 时段 | 对应时段色 | `sun.max` / `moon.fill` | "正午" / "深夜" |
| 月份 | 12 季节色 | `calendar` | "10 月" |
| 装饰 | 灰 | `square.dashed` | "TODO" |

代码端检查 `UIImage(named: assetName) != nil` 决定走真插图还是占位。

---

## 十、决策点（待你确认）

| 项 | 默认选择 | 你可改 |
|---|---|---|
| 报告范围 | 自然年（1/1-12/31） | 改"最近 365 天" |
| 人格风格 | 偏文艺 | 改偏搞笑 |
| 月份语境 | 中国（春节 / 月饼 / 西瓜） | 改通用季节 |
| 跨设备聚合 | 不同步（保隐私） | 加 iCloud sync toggle |
| 插图风格 | 扁平卡通插画 | 改半立体 / 复古海报 |

---

**最后更新**：2026-05-07
