# Pica Server

一个极简的私有服务器，用于把 PicaComic 的用户数据与已下载漫画集中存放在服务器上。

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

## .env（推荐）

后端支持读取 `backend/.env`（示例见 `backend/.env.example`）。

优先级：**系统环境变量 > `.env` > 默认值**。

## API（v1）

- `GET /api/v1/health`
- `POST /api/v1/userdata`：multipart，字段 `file`（`.picadata`）
- `GET /api/v1/userdata`
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
