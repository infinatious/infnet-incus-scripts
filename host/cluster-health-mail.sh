#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

usage() {
  cat <<'EOF'
Usage: cluster-health-mail.sh [--to ADDRESS] [--dry-run]

Runs cluster-health.sh and emails the report through the SMTP relay
(HEALTH_MAIL_TO, HEALTH_MAIL_FROM and SMTP_RELAY in .env). The subject
carries the summary, e.g. "us-west health: 0 FAIL, 2 WARN".
Run as kauffpc (ssh keys and passwordless sudo to the members), as
infnet-cluster-health-mail.timer does daily at 06:00.

  --to ADDRESS   send to ADDRESS instead of HEALTH_MAIL_TO
  --dry-run      print the subject and plain-text body, send nothing
EOF
}

[[ -f "${ENV_FILE}" ]] || { echo "Error: ${ENV_FILE} not found." >&2; exit 1; }
# shellcheck source=/dev/null
source "${ENV_FILE}"

TO="${HEALTH_MAIL_TO:-}"
DRY_RUN=0
while (( $# )); do
  case "$1" in
    --to) TO="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "${TO}" || "${DRY_RUN}" == 1 ]] || { echo 'Error: set HEALTH_MAIL_TO in .env or pass --to.' >&2; exit 1; }
[[ -n "${SMTP_RELAY:-}" || "${DRY_RUN}" == 1 ]] || { echo 'Error: set SMTP_RELAY in .env.' >&2; exit 1; }

REPORT="$(NO_COLOR=1 "${SCRIPT_DIR}/cluster-health.sh" 2>&1)"
CLUSTER="${HEALTH_CLUSTER_NAME:-$(hostname -s)}"

REPORT="${REPORT}" CLUSTER="${CLUSTER}" TO="${TO}" DRY_RUN="${DRY_RUN}" \
FROM="${HEALTH_MAIL_FROM:-$(hostname -s)@infinatio.us}" RELAY="${SMTP_RELAY:-}" \
python3 - <<'PY'
import html, os, re, smtplib, sys
from email.message import EmailMessage

report = os.environ["REPORT"]
counts = {k: 0 for k in ("OK", "WARN", "FAIL")}
m = re.search(r"Summary:\s*(\d+) OK, (\d+) WARN, (\d+) FAIL", report)
if m:
    counts = dict(zip(("OK", "WARN", "FAIL"), map(int, m.groups())))
    subject = f"{os.environ['CLUSTER']} health: {counts['FAIL']} FAIL, {counts['WARN']} WARN"
else:
    subject = f"{os.environ['CLUSTER']} health: report incomplete"

if os.environ["DRY_RUN"] == "1":
    print(f"Subject: {subject}\n\n{report}")
    sys.exit(0)

# HTML: the same text, monospace, with the status tags and bars coloured.
GREEN, YELLOW, RED, TEAL = "#2e7d32", "#b26a00", "#c62828", "#00838f"
def bar(mt):
    pct = int(mt.group(2))
    color = GREEN if pct < 70 else YELLOW if pct < 85 else RED
    return f'<span style="color:{color}">{mt.group(1)}</span> {mt.group(2)}%'
lines = []
for raw in report.splitlines():
    line = html.escape(raw)
    if raw and not raw.startswith(" ") and not raw.startswith("Summary") and not raw.startswith("INFNET"):
        line = f'<b style="color:{TEAL}">{line}</b>'
    line = line.replace("[ OK ]", f'<b style="color:{GREEN}">[ OK ]</b>')
    line = line.replace("[WARN]", f'<b style="color:{YELLOW}">[WARN]</b>')
    line = line.replace("[FAIL]", f'<b style="color:{RED}">[FAIL]</b>')
    line = re.sub(r"([█░]{10,})\s+(\d+)%", bar, line)
    lines.append(line)
body = ('<pre style="font-family:Menlo,Consolas,monospace;font-size:12px;line-height:1.35">'
        + "\n".join(lines) + "</pre>")

msg = EmailMessage()
msg["From"], msg["To"], msg["Subject"] = os.environ["FROM"], os.environ["TO"], subject
msg.set_content(report)
msg.add_alternative(body, subtype="html")
host, _, port = os.environ["RELAY"].partition(":")
with smtplib.SMTP(host, int(port or 25), timeout=60) as s:
    s.send_message(msg)
print(f"Sent '{subject}' to {os.environ['TO']} via {os.environ['RELAY']}")
PY
