# Primuse Share Relay 部署指南

本目录提供两种兼容 Primuse 媒体中继 API 的部署方式：

| 方案 | 运行位置 | 数据存储 | 适用场景 |
| --- | --- | --- | --- |
| Docker | 自有 Linux 主机或 NAS | 持久化 Docker Volume | 需要完全控制成本、日志与数据位置 |
| Cloudflare Worker | Cloudflare 边缘网络 | 私有 R2 Bucket | 需要公网域名、全球接入和免运维证书 |

两套服务提供相同的创建、分片上传、浏览器分享页、播放、Range、下载、一次性导入、密码保护和撤销接口，但存储布局不同，不能直接共用数据目录。生产环境只应为 Primuse 配置其中一个 API 地址。

## 分享页与接口约定

公开地址有两种形式，浏览器导航都会看到完整的 Primuse 分享页，而不是 JSON：

- **短码链接**：`https://<域名>/s/123456`。可选择 4–6 位数字，默认 6 位；最长 24 小时，适合口述、手动输入和二维码分享。短码只是临时定位符，不是密码。
- **安全链接**：`https://<域名>/s/<不可枚举令牌>`。使用高熵随机令牌，可设置更长有效期，适合直接通过系统分享或复制链接发送。

- 显示封面、歌曲、艺术家、专辑、格式、音质、大小和有效期；旧版上传缺少展示字段时会使用文件名与安全默认值。
- 播放器按需请求 `/s/<令牌>/media`，支持 `HEAD`、完整读取和标准单段 `Range`。
- “下载原文件”使用 `/s/<令牌>/download`，仅在分享者开放下载权限时出现。
- “用 Primuse 打开”先由同源 `POST /s/<令牌>/import` 签发 10 分钟、仅可使用一次的 `/i/<短期令牌>`，再通过 `primuse://import-share?...` 交给 App。短期令牌不包含分享密码。
- 分享、复制链接、二维码保存、隐私说明和大文件下载确认均在页面内完成；二维码在浏览器本地生成，只编码规范化分享页地址。
- 不存在、已过期和已撤销的分享统一返回 HTTP 410 页面，不向访问者透露具体状态或歌曲信息。

兼容性方面，旧客户端直接请求 `/s/<令牌或短码>`（非浏览器导航或带 `Range`）时仍可读取媒体；新客户端应优先使用显式的 `/media` 路径。网页及静态资源均返回禁止索引和收紧的安全响应头。

## 安全约定

- `ADMIN_TOKEN` 和 `MASTER_KEY` 只放入运行时 Secret，不写入镜像、配置仓库、命令参数或日志。
- `ADMIN_TOKEN` 至少使用 32 字节随机值；`MASTER_KEY` 必须是 32 字节随机值的 Base64 编码。
- Docker Hub PAT 仅用于 `docker login`，不要写入本文、Dockerfile、Compose 文件或 Git。
- 任何曾出现在聊天、终端回显或日志中的 PAT 都应在发布完成后撤销，并重新创建只含所需权限的新 PAT。
- 备份时必须把 `MASTER_KEY` 与媒体数据分开保管。丢失密钥后，现有加密媒体无法恢复；直接轮换密钥会使旧分享失效。
- 分享 ID、撤销令牌、上传令牌和媒体对象键始终使用高熵随机值；短码采用原子占位并在冲突时重新生成。磁盘或 R2 的短码索引只使用短码哈希作为键，不保存短码或访问密码明文。

## 方案一：Docker 自托管

### 1. 准备配置

```bash
cd ShareRelay
cp relay.env.example relay.env
chmod 600 relay.env
```

编辑 `relay.env`：

```dotenv
PRIMUSE_RELAY_PUBLIC_BASE_URL=https://share.example.com
PRIMUSE_RELAY_MASTER_KEY=<openssl rand -base64 32 的结果>
PRIMUSE_RELAY_ADMIN_TOKEN=<openssl rand -hex 32 的结果>
```

不要直接把尖括号中的命令文本填入配置，应在安全终端中分别运行命令，并把结果保存到密码管理器和本机 `relay.env`。`relay.env` 已被 Git 忽略。

### 2. 使用已发布镜像运行

默认镜像地址为：

```text
docker.io/kkape/primuse-share-relay
```

已有公开发布基线版本为 `2026.09.03`，`latest` 指向同一份 amd64/arm64 多架构清单：

```bash
docker pull docker.io/kkape/primuse-share-relay:2026.09.03
```

该基线不包含本次新增的短码协议。部署本次代码时应按下文使用提交哈希构建新标签，并在拉取后用 `docker buildx imagetools inspect` 记录当前清单摘要；不要长期跟随 `latest`。

若由本仓库内置 Caddy 负责 HTTPS，服务器需开放 TCP 80、TCP/UDP 443，并让域名解析到该服务器：

```bash
PRIMUSE_RELAY_IMAGE=docker.io/kkape/primuse-share-relay:<不可变版本标签> \
PRIMUSE_RELAY_DOMAIN=share.example.com \
docker compose --profile public pull

PRIMUSE_RELAY_IMAGE=docker.io/kkape/primuse-share-relay:<不可变版本标签> \
PRIMUSE_RELAY_DOMAIN=share.example.com \
docker compose --profile public up -d
```

若已有 Nginx、Caddy、Traefik 或 Cloudflare Tunnel，只启动仅监听本机的 relay，再把外部 HTTPS 反向代理到 `127.0.0.1:8787`：

```bash
PRIMUSE_RELAY_IMAGE=docker.io/kkape/primuse-share-relay:<不可变版本标签> \
docker compose pull relay

PRIMUSE_RELAY_IMAGE=docker.io/kkape/primuse-share-relay:<不可变版本标签> \
docker compose up -d relay
```

验证：

```bash
curl --fail --silent --show-error https://share.example.com/healthz
docker compose ps
```

成功响应为：

```json
{"status":"ok"}
```

### 3. 备份与升级

- `relay_data` Volume 保存加密媒体和哈希后的控制信息，应定期做一致性备份。
- `relay.env` 不应和数据备份放在同一公开位置。
- 升级时先拉取带摘要或不可变版本标签的镜像，再运行 `docker compose up -d`。
- 回滚时把 `PRIMUSE_RELAY_IMAGE` 改回上一版本标签；不要删除 `relay_data`。

### 4. 构建并推送 Docker Hub

先在 Docker Hub 的 `kkape` 命名空间创建 `primuse-share-relay` 仓库并选择公开或私有可见性。登录时让 CLI 交互式读取 PAT，避免它进入 shell 历史：

```bash
docker login --username kkape
```

在提示 `Password` 时粘贴具有写权限的 PAT。随后从仓库根目录构建并推送 amd64、arm64 双架构镜像：

```bash
IMAGE=docker.io/kkape/primuse-share-relay
VERSION=$(git rev-parse --short=12 HEAD)

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --file ShareRelay/Dockerfile \
  --tag "$IMAGE:$VERSION" \
  --tag "$IMAGE:latest" \
  --provenance=true \
  --sbom=true \
  --push \
  ShareRelay

docker buildx imagetools inspect "$IMAGE:$VERSION"
```

生产 Compose 建议固定 `$VERSION` 或镜像 digest，不要长期跟随 `latest`。Docker 官方参考：[推送镜像](https://docs.docker.com/docker-hub/repos/manage/hub-images/push/)、[多平台构建](https://docs.docker.com/build/building/multi-platform/)、[PAT](https://docs.docker.com/security/access-tokens/)。

## 方案二：Cloudflare Worker + R2

### 架构与资源

本方案使用以下固定资源：

- Worker：`primuse-share-relay`
- 私有 R2 Bucket：`primuse-share-relay`
- Custom Domain：`share.soundisle.com`
- Worker 源码与配置：`ShareRelay/cloudflare/`
- 静态分享页资源：`ShareRelay/web/`，通过 Workers Static Assets 的 `ASSETS` binding 提供
- 公开请求限流：每个 Cloudflare 边缘位置、每个来源 IP 每分钟 600 次
- 密码尝试限流：每个分享与来源 IP 每分钟 5 次
- 短码请求限流：每个 Cloudflare 边缘位置、每个来源 IP 与短码组合每分钟 60 次
- 短码失败限流：每个 Cloudflare 边缘位置、每个来源 IP 与短码组合每分钟 5 次
- 清理任务：每 5 分钟扫描一个随机 ID 分片，过期链接立即拒绝访问，密文异步清理

上传块在 Worker 内使用 `AES-256-GCM` 加密，然后通过 R2 Multipart Upload 合并成一个私有对象。播放时 Worker 只读取所需的密文区间并逐块解密，因此完整播放和跨块 Range 都不会为每个媒体块分别发起 R2 请求。R2 不设置公开域名，所有读取必须经过 Worker 的能力令牌和状态校验。

Cloudflare Workers Free 的单次 CPU 时间较紧，密码校验还包含 210,000 次 PBKDF2。生产环境建议使用 Workers Paid，并在发布前确认 R2 已开通且账单告警已配置。

### 1. 验证本地实现

无需安装 JavaScript 依赖即可运行单元测试，并检查分享页脚本：

```bash
cd ShareRelay
node --check web/share.js
node --check cloudflare/src/index.mjs
node --test cloudflare/test/index.test.mjs
```

发布需要 Wrangler 4.36.0 或更高版本；当前验证版本为 4.128.0：

```bash
cd ShareRelay/cloudflare
npx wrangler@4.128.0 --version
npx wrangler@4.128.0 whoami
```

### 2. 创建私有 R2 Bucket

```bash
npx wrangler@4.128.0 r2 bucket list
npx wrangler@4.128.0 r2 bucket create primuse-share-relay
```

Bucket 默认不公开。不要为它启用 `r2.dev` 或 R2 Public Custom Domain。

### 3. 一次性写入 Secret

以下命令在内存中生成两个独立随机值，并通过标准输入写入 Cloudflare，不创建明文 Secret 文件：

```bash
ADMIN_TOKEN=$(openssl rand -hex 32)
MASTER_KEY=$(openssl rand -base64 32)

printf '%s\0%s' "$ADMIN_TOKEN" "$MASTER_KEY" \
  | jq -Rs 'split("\u0000") | {ADMIN_TOKEN: .[0], MASTER_KEY: .[1]}' \
  | npx wrangler@4.128.0 secret bulk
```

在清空变量前，把 `ADMIN_TOKEN` 保存到密码管理器；它需要填入 Primuse 的媒体中继设置。`MASTER_KEY` 无需放入客户端，但应在独立的灾难恢复密码库中备份。完成保存后：

```bash
unset ADMIN_TOKEN MASTER_KEY
```

`wrangler secret bulk` 会创建并发布 Worker 版本；Secret 写入后无法从 Cloudflare 控制台或 Wrangler 读回。

### 4. 发布 Worker 与域名

```bash
npx wrangler@4.128.0 deploy --strict
```

`wrangler.jsonc` 使用 Worker Custom Domain，并把 `ShareRelay/web/` 作为静态资源目录。Cloudflare 会为 `share.soundisle.com` 自动创建 DNS 记录并签发证书；该主机名不能同时存在 CNAME，也不能同时绑定其他 Worker。若主机名已被占用，应先查清现有用途，不要直接覆盖。

验证部署：

```bash
curl --fail --silent --show-error https://share.soundisle.com/healthz
npx wrangler@4.128.0 deployments list
npx wrangler@4.128.0 secret list
```

随后在 Primuse 中填写：

```text
API 地址：https://share.soundisle.com
管理令牌：保存到密码管理器的 ADMIN_TOKEN
```

本次部署生成的管理员令牌还保存在部署 Mac 的钥匙圈中。需要复制到手机时，可在该 Mac 上运行以下命令；令牌只进入剪贴板，不在终端回显：

```bash
security find-generic-password \
  -a share.soundisle.com \
  -s com.primuse.share-relay.admin-token \
  -w | pbcopy
```

至少完成一次真实小文件的创建、上传、网页播放、Range、密码解锁、下载权限、一次性导入和撤销测试，再把服务交给其他用户。

### 5. 运维边界

- 公开链接在到期或撤销后立即拒绝新请求；已经开始的边缘响应可能继续到本次请求结束。
- 主动访问到期链接会触发即时清理。定时任务轮转 64 个 ID 分片，低流量下密文删除通常会比链接失效晚数小时。
- 未完成的 R2 Multipart Upload 即使未被任务清理，也会由 R2 默认规则在 7 天后自动终止。
- 配置关闭了 Worker Observability，避免能力令牌出现在原始 URL 日志中。若以后开启日志或 Logpush，必须对 `/s/<token>` 路径做脱敏。
- Cloudflare Rate Limiting Binding 是边缘位置内的宽松限流，不是精确计费或全局配额系统。
- R2 元数据仅保存公开令牌和控制令牌的 SHA-256 哈希；媒体对象保存应用层密文。

Cloudflare 官方参考：[Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)、[R2 Workers API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/)、[Multipart Upload](https://developers.cloudflare.com/r2/api/workers/workers-multipart-usage/)、[Workers Secrets](https://developers.cloudflare.com/workers/configuration/secrets/)、[Workers 限制](https://developers.cloudflare.com/workers/platform/limits/)。

## 手机端配置与分享权限

Primuse 当前不通过局域网广播或 `.well-known` 自动发现分享服务，而是识别同一套 HTTPS API。首次使用时：

1. 在歌曲行或正在播放页打开“更多”菜单。
2. 选择唯一的“分享”入口。“分享歌曲信息”只发送歌曲文字信息；“创建播放链接”才会创建可打开的网页链接。
3. 链接方式默认选“自动”：来源服务器具备原生分享能力时优先使用服务器链接；不支持或创建失败时，Primuse 会说明原因并询问是否改用 Primuse 分享服务，不会静默上传歌曲或改变权限。也可手动选择“音乐服务器”或“Primuse 分享服务”；Navidrome/OpenSubsonic 来源同样保留后者。
4. 首次使用 Primuse 分享服务时，API 地址默认是 `https://share.soundisle.com`，只需粘贴 `ADMIN_TOKEN`。API 地址和管理员令牌保存在设备钥匙圈中，之后无需重复填写。
5. 选择“短码链接”或“安全链接”。短码可选 4、5、6 位（默认 6 位）且最长 24 小时；安全链接使用不可枚举令牌。访问密码独立于短码，两种链接都可选择“公开”或“密码保护”。
6. 选择过期时间，并分别开放“在线播放”“下载原文件”“导入 Primuse”；至少需要开放一项操作。Primuse 会通过歌曲所属连接器按 Range 读取原始媒体、分块上传，并保存生成链接与撤销令牌。
7. 成功页可复制链接、调用系统分享、显示二维码或撤销分享。接收者在 Safari 打开链接即可试听；点击“用 Primuse 打开”时，网页会把一次性导入凭证交回已安装的 App，App 校验 HTTPS 公网地址、文件类型和大小后导入“本地音乐”并启动曲库扫描。

支持已知文件大小、可按范围读取的本地与网络音乐源。Apple Music DRM 内容、流描述文件、虚拟 CUE 曲目、文件大小未知的项目以及尚未开放读取 API 的来源不会出现中继分享入口。

公开与私密行为与 Navidrome 的可选密码分享相近，但这里没有用户账号或好友 ACL：

- **公开**：任何拿到完整安全链接或短码的人都能使用分享者开放的操作，但服务不会列出链接，也不会暴露来源 URL 或 NAS 凭据。短码可枚举，因此必须受 24 小时上限、来源 IP + 短码请求/失败限流保护；敏感内容应另设访问密码或使用安全链接。
- **密码保护**：链接仍可转发，但浏览器先显示不含歌曲元数据的密码页。验证成功后签发 30 分钟的 `HttpOnly`、`SameSite=Strict` 会话 Cookie；中继只保存 PBKDF2 哈希，Primuse 不保存明文密码。旧媒体客户端仍可通过 HTTP Basic Auth 访问允许的媒体接口。
- **操作权限**：播放、下载、导入互相独立。关闭下载不会阻止按需在线播放；导入始终需要同源页面签发的一次性短期凭证。
- 两种访问模式都受过期时间控制，并可在“已管理的链接”中随时撤销；到期或撤销后立即拒绝新的页面、播放、下载和导入请求。

因此，“私密”指“随机链接加访问密码”，不是“仅指定 Primuse/Navidrome 用户可见”。如需按账号、群组或登录状态授权，需要另外接入身份系统，不能只依赖当前分享 API。

## 切换方案

Docker 与 Cloudflare 方案不能同时占用 `share.soundisle.com`。切换前应停止创建新分享，等待或撤销已有链接，再修改 Primuse 中的 API 地址。两套方案即使使用同一个 `MASTER_KEY`，也不会自动迁移元数据或现有分享 URL。
