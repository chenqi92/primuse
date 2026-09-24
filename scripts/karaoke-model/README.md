# 卡拉OK AI 人声模型

卡拉OK模式的 AI 人声分离使用 Meta 的 Hybrid Transformer Demucs v4（MIT 许可，见 `LICENSE-demucs.txt`）。
模型不进安装包，而是作为 App Store 托管的按需资源包（Background Assets）下发，
系统通过 `PrimuseKaraokeModelDownloader` 扩展下载；App 端见 `KaraokeVocalModel`。

## 生成资源包

1. 转换（任意平台，需要 Python）：

   ```sh
   python3 -m venv env
   env/bin/pip install --index-url https://download.pytorch.org/whl/cpu torch==2.5.0 torchaudio==2.5.0
   env/bin/pip install coremltools==8.3.0 demucs==4.0.1 numpy
   env/bin/python convert_htdemucs.py --output HTDemucsVocals.mlpackage
   ```

2. 在 Mac 上编译成 `.mlmodelc` 并打包（`manifest.json` 与编译产物放在同一目录）：

   ```sh
   xcrun coremlcompiler compile HTDemucsVocals.mlpackage .
   ba-package manifest.json -o KaraokeVocalModel.aar
   ```

3. 在 App Store Connect 的「App 内资源包 / Background Assets」上传 `KaraokeVocalModel.aar`，
   资源包 ID 必须是 `KaraokeVocalModel`。只有 TestFlight 与 App Store 版本能下载托管资源包。

## 约束

- 更换模型时同步修改 `KaraokeVocalModel.cacheVersion`，旧的分离缓存就不会被复用。
- 模型必须跑在 CPU+GPU 上：神经引擎内部按半精度计算，频谱分支会溢出，输出是错的。
- 本地调试：Debug 构建设置环境变量 `PRIMUSE_KARAOKE_MODEL=<.mlmodelc 或 .mlpackage 路径>` 可跳过下载。
