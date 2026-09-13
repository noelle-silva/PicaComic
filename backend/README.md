# Pica Server

一个极简的私有服务器，用于把 PicaComic 的**服务器收藏**与**已下载漫画**集中存放在服务器上。

> 说明：用户数据（`/api/v1/userdata`）功能默认禁用；需要时可通过 `PICA_ENABLE_USERDATA=1` 开启。

## 运行

```bash
cd backend
dart pub get
dart run bin/server.dart
```

## 环境变量

- `PICA_BIND`：监听地址，默认 `0.0.0.0`
- `PICA_PORT`：端口，默认 `8080`
- `PICA_STORAGE`：数据目录，默认 `./storage`
- `PICA_API_KEY`：可选；如果设置，则所有 `/api/*` 请求必须带 `X-Api-Key`
- `PICA_ENABLE_USERDATA`：可选；默认禁用。设为 `1` 才启用用户数据（`/api/v1/userdata`）上传/下载
- `PICA_PROXY`：可选；后端对外访问（下载/抓取）走代理。支持 `host:port`、`http(s)://host:port`、`http(s)://user:pass@host:port`、`socks5://host:port`；设为 `DIRECT/NONE/OFF/0` 可禁用（如含特殊字符请对 `user/pass` 做 URL 编码）
- `PICA_PROXY_USERNAME` / `PICA_PROXY_PASSWORD`：可选；HTTP 代理 Basic 鉴权（用于避免 `user/pass` URL 编码问题）。如果设置了 `PICA_PROXY_USERNAME`，会覆盖 `PICA_PROXY` 里自带的 `user:pass@...`
- `PICA_FILE_RETRIES_DEFAULT`：可选；文件下载失败重试次数（0-10），默认 `2`
- `PICA_FILE_RETRIES_PICACG`：可选；默认 `2`
- `PICA_FILE_RETRIES_EHENTAI`：可选；默认 `1`
- `PICA_FILE_RETRIES_JM`：可选；默认 `2`
- `PICA_FILE_RETRIES_HITOMI`：可选；默认 `2`
- `PICA_FILE_RETRIES_HTMANGA`：可选；默认 `2`
- `PICA_FILE_RETRIES_NHENTAI`：可选；默认 `3`
- `PICA_FILE_CONCURRENT_DEFAULT`：可选；单任务内文件下载并行数（1-16），默认 `6`
- `PICA_FILE_CONCURRENT_PICACG`：可选；覆盖 `picacg` 的并行数
- `PICA_FILE_CONCURRENT_EHENTAI`：可选；覆盖 `ehentai` 的并行数
- `PICA_FILE_CONCURRENT_JM`：可选；覆盖 `jm` 的并行数
- `PICA_FILE_CONCURRENT_HITOMI`：可选；覆盖 `hitomi` 的并行数
- `PICA_FILE_CONCURRENT_HTMANGA`：可选；覆盖 `htmanga` 的并行数
- `PICA_FILE_CONCURRENT_NHENTAI`：可选；覆盖 `nhentai` 的并行数
- `PICA_AUTH_KEY`：可选；登录态数据的落盘加密密钥（AES-256-GCM）。不设置时自动生成 `<PICA_STORAGE>/auth.key`；设置后请妥善保管，更换密钥会导致旧记录不可读（需从 App 重新同步）

## .env（推荐）

后端支持读取 `backend/.env`（示例见 `backend/.env.example`）。

优先级：**系统环境变量 > `.env` > 默认值**。

## API（v1）

- `GET /api/v1/health`
- `PUT /api/v1/auth/{source}`：保存该漫画源的会话/配置（JSON，落盘加密）
- `GET /api/v1/auth/{source}`：查询该漫画源是否已配置
- `GET /api/v1/auth/{source}/data`：读取该漫画源已保存的会话内容（JSON，自动解密）
- `GET /api/v1/auth`：列出已配置的漫画源
- `POST /api/v1/tasks/download`：创建“服务端下载并入库”任务（异步，JSON）
  - `source`：`picacg | ehentai | jm | hitomi | htmanga | nhentai`
  - `target`：源站目标（不同源含义不同，见下方）
  - `eps`：可选；章节序号数组（从 0 开始，适用于 `picacg/jm`）
- `POST /api/v1/tasks/upload`：创建“上传本地已下载漫画并入库”任务（异步，multipart）
  - `meta`：JSON 字符串（包含 `id/title/subtitle/type/tags/directory/json` 等）
  - `zip`：下载目录打包后的 zip（仅用于传输；服务器会解压为图片并丢弃 zip）
  - `cover`：可选封面文件
- `GET /api/v1/tasks?limit=50`：列出任务
- `GET /api/v1/tasks/{id}`：查询任务状态/进度
- `GET /api/v1/tasks/config`：查询任务并发配置（`maxConcurrent` / `fileConcurrent`）
- `PUT /api/v1/tasks/config`：更新任务并发配置（JSON，可单独更新任一字段）
- `POST /api/v1/userdata`：可选；需要 `PICA_ENABLE_USERDATA=1`；multipart，字段 `file`（`.picadata`）
- `GET /api/v1/userdata`：可选；需要 `PICA_ENABLE_USERDATA=1`
- `POST /api/v1/comics/fetch`：服务端拉取 zip 并入库（JSON）
  - `zipUrl`：zip 下载地址（http/https）
  - `meta`：与 `POST /api/v1/comics` 的 `meta` 相同（至少包含 `id`）
  - `headers`：可选；请求头 Map（用于需要鉴权的直链下载）
- `POST /api/v1/comics`：multipart
  - `meta`：JSON 字符串（包含 `id/title/subtitle/type/tags/directory/json` 等）
  - `zip`：下载目录打包后的 zip（仅用于传输；服务器会解压为图片并丢弃 zip）
  - `cover`：可选封面文件
- `GET /api/v1/comics`
- `GET /api/v1/comics/contains?source={k}&target={id}`：查询漫画是否已下载到服务器（与收藏查询对称）
- `GET /api/v1/comics/{id}/cover`
- `GET /api/v1/comics/{id}/read`：返回章节信息（用于在线阅读）
- `GET /api/v1/comics/{id}/pages?ep={ep}`：返回指定章节的页面文件名列表
- `GET /api/v1/comics/{id}/image?ep={ep}&name={filename}`：返回单页图片
- `DELETE /api/v1/comics/{id}`
- 源信息收藏（收藏各来源的漫画信息，与是否已下载无关）
  - `GET /api/v1/favorites/folders`
  - `POST /api/v1/favorites/folders`
  - `PATCH /api/v1/favorites/folders/rename`
  - `PATCH /api/v1/favorites/folders/order`
  - `DELETE /api/v1/favorites/folders/{name}?moveTo={folder}`
  - `GET /api/v1/favorites?folder={folder}`
  - `GET /api/v1/favorites/contains?sourceKey={k}&target={id}`
  - `POST /api/v1/favorites`
  - `DELETE /api/v1/favorites`
  - `PATCH /api/v1/favorites/move`
  - `PATCH /api/v1/favorites/order`
- 服务器资源收藏（仅能收藏已入库漫画；展示信息实时取自漫画库，删除漫画时同步清理）
  - `GET /api/v1/resource-favorites/folders`
  - `POST /api/v1/resource-favorites/folders`
  - `PATCH /api/v1/resource-favorites/folders/rename`
  - `PATCH /api/v1/resource-favorites/folders/order`
  - `DELETE /api/v1/resource-favorites/folders/{name}?moveTo={folder}`
  - `GET /api/v1/resource-favorites?folder={folder}`
  - `GET /api/v1/resource-favorites/contains?id={comicId}`
  - `POST /api/v1/resource-favorites`（body：`{id, folder}`；id 不在漫画库时返回 404）
  - `DELETE /api/v1/resource-favorites`（body：`{id}`）
  - `PATCH /api/v1/resource-favorites/move`
  - `PATCH /api/v1/resource-favorites/order`
- 漫画订阅与自动追更（面向未入库漫画；服务器按频率检查更新，按级别记录/自动下载）
  - `GET /api/v1/subscriptions`：订阅列表（含有效频率、上次/下次检查时间）
  - `GET /api/v1/subscriptions/contains?source={k}&target={id}`
  - `POST /api/v1/subscriptions`（body：`{source, target, title, subtitle, cover, tags, level: update|download, intervalMinutes?}`；已入库返回 409）
  - `PATCH /api/v1/subscriptions`（body：`{source, target, level?, intervalMinutes?, enabled?}`）
  - `DELETE /api/v1/subscriptions`（body：`{source, target}`；历史保留）
  - `POST /api/v1/subscriptions/check`（body：`{source, target}`；同步执行检查并返回结果：`status`/`newItems`/`totalItems`/`latestItem`/`recentItems`（最近几话与源站更新时间）/`firstCheck`/`message`）
  - `GET /api/v1/subscriptions/history?source={k}&target={id}`：更新历史（发现更新/失败）
  - `GET /api/v1/subscriptions/downloads?limit=`：订阅自动下载历史（实时关联任务状态）
  - `GET /api/v1/subscriptions/config` / `PUT /api/v1/subscriptions/config`：全局默认检查频率（分钟）

## auth/{source} 约定（KISS）

后端不会自动登录/续期；会话失效时任务会失败，需要客户端重新 `PUT /api/v1/auth/{source}` 更新。

登录态数据在服务器上**加密存储**（AES-256-GCM）：客户端读写仍为明文 JSON，加解密发生在服务器内部。密钥来自 `PICA_AUTH_KEY`，未设置时自动生成 `<PICA_STORAGE>/auth.key`。

> 安全提醒：请务必在服务器前置 HTTPS（反向代理），否则传输链路仍可能被监听。加密存储只能防数据库文件/备份被直接读取，不能防服务器被完整入侵。
>
> 数据兼容：升级到加密存储后，旧的明文记录无法读取，需要在 App 中删除后重新同步一次。

- `picacg`
  - 必填：`token`
  - 可选：`appChannel`、`imageQuality`、`appUuid`
  - `target`：漫画 id
- `jm`
  - 必填：`apiBaseUrl`（如 `https://<jm-api-domain>`）
  - 必填：`imgBaseUrl`（如 `https://<jm-img-domain>`）
  - 必填：`appVersion`
  - 可选：`scrambleId`（默认 `220980`）
  - `target`：漫画 id（纯数字）
- `ehentai`
  - 必填：`cookie`（整段 Cookie 字符串）
  - `target`：画廊链接（必须包含 `/g/{gid}/{token}/`）
- `htmanga`
  - 必填：`baseUrl`（站点根地址）
  - 可选：`cookie`
  - `target`：漫画 id（纯数字）
- `hitomi`
  - 可选：`baseDomain`（默认 `hitomi.la`）
  - `target`：画廊 id（数字；也可传包含数字的链接）
- `nhentai`
  - 可选：`baseUrl`（默认 `https://nhentai.net`）
  - 可选：`cookie`（需要时用于绕过 403/风控，例如 `cf_clearance`）
  - `target`：画廊 id（数字；也可传包含数字的链接）
