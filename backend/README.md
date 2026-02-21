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

## .env（推荐）

后端支持读取 `backend/.env`（示例见 `backend/.env.example`）。

优先级：**系统环境变量 > `.env` > 默认值**。

## API（v1）

- `GET /api/v1/health`
- `PUT /api/v1/auth/{source}`：保存该漫画源的会话/配置（JSON，明文存储）
- `GET /api/v1/auth/{source}`：查询该漫画源是否已配置
- `GET /api/v1/auth`：列出已配置的漫画源
- `POST /api/v1/tasks/download`：创建“服务端下载并入库”任务（异步，JSON）
  - `source`：`picacg | ehentai | jm | hitomi | htmanga | nhentai`
  - `target`：源站目标（不同源含义不同，见下方）
  - `eps`：可选；章节序号数组（从 0 开始，适用于 `picacg/jm`）
- `GET /api/v1/tasks?limit=50`：列出任务
- `GET /api/v1/tasks/{id}`：查询任务状态/进度
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
- `GET /api/v1/comics/{id}/cover`
- `GET /api/v1/comics/{id}/read`：返回章节信息（用于在线阅读）
- `GET /api/v1/comics/{id}/pages?ep={ep}`：返回指定章节的页面文件名列表
- `GET /api/v1/comics/{id}/image?ep={ep}&name={filename}`：返回单页图片
- `DELETE /api/v1/comics/{id}`
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

## auth/{source} 约定（KISS）

后端不会自动登录/续期；会话失效时任务会失败，需要客户端重新 `PUT /api/v1/auth/{source}` 更新。

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
