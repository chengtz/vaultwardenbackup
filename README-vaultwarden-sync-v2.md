# Vaultwarden 主备同步脚本

这个脚本用于已经部署好的 Vaultwarden，实现：

```text
主节点 -> 备用节点
```

只做单向同步，不做双写。

## 1. 准备条件

两台机器都已经部署好 Vaultwarden。

主节点可以 SSH 登录备用节点。

建议先在主节点测试：

```sh
ssh 备用节点用户@备用节点主机 'hostname && whoami && pwd'
```

如果可以免密登录，后续定时同步最方便。

## 2. 在主节点运行安装器

```sh
fetch -o install-vaultwarden-sync.sh https://raw.githubusercontent.com/YOUR_NAME/YOUR_REPO/main/install-vaultwarden-sync.sh
chmod +x install-vaultwarden-sync.sh
./install-vaultwarden-sync.sh
```

脚本会一步步询问：

```text
主节点 Vaultwarden 目录
备用节点 SSH 用户名
备用节点 SSH 主机
备用节点 Vaultwarden 目录
SSH 私钥路径
定时同步时间
```

## 3. 推荐定时任务

每天同步两次可以填：

```cron
0 3,15 * * *
```

只想每天凌晨同步一次可以填：

```cron
0 3 * * *
```

不想自动同步就留空。

## 4. 手动同步

安装完成后，在主节点执行：

```sh
cd ~/apps/vaultwarden
./backup_to_standby.sh
```

看到下面内容表示成功：

```text
Restore completed.
Sync completed
```

## 5. 备用节点检查

登录备用节点：

```sh
cd ~/apps/vaultwarden
curl -I http://127.0.0.1:你的端口
```

返回 `HTTP/1.1 200 OK` 就说明服务正常。

再确认 `.env` 没被覆盖：

```sh
grep -E 'DOMAIN|SIGNUPS_ALLOWED|ROCKET_PORT' .env
```

## 6. 同步内容

会同步：

```text
data/db.sqlite3
data/attachments/
data/sends/
data/rsa_key.pem
data/rsa_key.pub.pem
```

不会同步：

```text
.env
logs/
pkg-extract/
```

## 7. 注意事项

备用节点会拥有完整密码库数据，包括账号、2FA 和所有密码条目。

不要在备用节点日常新增或修改密码，因为下次同步会被主节点覆盖。

主节点和备用节点都要关闭注册：

```env
SIGNUPS_ALLOWED=false
```

## 8. GitHub 忽略文件

建议 `.gitignore`：

```gitignore
.env
data/
logs/
incoming/
backups/
backup-tmp/
restore-tmp/
local-before-restore/
*.pid
*.pkg
pkg-extract/
```
