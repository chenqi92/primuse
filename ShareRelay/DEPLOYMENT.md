# Primuse Share Relay 部署指南

本目录提供两种兼容 Primuse 媒体中继 API 的部署方式：

| 方案 | 运行位置 | 数据存储 | 适用场景 |
| --- | --- | --- | --- |
| Docker | 自有 Linux 主机或 NAS | 持久化 Docker Volume | 需要完全控制成本、日志与数据位置 |
| Cloudflare Worker | Cloudflare 边缘网络 | 私有 R2 Bucket | 需要公网域名、全球接入和免运维证书 |

两套服务提供相同的创建、客户端加密、分片上传、浏览器本地解密播放/下载、一次性导入、密码保护和撤销接口，但存储布局不同，不能直接共用数据目录。生产环境只应为 Primuse 配置其中一个 API 地址。

## 分享页与接口约定

公开地址有两种形式，浏览器导航都会看到完整的 Primuse 分享页，而不是 JSON：

- **短码链接**：`https://<域名>/s/123456#k=<解密密钥>`。可选择 4–6 位数字，默认 6 位；最长 24 小时。短码只是临时定位符，不是密码或解密密钥；单独口述短码时，还必须通过另一安全渠道提供密钥。
- **永久安全链接**：`https://<域名>/s/<不可枚举令牌>#k=<解密密钥>`。使用高熵随机令牌，不会自动过期，只有分享者撤销或管理员清理后才失效，适合长期分享。

- 页面首次只显示通用的加密分享状态。浏览器从 URL `#k=` 读取密钥，或接受用户手动粘贴密钥/完整链接；验证成功后才在本机显示歌曲、艺术家、专辑、格式、音质、文件名和操作按钮。
- 加密清单从 `/s/<令牌>/manifest` 读取，媒体密文按 `/s/<令牌>/chunks/<序号>` 获取。WebCrypto 使用 AES-256-GCM 在浏览器内逐块认证并解密，然后用本地 Blob 播放或下载；服务端的 `/media` 与 `/download` 不会为客户端加密分享返回明文。
- “用 Primuse 打开”先由同源 `POST /s/<令牌>/import` 签发 10 分钟、仅可使用一次的 `/i/<短期令牌>`，再通过 `primuse://import-share?...` 交给 App。App 下载密文后在本机解密再导入；短期令牌不包含分享密码，解密密钥仍只位于 URL Fragment。
- 分享、复制链接、二维码保存、隐私说明和大文件下载确认均在页面内完成；对加密分享，复制、系统分享和二维码都会包含完整 `#k=`，页面在获得有效密钥前不会执行这些操作。
- 不存在、已过期和已撤销的分享统一返回 HTTP 410 页面，不向访问者透露具体状态或歌曲信息。

兼容性方面，旧版由中继管理加密的分享仍可通过 `/media`、`/download` 和 Range 接口读取。客户端加密分享不会把这些接口降级成明文输出。网页及静态资源均返回禁止索引和收紧的安全响应头。

创建协议中，短码使用 `linkType: "short"` 并提交 `expiresAt`；永久安全链接使用 `linkType: "permanent"` 且不得提交 `expiresAt`。创建和完成响应都会返回明确的 `permanent` 布尔值，永久链接不返回 `expiresAt`。旧客户端省略 `linkType` 或使用 `"long"` 时仍创建有限期高熵链接，便于平滑升级，但新界面不再提供这种容易误解为永久的模式。

## 安全约定

- `ADMIN_TOKEN` 和 `MASTER_KEY` 只放入运行时 Secret，不写入镜像、配置仓库、命令参数或日志。
- `ADMIN_TOKEN` 至少使用 32 字节随机值；`MASTER_KEY` 必须是 32 字节随机值的 Base64 编码。
- 新版 Primuse 为每条分享在设备上生成独立的 256 位随机密钥；音频和包含文件名、标题、艺术家、专辑等信息的清单都在上传前用 AES-256-GCM 加密。每个分块使用独立随机 Nonce，并把分享 ID、分块序号和明文长度作为认证数据。
- 解密密钥只写入 URL 的 `#k=` Fragment。Fragment 按浏览器规则不会进入 HTTP 请求、Worker、反向代理、R2 或服务端日志；服务端只知道分享控制信息、明文总大小、分块大小和密文对象。
- 网页端端到端加密仍信任该域名当次下发的 HTML/JavaScript；如果部署账号或 Worker 被攻破，恶意脚本可以读取 Fragment。应保护 Cloudflare/服务器发布权限并审计前端变更；高敏感场景优先让双方使用受信任版本的 Primuse 原生客户端。
- 官方 `share.soundisle.com` 固定要求客户端加密。自托管可通过 `PRIMUSE_RELAY_E2EE_POLICY=required|optional|disabled` 选择策略，默认 `required`；`optional` 会兼容两种上传，但当前 Primuse 仍默认选择客户端加密；只有 `disabled` 才让当前客户端回退到中继管理的静态加密。
- Docker Hub PAT 仅用于 `docker login`，不要写入本文、Dockerfile、Compose 文件或 Git。
- 任何曾出现在聊天、终端回显或日志中的 PAT 都应在发布完成后撤销，并重新创建只含所需权限的新 PAT。
- `MASTER_KEY` 仍用于访问会话和旧版中继加密分享，不是新版客户端加密媒体的解密密钥。备份时必须与数据分开保管；丢失或轮换它会影响旧版分享和现有验证会话，但服务端本来就无法恢复新版客户端加密内容。
- 分享 ID、撤销令牌、上传令牌和媒体对象键始终使用高熵随机值；短码采用原子占位并在冲突时重新生成。磁盘或 R2 的短码索引只使用短码哈希作为键，不保存短码或访问密码明文。
- 永久链接的元数据不保存伪造的远期过期时间；完成后的密文不会进入到期清理队列，只能通过撤销或管理员清理删除。旧版带 `expiresAt` 的有限期元数据仍按原语义读取和清理。
- “禁止下载”只能控制产品界面和服务接口，不能成为 DRM：只要允许浏览器播放，获授权的接收者就必然能在自己的设备上取得可播放明文。不要把播放权限描述为技术上无法复制。

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
PRIMUSE_RELAY_E2EE_POLICY=required
PRIMUSE_RELAY_MASTER_KEY=<openssl rand -base64 32 的结果>
PRIMUSE_RELAY_ADMIN_TOKEN=<openssl rand -hex 32 的结果>
```

自托管管理员如确有兼容需求，可把策略改为：

```dotenv
# required：仅接受客户端端到端加密（默认，推荐）
# optional：同时接受客户端加密与旧式上传；新版 Primuse 仍默认加密
# disabled：禁用客户端加密，改用服务端静态加密
PRIMUSE_RELAY_E2EE_POLICY=optional
```

修改策略只影响之后创建的分享，不会转换已保存的数据。客户端会先读取 `GET /.well-known/primuse-share`，再按服务端声明的策略上传。

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
- 短码总请求限流：每个 Cloudflare 边缘位置、每个来源 IP 每分钟 60 次，换码不会绕过
- 短码失败限流：每个 Cloudflare 边缘位置、每个来源 IP 与短码组合每分钟 5 次
- 清理任务：每 5 分钟扫描一个随机 ID 分片，临时链接过期后立即拒绝访问并异步清理；永久链接不会因时间被清理

Primuse 在上传前使用 `AES-256-GCM` 加密清单与每个媒体块，Worker 不持有该分享的解密密钥。Worker 将收到的密文原样写入私有 R2：加密清单是独立对象，媒体块通过 R2 Multipart Upload 合并为一个密文对象。网页按分块区间读取密文并在浏览器本地解密；R2 不设置公开域名，所有读取必须经过 Worker 的能力令牌、状态和权限校验。

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

在清空变量前，把 `ADMIN_TOKEN` 保存到密码管理器；它需要填入 Primuse 的媒体中继设置。`MASTER_KEY` 无需放入客户端，但仍用于访问会话、访问密码流程和兼容旧分享，应在独立的灾难恢复密码库中备份。每条新版分享的媒体密钥由 Primuse 单独生成，不是这个 `MASTER_KEY`。完成保存后：

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

官方配置中的 `E2EE_POLICY` 固定为 `required`。如需验证部署策略：

```bash
curl --fail --silent --show-error \
  https://share.soundisle.com/.well-known/primuse-share
```

响应应包含 `"protocolVersion":4`、`"clientSideEncryption":"required"` 和 `client-aes-256-gcm-chunks-v1`。

### 5. 运维边界

- 临时链接在到期后、所有链接在撤销后立即拒绝新请求；已经开始的边缘响应可能继续到本次请求结束。
- 主动访问到期链接会触发即时清理。定时任务轮转 64 个 ID 分片，低流量下密文删除通常会比链接失效晚数小时。
- 未完成的 R2 Multipart Upload 即使未被任务清理，也会由 R2 默认规则在 7 天后自动终止。
- 配置关闭了 Worker Observability，避免能力令牌出现在原始 URL 日志中。若以后开启日志或 Logpush，必须对 `/s/<token>` 路径做脱敏。
- Cloudflare Rate Limiting Binding 是边缘位置内的宽松限流，不是精确计费或全局配额系统。
- R2 元数据仅保存公开令牌和控制令牌的 SHA-256 哈希；媒体对象与歌曲清单保存客户端生成的应用层密文。R2、Worker Secret 和数据库中都没有每条分享的 `#k=` 密钥。

Cloudflare 官方参考：[Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)、[R2 Workers API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/)、[Multipart Upload](https://developers.cloudflare.com/r2/api/workers/workers-multipart-usage/)、[Workers Secrets](https://developers.cloudflare.com/workers/configuration/secrets/)、[Workers 限制](https://developers.cloudflare.com/workers/platform/limits/)。

## 手机端配置与分享权限

Primuse 当前不通过局域网广播或 `.well-known` 自动发现分享服务，而是识别同一套 HTTPS API。首次使用时：

1. 在歌曲行或正在播放页打开“更多”菜单。
2. 选择唯一的“分享”入口。“分享歌曲信息”只发送歌曲文字信息；“创建播放链接”才会创建可打开的网页链接。
3. 链接方式默认选“自动”：来源服务器具备原生分享能力时优先使用服务器链接；不支持或创建失败时，Primuse 会说明原因并询问是否改用 Primuse 分享服务，不会静默上传歌曲或改变权限。也可手动选择“音乐服务器”或“Primuse 分享服务”；Navidrome/OpenSubsonic 来源同样保留后者。
4. 首次使用 Primuse 分享服务时，API 地址默认是 `https://share.soundisle.com`，只需粘贴 `ADMIN_TOKEN`。API 地址和管理员令牌保存在设备钥匙圈中，之后无需重复填写。App 会先读取服务能力；官方服务必须使用客户端加密，自托管 `optional` 也会默认使用客户端加密，只有自托管明确设为 `disabled` 时才回退到中继管理加密。
5. 选择“短码链接”或“永久安全链接”。短码可选 4、5、6 位（默认 6 位）且最长 24 小时；永久安全链接使用不可枚举令牌并一直有效，直到主动撤销。访问密码独立于链接类型，两种链接都可选择“公开”或“密码保护”。
6. 短码需选择过期时间；永久安全链接会明确显示“永久（直到撤销）”。再分别开放“在线播放”“下载原文件”“导入 Primuse”，至少需要开放一项操作。Primuse 会通过歌曲所属连接器按 Range 读取原始媒体，在设备上加密清单和每个分块，只上传密文，并把含 `#k=` 的完整链接与撤销令牌保存在本机钥匙圈。
7. 成功页可复制完整链接、调用系统分享、显示包含完整链接的二维码或撤销分享。接收者在 Safari 打开后会自动使用 Fragment 密钥解密；如果只收到基础地址和密钥，也可在页面手动粘贴密钥或完整链接，然后播放、下载。点击“用 Primuse 打开”时，网页会把一次性导入凭证与 Fragment 密钥交回已安装的 App，App 下载密文、本地认证解密、校验文件类型和大小，再导入“本地音乐”并启动曲库扫描。

支持已知文件大小、可按范围读取的本地与网络音乐源。Apple Music DRM 内容、流描述文件、虚拟 CUE 曲目、文件大小未知的项目以及尚未开放读取 API 的来源不会出现中继分享入口。

公开与私密行为与 Navidrome 的可选密码分享相近，但这里没有用户账号或好友 ACL：

- **公开**：任何拿到包含正确 `#k=` 的完整永久安全链接，或同时拿到短码与解密密钥的人，都能使用分享者开放的操作。服务不会列出链接，也不会看到歌曲信息、来源 URL、NAS 凭据或解密密钥。短码可枚举，但枚举到短码仍无法解密；它依然受 24 小时上限和请求/失败限流保护。
- **密码保护**：密码是在随机链接与加密密钥之外再加一层服务端访问控制。浏览器先显示不含歌曲元数据的密码页；验证成功后签发 30 分钟的 `HttpOnly`、`SameSite=Strict` 会话 Cookie。中继只保存 PBKDF2 哈希，Primuse 不保存明文密码，密码也不会写入链接或二维码。通过后仍必须拥有正确的 `#k=` 才能在本地解密。
- **操作权限**：播放、下载、导入互相独立。关闭下载不会阻止按需在线播放；导入始终需要同源页面签发的一次性短期凭证。
- 两种访问模式都遵循所选链接寿命，并可在“已管理的链接”中随时撤销；短码到期或任意链接撤销后立即拒绝新的页面、播放、下载和导入请求。

因此，“公开”与“密码保护”控制谁能从服务端取得密文；`#k=` 控制谁能解密内容。这里的“私密”仍不是“仅指定 Primuse/Navidrome 用户可见”。如需按账号、群组或登录状态授权，需要另外接入身份系统，不能只依赖当前分享 API。

## 切换方案

Docker 与 Cloudflare 方案不能同时占用 `share.soundisle.com`。切换前应停止创建新分享，等待或撤销已有链接，再修改 Primuse 中的 API 地址。两套方案即使使用同一个 `MASTER_KEY`，也不会自动迁移元数据、密文或现有分享 URL；每条客户端加密分享还依赖只保存在完整链接和分享者设备中的独立密钥。
