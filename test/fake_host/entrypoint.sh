#!/bin/sh
set -e

# 后台启动 dockerd（dind 镜像自带的入口脚本）
dockerd-entrypoint.sh dockerd >/var/log/dockerd.log 2>&1 &

# 等待 docker socket 就绪
for i in $(seq 1 60); do
  if [ -S /var/run/docker.sock ]; then
    break
  fi
  sleep 1
done

if [ ! -S /var/run/docker.sock ]; then
  echo "dockerd 启动超时" >&2
  cat /var/log/dockerd.log >&2
  exit 1
fi

# 让 deploy 用户可以访问 docker socket
chgrp docker /var/run/docker.sock
chmod 660 /var/run/docker.sock

# 预拉测试用镜像，避免每个测试各拉一次
docker pull busybox:latest >/dev/null 2>&1 || true
docker pull basecamp/kamal-proxy:v0.10.0 >/dev/null 2>&1 || true

exec /usr/sbin/sshd -D -e
