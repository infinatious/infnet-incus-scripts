#!/usr/bin/env python3
"""HTTP gateway between the web UI and ops/ops-job.sh.

The UI used to run ops-job.sh through the Incus exec API on the ops runner,
which needs exec rights on a container holding an admin certificate. This
service replaces that path: it exposes only the ops actions, identifies the
caller through Incus itself and asks OpenFGA what the caller may do, so a
project operator can use the scripted flows for their own project and nothing
else.

  GET  /ops/api/me            {"user", "admin"}
  GET  /ops/api/backups       list-backups, filtered to projects the caller can view
  GET  /ops/api/jobs          list-jobs, filtered the same way
  GET  /ops/api/jobs/<id>     {"status", "log"} of one job
  POST /ops/api/jobs          {"action", "params"} -> {"id"}

Identity: the caller's cookies/Authorization header are forwarded to
GET /1.0 on the Incus API, which validates the OIDC token and reports the user.
Authorization: OpenFGA checks (the same store Incus uses), by e-mail.
"""
import hashlib
import json
import os
import re
import ssl
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PREFIX = "/ops/api"
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
JOB_RE = re.compile(r"^[A-Za-z0-9-]{6,64}$")
EMAIL_RE = re.compile(r"^[^\s:#@]+@[^\s:#@]+$")
MAX_BODY = 32 * 1024
MAX_LOG = 1024 * 1024

# Actions a project operator may start, and the OpenFGA relation each needs on
# every project it touches. Everything else (create/delete project) is for
# server admins only.
PROJECT_ACTIONS = {
    "backup": "can_create_instances",
    "restore": "can_create_instances",
    "create-instance": "can_create_instances",
    "delete-instance": "can_create_instances",
}
ADMIN_ACTIONS = {"create-project", "delete-project"}


class Denied(Exception):
    def __init__(self, message, status=403):
        super().__init__(message)
        self.status = status


def job_projects(params):
    """Every project a job's arguments name (empty for create-project)."""
    projects = set()
    if isinstance(params.get("project"), str):
        projects.add(params["project"])
    items = params.get("items")
    if isinstance(items, list):
        for item in items:
            if isinstance(item, dict) and isinstance(item.get("project"), str):
                projects.add(item["project"])
    return projects


def authorize_start(check, user, admin, action, params, backup_dir):
    """Raise Denied unless `user` may start `action`. check(user, rel, obj)."""
    if not isinstance(params, dict):
        raise Denied("params must be an object", 400)
    if action not in PROJECT_ACTIONS and action not in ADMIN_ACTIONS:
        raise Denied("unknown action", 400)
    if admin:
        return
    if action in ADMIN_ACTIONS:
        raise Denied("this action is for administrators")
    projects = job_projects(params)
    if not projects:
        raise Denied("no project given", 400)
    for project in projects:
        if not NAME_RE.match(project):
            raise Denied("invalid project name", 400)
        if not check(user, PROJECT_ACTIONS[action], f"project:{project}"):
            raise Denied(f"you may not do this in project {project}")
    if action == "restore":
        # A backup of another project must never be restorable here.
        project = params.get("project", "")
        instance = params.get("instance", "")
        backup_file = params.get("backup_file", "")
        prefix = f"{backup_dir.rstrip('/')}/{project}/{instance}/"
        if (
            not isinstance(backup_file, str)
            or not NAME_RE.match(str(instance))
            or not backup_file.startswith(prefix)
            or ".." in backup_file
        ):
            raise Denied("that backup does not belong to this instance")


def visible_to(check, user, admin, params):
    """May `user` see a job or backup tied to these projects?"""
    if admin:
        return True
    projects = job_projects(params)
    return bool(projects) and all(
        NAME_RE.match(p) and check(user, "can_view", f"project:{p}") for p in projects
    )


class Gateway:
    def __init__(self, env):
        self.env = env
        self.ops_job = env["OPS_JOB"]
        self.jobs_dir = env.get("OPS_JOBS_DIR", "/var/lib/infnet-ops/jobs")
        self.backup_dir = env["NFS_BACKUP_DIR"]
        self.incus_url = env["INCUS_URL"].rstrip("/")
        self.fga_url = env["OPENFGA_URL"].rstrip("/")
        self.fga_store = env["OPENFGA_STORE"]
        self.fga_token = env["OPENFGA_TOKEN"]
        self.ctx = ssl.create_default_context(cafile=env["INCUS_CA"])
        self.ctx.check_hostname = False  # the cluster certificate is pinned by file
        self._cache = {}
        self._lock = threading.Lock()

    def _cached(self, key, ttl, fn):
        now = time.monotonic()
        with self._lock:
            hit = self._cache.get(key)
            if hit and hit[0] > now:
                return hit[1]
        value = fn()
        with self._lock:
            if len(self._cache) > 2000:
                self._cache.clear()
            self._cache[key] = (now + ttl, value)
        return value

    def identify(self, headers):
        """The OIDC e-mail Incus sees for these credentials, or None."""
        cookie = headers.get("Cookie", "")
        auth = headers.get("Authorization", "")
        if not cookie and not auth:
            return None
        key = "id:" + hashlib.sha256((cookie + "\0" + auth).encode()).hexdigest()

        def lookup():
            req = urllib.request.Request(self.incus_url + "/1.0")
            if cookie:
                req.add_header("Cookie", cookie)
            if auth:
                req.add_header("Authorization", auth)
            try:
                with urllib.request.urlopen(req, context=self.ctx, timeout=10) as resp:
                    meta = json.load(resp).get("metadata", {})
            except Exception as exc:  # network or Incus error: treat as not signed in
                print(f"identify failed: {exc}", file=sys.stderr)
                return None
            if meta.get("auth") != "trusted" or meta.get("auth_user_method") != "oidc":
                return None
            name = meta.get("auth_user_name", "")
            return name if EMAIL_RE.match(name) else None

        return self._cached(key, 20, lookup)

    def check(self, user, relation, obj):
        def ask():
            body = json.dumps(
                {"tuple_key": {"user": f"user:{user}", "relation": relation, "object": obj}}
            ).encode()
            req = urllib.request.Request(
                f"{self.fga_url}/stores/{self.fga_store}/check",
                data=body,
                headers={
                    "Authorization": f"Bearer {self.fga_token}",
                    "Content-Type": "application/json",
                },
            )
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:
                    return bool(json.load(resp).get("allowed"))
            except Exception as exc:  # fail closed
                print(f"openfga check failed: {exc}", file=sys.stderr)
                return False

        return self._cached(f"fga:{user}:{relation}:{obj}", 10, ask)

    def is_admin(self, user):
        return self.check(user, "can_edit", "server:incus")

    def run_ops(self, args, timeout=180):
        proc = subprocess.run(
            [self.ops_job, *args],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout + (proc.stderr if proc.returncode else "")

    def read_job(self, job_id):
        base = os.path.join(self.jobs_dir, job_id)
        try:
            with open(os.path.join(base, "status.json")) as fh:
                status = json.load(fh)
        except (OSError, ValueError):
            return None, ""
        try:
            with open(os.path.join(base, "log"), "rb") as fh:
                fh.seek(0, os.SEEK_END)
                size = fh.tell()
                fh.seek(max(0, size - MAX_LOG))
                log = fh.read().decode("utf-8", "replace")
        except OSError:
            log = ""
        return status, log


def make_handler(gw):
    class Handler(BaseHTTPRequestHandler):
        server_version = "ops-gateway"

        def log_message(self, fmt, *args):
            print(f"{self.address_string()} {fmt % args}", file=sys.stderr)

        def _send(self, status, payload):
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _user(self):
            user = gw.identify(self.headers)
            if not user:
                raise Denied("not signed in", 401)
            return user, gw.is_admin(user)

        def _dispatch(self, method):
            try:
                path = self.path.split("?", 1)[0]
                if not path.startswith(PREFIX):
                    raise Denied("not found", 404)
                route = path[len(PREFIX):]
                user, admin = self._user()
                if method == "GET" and route == "/me":
                    return self._send(200, {"user": user, "admin": admin})
                if method == "GET" and route == "/backups":
                    code, out = gw.run_ops(["list-backups"])
                    if code != 0:
                        raise Denied(out.strip() or "listing backups failed", 502)
                    data = json.loads(out)
                    data["backups"] = [
                        b
                        for b in data.get("backups", [])
                        if visible_to(gw.check, user, admin, {"project": b.get("project", "")})
                    ]
                    return self._send(200, data)
                if method == "GET" and route == "/jobs":
                    code, out = gw.run_ops(["list-jobs"])
                    if code != 0:
                        return self._send(200, [])
                    jobs = [
                        j
                        for j in json.loads(out or "[]")
                        if visible_to(gw.check, user, admin, j.get("params") or {})
                    ]
                    return self._send(200, jobs)
                match = re.fullmatch(r"/jobs/([A-Za-z0-9-]{6,64})", route)
                if method == "GET" and match:
                    status, log = gw.read_job(match.group(1))
                    if status is None or not visible_to(
                        gw.check, user, admin, status.get("params") or {}
                    ):
                        raise Denied("not found", 404)
                    return self._send(200, {"status": status, "log": log})
                if method == "POST" and route == "/jobs":
                    length = int(self.headers.get("Content-Length", "0"))
                    if length <= 0 or length > MAX_BODY:
                        raise Denied("bad request body", 400)
                    body = json.loads(self.rfile.read(length))
                    action = body.get("action")
                    params = body.get("params")
                    if not isinstance(action, str):
                        raise Denied("action required", 400)
                    authorize_start(gw.check, user, admin, action, params, gw.backup_dir)
                    params = dict(params)
                    params["requested_by"] = user
                    job_id = time.strftime("%Y%m%d%H%M%S", time.gmtime()) + "-" + hashlib.sha256(
                        os.urandom(16)
                    ).hexdigest()[:6]
                    code, out = gw.run_ops(["start", job_id, action, json.dumps(params)], timeout=30)
                    print(f"job {job_id} {action} by {user} projects={sorted(job_projects(params))}", file=sys.stderr)
                    if code != 0:
                        raise Denied(out.strip() or "could not start the job", 500)
                    return self._send(200, {"id": job_id})
                raise Denied("not found", 404)
            except Denied as exc:
                self._send(exc.status, {"error": str(exc)})
            except (ValueError, KeyError) as exc:
                self._send(400, {"error": f"bad request: {exc}"})
            except Exception as exc:  # never leak internals
                print(f"error: {exc!r}", file=sys.stderr)
                self._send(500, {"error": "internal error"})

        def do_GET(self):
            self._dispatch("GET")

        def do_POST(self):
            self._dispatch("POST")

    return Handler


def load_env(path):
    env = dict(os.environ)
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                env[key.strip()] = value.strip().strip("'\"")
    return env


def main():
    env = load_env(sys.argv[1] if len(sys.argv) > 1 else "/etc/infnet-ops-gateway.env")
    gw = Gateway(env)
    server = ThreadingHTTPServer((env.get("LISTEN", "0.0.0.0"), int(env.get("PORT", "8091"))), make_handler(gw))
    print(f"ops-gateway listening on {env.get('LISTEN', '0.0.0.0')}:{env.get('PORT', '8091')}", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    main()
