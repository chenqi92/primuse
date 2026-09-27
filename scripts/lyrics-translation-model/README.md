# 离线歌词翻译模型（英语 ↔ 波斯语）

Apple 翻译框架不支持波斯语（#48）。这里的模型补上英语 ↔ 波斯语两个方向，下载后在本机翻译，不联网、不需要 API Key。
模型不进安装包，而是作为 App Store 托管的按需资源包 `LyricsTranslationModel` 下发（Background Assets，26.4 起），
由已有的 `PrimuseKaraokeModelDownloader` 扩展代为下载（它对所有资源包都放行）。App 端见 `LocalLyricsTranslationModel`
与 `LocalLyricsTranslationService`。

## 来源与授权

- Mozilla Firefox Translations 的 `tiny` 学生模型（Firefox 网页翻译用的就是它们的 int8 版本），MPL-2.0。
  出处、源码形式与改动说明见 `NOTICE.txt`，许可全文 `LICENSE-MPL-2.0.txt`，两者都随资源包分发。
- 训练数据来自 OPUS/HPLT 等公开语料，与其他开源翻译模型相同的灰区，需要知情。
- 评估过但没选（FLORES-200 devtest 前 50 句 en→fa，贪心解码，chrF++）：本模型 53.9；
  Helsinki OPUS-MT `tc-bible-big`（Apache-2.0，2.4 亿参数）49.9；M2M100 418M（MIT，4.8 亿参数）44.9、zh→fa 39.4；
  OPUS-MT `en-iir` 16.6。NLLB（CC-BY-NC）与 `persiannlp` mT5（CC-BY-NC-SA）不能商用，没测。

## 生成资源包

1. 取 Mozilla 公开的 float32 学生模型（`student-finetuned/` 目录下的 `final.model.npz.best-chrf.npz` 与 `vocab.en.spm`，
   路径见 `NOTICE.txt`）。
2. 转换（任意平台，需要 Python）：

   ```sh
   python3 -m venv env
   env/bin/pip install --index-url https://download.pytorch.org/whl/cpu torch==2.5.0
   env/bin/pip install coremltools==8.3.0 numpy
   env/bin/python convert_firefox_translations.py en-fa/final.model.npz.best-chrf.npz en-fa.mlpackage
   env/bin/python convert_firefox_translations.py fa-en/final.model.npz.best-chrf.npz fa-en.mlpackage
   ```

3. 在 Mac 上编译并打包（本目录下的 `manifest.json`、`translation-model.json`、两个许可文件与产物放在同一目录）：

   ```sh
   xcrun coremlcompiler compile en-fa.mlpackage .
   xcrun coremlcompiler compile fa-en.mlpackage .
   cp en-fa/vocab.en.spm vocab.enfa.spm
   cp fa-en/vocab.en.spm vocab.faen.spm
   ba-package manifest.json -o LyricsTranslationModel.aar
   ```

4. 在 App Store Connect 的 Background Assets 上传 `LyricsTranslationModel.aar`，资源包 ID 必须是 `LyricsTranslationModel`。
   只有 TestFlight 与 App Store 版本能下载托管资源包。

## 约束

- **必须 fp32 计算**：fp16 计算时单步输出与 PyTorch 一致，但 SSRU 状态逐步累积误差，几步后就开始重复、串词
  （FLORES chrF++ 从 52 掉到 38）。权重用 int8 存储不受影响（chrF++ 只降 0.2）。
- 跑在 CPU 上（`.cpuOnly`）：M2 上神经引擎不更快，内存还翻倍，`.all` 偶发 2 秒卡顿。
- 换模型时同步修改 `translation-model.json` 的 `version`：它是翻译缓存键的一部分，旧译文不会被新模型复用。
- 分词由 `SentencePieceUnigramTokenizer`（PrimuseKit）完成，不依赖 sentencepiece 库；nmt_nfkc 规范化按参考实现
  逐码位推出，波斯语的 ZWNJ 会变成空格。
- 本地调试：Debug 构建设置 `PRIMUSE_LYRICS_TRANSLATION_MODEL=<按资源包布局放好的目录>` 可跳过下载。

## 实测（2026-09-26，M2 Mac mini，int8 权重 + fp32 计算 + CPU）

| 方向 | FLORES-200 devtest 前 150 句 chrF++ | 与 Mozilla 官方输出逐字相同 | 每条歌词 | 长句（新闻） | 加载 | 进程峰值内存 |
|---|---|---|---|---|---|---|
| en→fa | 52.2（官方全量 51.3） | 126/150 | 约 11 ms（负载 5） | 约 33 ms（负载 5） | 0.2–0.7 s | 约 100 MB |
| fa→en | 57.1（官方全量 58.3） | 112/150 | 约 40 ms（负载 150） | 约 140 ms（负载 150） | 0.4–0.6 s | 约 100 MB |

编译机被其他任务占满时（负载 100+）耗时约为空闲时的 3–4 倍。App 内实测：打开播放页后 0.6 秒内加载完模型，
一首 20 行的英文歌词不到 1 秒译完。口语歌词翻得自然；古典波斯诗（哈菲兹、鲁米）翻得很差，是这个体量模型的上限。
iPhone、Apple TV 真机的速度、内存与发热尚未实测。
