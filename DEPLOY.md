# 部署說明(純 pull image,適用 Dockhand 等面板)

用「已打包好的 image」部署 worklenz(繁體中文版),伺服器上**不需 build 原始碼**。

## 前置

三個 image 已發佈在 ghcr.io(**public,免帳密可拉**):

| image | 內容 |
|-------|------|
| `ghcr.io/tw199501/worklenz-postgres:2.1.6-zh-TW.1` | PostgreSQL + 內建 schema(首次啟動自動匯入) |
| `ghcr.io/tw199501/worklenz-backend:2.1.6-zh-TW.1` | Express API |
| `ghcr.io/tw199501/worklenz-frontend:2.1.6-zh-TW.1` | React SPA |

> 本 compose **不含 nginx** —— 假設你前面已有一層 reverse proxy。

## 1. 準備 `.env`

### 產生密鑰
```bash
echo "DB_PASSWORD=$(openssl rand -hex 16)"
echo "SESSION_SECRET=$(openssl rand -hex 32)"
echo "COOKIE_SECRET=$(openssl rand -hex 32)"
echo "JWT_SECRET=$(openssl rand -hex 32)"
```

### `.env` 範本(填入密鑰與域名)
```env
# 密鑰(用上面指令產生)
DB_PASSWORD=
SESSION_SECRET=
COOKIE_SECRET=
JWT_SECRET=

# 對外網址(4 個都換成你的域名)
VITE_API_URL=https://your-domain
VITE_SOCKET_URL=wss://your-domain
FRONTEND_URL=https://your-domain
SOCKET_IO_CORS=https://your-domain

# image 版本(已對好,別動)
DOCKER_USERNAME=tw199501
DB_VERSION=2.1.6-zh-TW.1
BACKEND_VERSION=2.1.6-zh-TW.1
FRONTEND_VERSION=2.1.6-zh-TW.1
```

> 其餘變數(Redis 密碼、MinIO、DB 名稱…)都有內建預設值,可先不填。
> `VITE_*` 是**容器啟動時注入**的(不是 build 進 image),改域名重啟即可生效,不必重 build。

## 2. Dockhand 設定

- Repo:`TW199501/worklenz` ・ Branch:**`release`** ・ Compose 檔:**`docker-compose.deploy.yaml`**
- 將上面的 `.env` 貼進環境變數

## 3. 你前面那層 reverse proxy 的分流

compose 對外暴露:**backend → `:3000`**、**frontend → `:5000`**。
以下前綴轉到 backend,其餘全部轉到 frontend:

| 路徑 | 轉到 | 備註 |
|------|------|------|
| `/api/` | backend:3000 | |
| `/socket.io/`、`/socket/` | backend:3000 | **需 WebSocket upgrade** |
| `/secure/` | backend:3000 | 登入/註冊 |
| `/public/` | backend:3000 | |
| `/csrf-token` | backend:3000 | |
| `/uploads/` | backend:3000 | |
| `/`(其他全部) | frontend:5000 | React SPA |

完整可抄的 nginx 範例見 [`nginx/conf.d/worklenz.conf`](nginx/conf.d/worklenz.conf)。

## 故障排除

| 症狀 | 多半原因 |
|------|----------|
| login 卡住/失敗 | reverse proxy 漏了 `/secure/` 或 `/socket.io/` 分流 |
| 即時更新沒反應 | `/socket.io/` 沒設 WebSocket upgrade |
| 拉不到 image(`unauthorized`) | ghcr 三個 package 不是 public |
| 中文名稱亂碼 | 已修(session base64 改 UTF-8 解碼) |
