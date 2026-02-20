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
- `POST /api/v1/userdata`：可选；需要 `PICA_ENABLE_USERDATA=1`；multipart，字段 `file`（`.picadata`）
- `GET /api/v1/userdata`：可选；需要 `PICA_ENABLE_USERDATA=1`
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
