#!/usr/bin/env bash
# Installs zabbix-agent2 in ACTIVE mode only: the agent connects out to the
# Zabbix server (tcp/10051) and never listens, so instances need no inbound
# firewall rule. Runs inside an instance (Ubuntu 26.04, AlmaLinux 9/10):
#   - at first boot from the Linux profiles' cloud-init (deploy-project.sh adds
#     it when ZABBIX_SERVER_ACTIVE is set in .env), or
#   - pushed by monitoring/install-zabbix-agent.sh for existing instances.
# Usage: zabbix-agent-install.sh '<ServerActive>' ['<HostMetadata>']
#   ServerActive: e.g. '137.152.231.61;10.125.25.4' - the public IP first, then
#   the internal one, which the agent falls back to when the public one can't
#   be reached (instances in the Zabbix server's own project: hairpin NAT).
set -euo pipefail

SERVER_ACTIVE="${1:?usage: $0 '<ServerActive>' ['<HostMetadata>']}"
HOST_METADATA="${2:-infnet}"
ZABBIX_VERSION="${ZABBIX_VERSION:-7.4}"

. /etc/os-release
case " ${ID} ${ID_LIKE:-} " in
  *" rhel "*|*" centos "*|*" fedora "*)
    major="${VERSION_ID%%.*}"
    rpm -q zabbix-release >/dev/null 2>&1 \
      || rpm -Uvh --quiet "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/alma/${major}/noarch/zabbix-release-latest-${ZABBIX_VERSION}.el${major}.noarch.rpm" 2>/dev/null \
      || rpm -Uvh --quiet "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/alma/${major}/noarch/zabbix-release-latest.el${major}.noarch.rpm"
    # EPEL carries its own, older Zabbix packages.
    dnf -y -q --disablerepo='epel*' install zabbix-agent2
    ;;
  *)
    export DEBIAN_FRONTEND=noninteractive
    if ! dpkg -s zabbix-release >/dev/null 2>&1; then
      curl -fsSL -o /tmp/zabbix-release.deb "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+ubuntu${VERSION_ID}_all.deb"
      dpkg -i /tmp/zabbix-release.deb >/dev/null
    fi
    apt-get -qq update
    apt-get -qq install -y zabbix-agent2 >/dev/null
    ;;
esac

# The packaged config sets Server, ServerActive and Hostname=Zabbix server;
# comment them out so the drop-in below is the only definition. Without
# Hostname the agent uses the system hostname, i.e. the instance name, which
# is the host name the scripts register in Zabbix.
sed -i -E 's/^(Server|ServerActive|Hostname)=/# &/' /etc/zabbix/zabbix_agent2.conf
cat > /etc/zabbix/zabbix_agent2.d/infnet.conf <<EOF
# Managed by infnet-incus-scripts (monitoring/zabbix-agent-install.sh).
# Active checks only; Server is empty so the agent doesn't listen.
Server=
ServerActive=${SERVER_ACTIVE}
HostMetadata=${HOST_METADATA}
EOF
systemctl enable -q zabbix-agent2
systemctl restart zabbix-agent2
echo "zabbix-agent2 $(zabbix_agent2 -V 2>/dev/null | head -1 | awk '{print $NF}') reporting to ${SERVER_ACTIVE} as $(hostname)"
