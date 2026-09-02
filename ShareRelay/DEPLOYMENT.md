# Primuse Share Relay 部署指南

本目录提供两种兼容 Primuse 媒体中继 API 的部署方式：

| 方案 | 运行位置 | 数据存储 | 适用场景 |
| --- | --- | --- | --- |
| Docker | 自有 Linux 主机或 NAS | 持久化 Docker Volume | 需要完全控制成本、日志与数据位置 |
| Cloudflare Worker | Cloudflare 边缘网络 | 私有 R2 Bucket | 需要公网域名、全球接入和免运维证书 |

两套服务提供相同的创建、分片上传、播放、Range、密码保护和撤销接口，但存储布局不同，不能直接共用数据目录。生产环境只应为 Primuse 配置其中一个 API 地址。

## 安全约定

- `ADMIN_TOKEN` 和 `MASTER_KEY` 只放入运行时 Secret，不写入镜像、配置仓库、命令参数或日志。
- `ADMIN_TOKEN` 至少使用 32 字节随机值；`MASTER_KEY` 必须是 32 字节随机值的 Base64 编码。
- Docker Hub PAT 仅用于 `docker login`，不要写入本文、Dockerfile、Compose 文件或 Git。
- 任何曾出现在聊天、终端回显或日志中的 PAT 都应在发布完成后撤销，并重新创建只含所需权限的新 PAT。
- 备份时必须把 `MASTER_KEY` 与媒体数据分开保管。丢失密钥后，现有加密媒体无法恢复；直接轮换密钥会使旧分享失效。

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

当前公开发布版本为 `2026.09.02`，`latest` 指向同一份 amd64/arm64 多架构清单：

```bash
docker pull docker.io/kkape/primuse-share-relay:2026.09.02
```

版本清单摘要为 `sha256:1042d4b31cbe49e452e9911bf2d05d87bbb9814886aee3effd35b1a22559de74`。生产部署建议固定 `2026.09.02` 或该摘要。

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
- 公开请求限流：每个 Cloudflare 边缘位置、每个来源 IP 每分钟 600 次
- 清理任务：每 5 分钟扫描一个随机 ID 分片，过期链接立即拒绝访问，密文异步清理

上传块在 Worker 内使用 `AES-256-GCM` 加密，然后通过 R2 Multipart Upload 合并成一个私有对象。播放时 Worker 只读取所需的密文区间并逐块解密，因此完整播放和跨块 Range 都不会为每个媒体块分别发起 R2 请求。R2 不设置公开域名，所有读取必须经过 Worker 的能力令牌和状态校验。

Cloudflare Workers Free 的单次 CPU 时间较紧，密码校验还包含 210,000 次 PBKDF2。生产环境建议使用 Workers Paid，并在发布前确认 R2 已开通且账单告警已配置。

### 1. 验证本地实现

无需安装 JavaScript 依赖即可运行单元测试：

```bash
cd ShareRelay
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

`wrangler.jsonc` 使用 Worker Custom Domain。Cloudflare 会为 `share.soundisle.com` 自动创建 DNS 记录并签发证书；该主机名不能同时存在 CNAME，也不能同时绑定其他 Worker。若主机名已被占用，应先查清现有用途，不要直接覆盖。

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

至少完成一次真实小文件的创建、上传、Range 播放和撤销测试，再把服务交给其他用户。

### 5. 运维边界

- 公开链接在到期或撤销后立即拒绝新请求；已经开始的边缘响应可能继续到本次请求结束。
- 主动访问到期链接会触发即时清理。定时任务轮转 64 个 ID 分片，低流量下密文删除通常会比链接失效晚数小时。
- 未完成的 R2 Multipart Upload 即使未被任务清理，也会由 R2 默认规则在 7 天后自动终止。
- 配置关闭了 Worker Observability，避免能力令牌出现在原始 URL 日志中。若以后开启日志或 Logpush，必须对 `/s/<token>` 路径做脱敏。
- Cloudflare Rate Limiting Binding 是边缘位置内的宽松限流，不是精确计费或全局配额系统。
- R2 元数据仅保存公开令牌和控制令牌的 SHA-256 哈希；媒体对象保存应用层密文。

Cloudflare 官方参考：[Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)、[R2 Workers API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/)、[Multipart Upload](https://developers.cloudflare.com/r2/api/workers/workers-multipart-usage/)、[Workers Secrets](https://developers.cloudflare.com/workers/configuration/secrets/)、[Workers 限制](https://developers.cloudflare.com/workers/platform/limits/)。

## 手机端配置与分享权限

Primuse 当前不通过局域网广播或 `.well-known` 自动发现媒体中继，而是识别同一套 HTTPS API。首次使用时：

1. 在歌曲行或正在播放页打开“更多”菜单。
2. 当来源服务器没有原生安全分享能力时，选择“通过私有中继创建链接”。若来源本身支持 Navidrome 等原生分享，界面会优先显示来源服务器的分享入口。
3. 将中继 API 地址填写为 `https://share.soundisle.com`，粘贴 `ADMIN_TOKEN`。
4. 选择过期时间；访问密码留空或填写后，点“创建可播放链接”。
5. Primuse 会通过歌曲所属连接器按 Range 读取原始媒体、分块上传到中继，并保存生成链接与撤销令牌。API 地址和管理员令牌保存在设备钥匙圈中，之后无需重复填写。

支持已知文件大小、可按范围读取的本地与网络音乐源。Apple Music DRM 内容、流描述文件、虚拟 CUE 曲目、文件大小未知的项目以及尚未开放读取 API 的来源不会出现中继分享入口。

公开与私密行为与 Navidrome 的可选密码分享相近，但这里没有用户账号或好友 ACL：

- **访问密码留空**：生成不可枚举的能力链接；任何拿到完整链接的人都能播放，但它不会被服务列出，也不会暴露来源 URL 或 NAS 凭据。
- **填写访问密码**：链接仍可转发，但访问者还必须通过 HTTP Basic Auth 输入该密码；中继只保存 PBKDF2 哈希，Primuse 不保存明文密码。
- 两种链接都受过期时间控制，并可在“已管理的链接”中随时撤销；到期或撤销后立即拒绝新的播放请求。

因此，“私密”指“随机链接加访问密码”，不是“仅指定 Primuse/Navidrome 用户可见”。如需按账号、群组或登录状态授权，需要另外接入身份系统，不能只依赖当前分享 API。

## 切换方案

Docker 与 Cloudflare 方案不能同时占用 `share.soundisle.com`。切换前应停止创建新分享，等待或撤销已有链接，再修改 Primuse 中的 API 地址。两套方案即使使用同一个 `MASTER_KEY`，也不会自动迁移元数据或现有分享 URL。
