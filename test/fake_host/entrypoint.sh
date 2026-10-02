#!/bin/sh
set -e

# Start dockerd in the background (the entrypoint script that ships with the dind image)
dockerd-entrypoint.sh dockerd >/var/log/dockerd.log 2>&1 &

# Wait for the docker socket to be ready
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

# Let the deploy user access the docker socket
chgrp docker /var/run/docker.sock
chmod 660 /var/run/docker.sock

# Pre-pull the test image so each test doesn't pull it separately
docker pull busybox:latest >/dev/null 2>&1 || true
docker pull basecamp/kamal-proxy:v0.10.0 >/dev/null 2>&1 || true

exec /usr/sbin/sshd -D -e
