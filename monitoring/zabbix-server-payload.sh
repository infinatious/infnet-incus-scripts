#!/bin/bash
# Runs INSIDE the Zabbix container (Ubuntu 26.04), pushed there by
# install-zabbix-server.sh: Zabbix server + PostgreSQL + nginx frontend (own
# TLS, self-signed) + agent2. Idempotent; secrets stay root-only in /root/zabbix.
# Usage: zabbix-server-payload.sh <public fqdn> <internal fqdn> <public ip> <title>
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
FQDN_PUB="$1"
FQDN_INT="$2"
PUB_IP="$3"
TITLE="$4"
ZABBIX_VERSION="${ZABBIX_VERSION:-7.4}"

cloud-init status --wait >/dev/null 2>&1 || true

if ! dpkg -s zabbix-release >/dev/null 2>&1; then
  curl -fsSL -o /tmp/zabbix-release.deb "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+ubuntu$(. /etc/os-release; echo "${VERSION_ID}")_all.deb"
  dpkg -i /tmp/zabbix-release.deb
fi
apt-get -qq update
apt-get -qq install -y postgresql zabbix-server-pgsql zabbix-frontend-php zabbix-nginx-conf zabbix-sql-scripts zabbix-agent2 php-pgsql openssl jq fping >/dev/null

# Database (password kept root-only on the box, never printed).
install -d -m 700 /root/zabbix
[[ -s /root/zabbix/db-password ]] || openssl rand -base64 24 | tr -d '/+=' > /root/zabbix/db-password
DB_PW="$(cat /root/zabbix/db-password)"
if ! sudo -u postgres psql -tAc "select 1 from pg_roles where rolname='zabbix'" | grep -q 1; then
  sudo -u postgres psql -qc "create user zabbix with password '${DB_PW}'"
  sudo -u postgres createdb -O zabbix zabbix
  zcat /usr/share/zabbix/sql-scripts/postgresql/server.sql.gz | sudo -u zabbix psql -q zabbix >/dev/null
fi

# Server.
sed -i -E "s|^#? ?DBPassword=.*|DBPassword=${DB_PW}|" /etc/zabbix/zabbix_server.conf
grep -q "^DBPassword=" /etc/zabbix/zabbix_server.conf || echo "DBPassword=${DB_PW}" >> /etc/zabbix/zabbix_server.conf

# Frontend config (skips the setup wizard).
cat > /etc/zabbix/web/zabbix.conf.php <<PHP
<?php
\$DB['TYPE']     = ZBX_DB_POSTGRESQL;
\$DB['SERVER']   = 'localhost';
\$DB['PORT']     = '0';
\$DB['DATABASE'] = 'zabbix';
\$DB['USER']     = 'zabbix';
\$DB['PASSWORD'] = '${DB_PW}';
\$DB['SCHEMA']   = '';
\$DB['ENCRYPTION'] = false;
\$ZBX_SERVER_NAME = '${TITLE}';
\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
PHP
chown www-data:www-data /etc/zabbix/web/zabbix.conf.php
chmod 640 /etc/zabbix/web/zabbix.conf.php

# TLS served by nginx itself (self-signed for QA).
install -d -m 755 /etc/zabbix/tls
if [[ ! -s /etc/zabbix/tls/zabbix.crt ]]; then
  openssl req -x509 -newkey rsa:3072 -nodes -days 825 -subj "/CN=${FQDN_PUB}" \
    -addext "subjectAltName=DNS:${FQDN_PUB},DNS:${FQDN_INT},IP:${PUB_IP}" \
    -keyout /etc/zabbix/tls/zabbix.key -out /etc/zabbix/tls/zabbix.crt 2>/dev/null
  chmod 600 /etc/zabbix/tls/zabbix.key
fi
FQDN_PUB="${FQDN_PUB}" FQDN_INT="${FQDN_INT}" python3 - <<'PY'
import os, re
p = '/etc/zabbix/nginx.conf'
s = open(p).read()
if 'ssl_certificate ' in s:
    raise SystemExit(0)
s = re.sub(r'^\s*#?\s*listen\s+[^;]*;\s*$', '', s, flags=re.M)
s = re.sub(r'^\s*#?\s*server_name\s+[^;]*;\s*$', '', s, flags=re.M)
s = s.replace('server {', f'''server {{
        listen          443 ssl;
        http2           on;
        server_name     {os.environ["FQDN_PUB"]} {os.environ["FQDN_INT"]} _;
        ssl_certificate     /etc/zabbix/tls/zabbix.crt;
        ssl_certificate_key /etc/zabbix/tls/zabbix.key;
        ssl_protocols       TLSv1.2 TLSv1.3;''', 1)
open(p, 'w').write(s)
PY
cat > /etc/nginx/sites-available/default <<'NGX'
server {
    listen 80 default_server;
    return 301 https://$host$request_uri;
}
NGX
nginx -t 2>&1 | tail -1

# The Admin password: replace the default 'zabbix' with a random one (once).
[[ -s /root/zabbix/admin-password ]] || openssl rand -base64 18 | tr -d '/+=' > /root/zabbix/admin-password
chmod 600 /root/zabbix/*

# Agent2 on the server itself.
sed -i -E "s|^Hostname=.*|Hostname=Zabbix server|" /etc/zabbix/zabbix_agent2.conf

PHP_FPM="$(systemctl list-unit-files 'php*-fpm.service' --no-legend | awk '{print $1}' | head -1)"
systemctl enable -q zabbix-server zabbix-agent2 nginx "${PHP_FPM}"
systemctl restart zabbix-server zabbix-agent2 "${PHP_FPM}" nginx
sleep 5
systemctl is-active zabbix-server zabbix-agent2 nginx "${PHP_FPM}" postgresql | paste -sd' '
zabbix_server -V | head -1

api() { curl -sk -H 'Content-Type: application/json-rpc' ${2:+-H "Authorization: Bearer $2"} -d "$1" https://127.0.0.1/api_jsonrpc.php; }
for _ in $(seq 1 30); do api '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' | grep -q result && break; sleep 2; done
NEW="$(cat /root/zabbix/admin-password)"
tok="$(api '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":1}' | jq -r '.result // empty')"
if [[ -n "${tok}" ]]; then
  api "$(jq -nc --arg p "${NEW}" '{jsonrpc:"2.0",method:"user.update",params:{userid:"1",current_passwd:"zabbix",passwd:$p},id:2}')" "${tok}" | jq -r 'if .result then "Admin password replaced (see /root/zabbix/admin-password)" else .error end'
fi
