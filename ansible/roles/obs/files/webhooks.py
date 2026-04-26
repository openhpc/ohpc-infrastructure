# WSGI webhook handler for GitHub -> OBS integration
#
# Receives GitHub push webhooks, validates HMAC-SHA256 signatures,
# determines which OBS packages need rebuilding, and triggers
# osc service remoterun / unlock commands in a background thread.
#
# Deployed by Ansible to /srv/www/trigger/webhooks/webhooks.py
# Apache mod_wsgi calls the ``application`` callable directly.
#
# All logging goes to stderr (Apache error log).

import hashlib
import hmac
import json
import logging
import os
import re
import subprocess
import sys
import threading
import traceback
import xml.etree.ElementTree as ET

# ---------------------------------------------------------------------------
# Logging — stderr only (captured by Apache error log)
# ---------------------------------------------------------------------------

logging.basicConfig(
    stream=sys.stderr,
    level=logging.DEBUG,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("webhooks")

# ---------------------------------------------------------------------------
# Configuration — deferred so a broken config never kills the module import
# ---------------------------------------------------------------------------

_HERE = os.path.dirname(os.path.abspath(__file__))
_INIT_ERROR = None
CONFIG = None
SECRET = None
OBS_API = None
BRANCHES = {}
DEFAULT_COMPILER = "gnu15"
DEFAULT_MPI = "openmpi5"
COMPILER_DEPENDENT = set()
MPI_DEPENDENT = set()


def _run_osc_raw(*args):
    """Run an osc command during init (before globals are fully set)."""
    cmd = ["osc", "-A", OBS_API] + list(args)
    log.debug("running: %s", " ".join(cmd))
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        timeout=120,
    )
    if result.returncode != 0:
        log.error(
            "osc failed (rc=%d): %s\nstderr: %s",
            result.returncode,
            " ".join(cmd),
            result.stderr,
        )
    return result.returncode, result.stdout, result.stderr


def _is_project_locked(subproject):
    """Return True if the OBS project has <lock><enable/></lock>."""
    rc, stdout, _ = _run_osc_raw("meta", "prj", subproject)
    if rc != 0:
        log.warning("cannot read meta for %s, assuming unlocked", subproject)
        return False
    try:
        root = ET.fromstring(stdout)
    except ET.ParseError:
        log.warning("cannot parse meta XML for %s, assuming unlocked", subproject)
        return False
    lock = root.find("lock")
    if lock is not None and lock.find("enable") is not None:
        return True
    return False


def _discover_versions(branches_config):
    """Query OBS to find the latest Factory version for each branch.

    Runs ``osc ls`` once to get all projects, then filters for
    ``<Project>:<X.Y>:Factory`` patterns and picks the highest version.
    If a branch entry includes a ``version`` key it is used as-is
    (manual pin).
    """
    rc, stdout, _ = _run_osc_raw("ls")
    if rc != 0:
        raise RuntimeError(
            "Failed to list OBS projects. Is osc configured and the OBS API reachable?"
        )

    all_projects = [p.strip() for p in stdout.splitlines() if p.strip()]
    result = {}

    for key, info in branches_config.items():
        project = info["project"]

        # Allow manual version pin
        if "version" in info:
            result[key] = dict(info)
            log.info("branch %s: using pinned version %s", key, info["version"])
            continue

        # Match <Project>:<X.Y>:Factory (skip update branches like 3.3.1)
        pattern = re.compile(r"^" + re.escape(project) + r":(\d+\.\d+):Factory$")
        versions = []
        for proj_name in all_projects:
            m = pattern.match(proj_name)
            if m:
                ver_str = m.group(1)
                ver_tuple = tuple(int(x) for x in ver_str.split("."))
                versions.append((ver_tuple, ver_str))

        if not versions:
            log.warning(
                "branch %s: no Factory subprojects found for %s, skipping", key, project
            )
            continue

        versions.sort(reverse=True)

        # Pick the highest version whose project is not locked
        latest = None
        for _, ver_str in versions:
            subproj = "%s:%s:Factory" % (project, ver_str)
            if _is_project_locked(subproj):
                log.info("branch %s: skipping %s (locked)", key, subproj)
                continue
            latest = ver_str
            break

        if latest is None:
            log.warning(
                "branch %s: all Factory subprojects for %s are locked, skipping",
                key,
                project,
            )
            continue

        log.info(
            "branch %s: discovered latest %s:%s:Factory",
            key,
            project,
            latest,
        )
        result[key] = {"project": project, "version": latest}

    return result


def _load_config():
    """Load configuration and secret.  Called once on first request."""
    global _INIT_ERROR, CONFIG, SECRET, OBS_API, BRANCHES
    global DEFAULT_COMPILER, DEFAULT_MPI, COMPILER_DEPENDENT, MPI_DEPENDENT

    config_path = os.path.join(_HERE, "webhooks.json")
    if not os.path.isfile(config_path):
        raise FileNotFoundError(
            f"Webhook config file not found: {config_path}\n"
            "Deploy webhooks.json next to webhooks.py."
        )
    with open(config_path, "r") as fp:
        CONFIG = json.load(fp)

    secret_path = os.path.join(_HERE, "webhooks.secret")
    if not os.path.isfile(secret_path):
        raise FileNotFoundError(
            f"Webhook secret file not found: {secret_path}\n"
            "Create this file manually on the server with the GitHub "
            "webhook secret (mode 0600, owned by root).\n"
            "Example:\n"
            "  echo 'your-secret-here' > "
            "/srv/www/trigger/webhooks/webhooks.secret\n"
            "  chmod 0600 /srv/www/trigger/webhooks/webhooks.secret"
        )
    with open(secret_path, "r") as sf:
        secret_text = sf.read().strip()
    if not secret_text:
        raise ValueError(
            f"Webhook secret file is empty: {secret_path}\n"
            "The file must contain the GitHub webhook secret string."
        )
    SECRET = secret_text.encode("utf-8")

    OBS_API = CONFIG["obs_api"]
    DEFAULT_COMPILER = CONFIG.get("default_compiler", "gnu15")
    DEFAULT_MPI = CONFIG.get("default_mpi", "openmpi5")
    COMPILER_DEPENDENT = set(CONFIG.get("compiler_dependent", []))
    MPI_DEPENDENT = set(CONFIG.get("mpi_dependent", []))

    # Discover latest Factory versions from OBS
    BRANCHES = _discover_versions(CONFIG.get("branches", {}))

    log.info("config loaded: obs_api=%s", OBS_API)
    for bkey, binfo in BRANCHES.items():
        log.info(
            "branch %s: project=%s version=%s", bkey, binfo["project"], binfo["version"]
        )
    log.debug("defaults: compiler=%s mpi=%s", DEFAULT_COMPILER, DEFAULT_MPI)
    log.debug("compiler_dependent packages: %s", sorted(COMPILER_DEPENDENT))
    log.debug("mpi_dependent packages: %s", sorted(MPI_DEPENDENT))


# Try to load config eagerly so errors show up at startup.  If it fails,
# store the error and report it on every request instead of crashing the
# module import (which mod_wsgi caches silently).
try:
    _load_config()
except Exception:
    _INIT_ERROR = traceback.format_exc()
    print("webhooks.py: config load failed:\n" + _INIT_ERROR, file=sys.stderr)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _tag_package(category, package):
    """Apply compiler/MPI family suffix based on package lists or category.

    Returns the tagged package name used in OBS.
    """
    if package in COMPILER_DEPENDENT:
        tagged = f"{package}-{DEFAULT_COMPILER}"
        log.debug(
            "tag %s/%s -> %s (compiler_dependent list)", category, package, tagged
        )
        return tagged
    if package in MPI_DEPENDENT:
        tagged = f"{package}-{DEFAULT_COMPILER}-{DEFAULT_MPI}"
        log.debug("tag %s/%s -> %s (mpi_dependent list)", category, package, tagged)
        return tagged

    # Fall back to directory-based tagging
    if category == "serial-libs":
        tagged = f"{package}-{DEFAULT_COMPILER}"
        log.debug("tag %s/%s -> %s (serial-libs dir)", category, package, tagged)
        return tagged
    if category == "parallel-libs":
        tagged = f"{package}-{DEFAULT_COMPILER}-{DEFAULT_MPI}"
        log.debug("tag %s/%s -> %s (parallel-libs dir)", category, package, tagged)
        return tagged

    log.debug("tag %s/%s -> %s (standalone)", category, package, package)
    return package


def _extract_packages(commits):
    """Scan commit file lists and return a set of OBS package names."""
    packages = set()
    for commit in commits:
        sha = commit.get("id", "unknown")[:8]
        for key in ("added", "modified", "removed"):
            for path in commit.get(key, []):
                log.debug("commit %s: %s %s", sha, key, path)
                m = re.match(r"^components/([^/]+)/([^/]+)/", path)
                if m:
                    category, pkg = m.group(1), m.group(2)
                    packages.add(_tag_package(category, pkg))
                elif re.match(r"^docs/recipes/", path):
                    packages.add("docs")
                elif re.match(r"^tests/", path):
                    packages.add("test-suite")
    log.debug("extracted packages: %s", sorted(packages))
    return packages


def _map_branch(ref):
    """Map a git ref to (subproject, branch_key) or (None, None)."""
    # ref looks like "refs/heads/3.x"
    if not ref or not ref.startswith("refs/heads/"):
        return None, None

    branch_name = ref.split("/", 2)[2]
    log.debug("_map_branch: ref=%s branch_name=%s", ref, branch_name)

    for key, info in BRANCHES.items():
        if branch_name == key:
            project = info["project"]
            version = info["version"]

            # Detect update branches like "3.4.1"
            update = re.match(r"^(\d+\.\d+)\.(\d+)$", version)
            if update:
                base, micro = update.group(1), update.group(2)
                subproject = f"{project}:{base}:Update{micro}:Factory"
            else:
                subproject = f"{project}:{version}:Factory"

            return subproject, key

    return None, None


def _run_osc(*args):
    """Run an osc command and return (returncode, stdout, stderr)."""
    cmd = ["osc", "-A", OBS_API] + list(args)
    log.info("running: %s", " ".join(cmd))
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        timeout=120,
    )
    if result.returncode != 0:
        log.error(
            "osc failed (rc=%d): %s\nstderr: %s",
            result.returncode,
            " ".join(cmd),
            result.stderr,
        )
    else:
        log.debug("osc ok: %s\nstdout: %s", " ".join(cmd), result.stdout.strip())
    return result.returncode, result.stdout, result.stderr


def _unlock_package(subproject, package):
    """Unlock a package and remove the marker file."""
    log.info("unlocking %s/%s", subproject, package)
    _run_osc(
        "unlock",
        subproject,
        package,
        "-m",
        "obs-trigger: releasing first build",
    )
    _run_osc("rremove", "-f", subproject, package, "_obs_config_ready_for_build")


def _process_rebuilds(subproject, packages):
    """Background worker: trigger rebuilds and unlock packages."""
    log.debug(
        "background thread started: subproject=%s packages=%s",
        subproject,
        sorted(packages),
    )
    for package in packages:
        log.info("triggering rebuild: %s %s", subproject, package)
        _run_osc("service", "remoterun", subproject, package)

        # Check for lock marker
        rc, stdout, _ = _run_osc("list", subproject, package)
        if rc != 0:
            continue
        if "_obs_config_ready_for_build" not in stdout:
            log.debug("no lock marker for %s/%s, skipping unlock", subproject, package)
            continue

        _unlock_package(subproject, package)

        # Check linked (child) packages
        rc, stdout, _ = _run_osc(
            "api",
            "-X",
            "POST",
            f"/source/{subproject}/{package}?cmd=showlinked",
        )
        if rc != 0 or not stdout:
            continue

        try:
            root = ET.fromstring(stdout)
        except ET.ParseError:
            log.error("failed to parse showlinked XML for %s", package)
            continue

        children = list(root.iter("package"))
        log.debug(
            "showlinked returned %d linked packages for %s", len(children), package
        )
        for elem in children:
            child_project = elem.get("project", "")
            child_name = elem.get("name", "")
            if child_project != subproject or not child_name:
                log.debug(
                    "skipping linked package %s/%s (wrong project)",
                    child_project,
                    child_name,
                )
                continue
            log.debug("checking child package %s/%s", subproject, child_name)

            rc2, child_stdout, _ = _run_osc(
                "list",
                subproject,
                child_name,
            )
            if rc2 == 0 and "_obs_config_ready_for_build" in child_stdout:
                _unlock_package(subproject, child_name)


# ---------------------------------------------------------------------------
# WSGI application
# ---------------------------------------------------------------------------


def application(environ, start_response):
    """WSGI entry point for mod_wsgi / Apache."""

    # If config failed to load, return the error on every request so it
    # is visible in both the HTTP response and the Apache error log.
    if _INIT_ERROR:
        log.error("returning 500 due to config error:\n%s", _INIT_ERROR)
        start_response(
            "500 Internal Server Error",
            [
                ("Content-Type", "text/plain"),
            ],
        )
        return [("webhooks.py failed to initialise.\n\n" + _INIT_ERROR).encode()]

    method = environ.get("REQUEST_METHOD", "GET")
    remote = environ.get("REMOTE_ADDR", "unknown")
    log.debug("request: method=%s remote=%s", method, remote)

    if method != "POST":
        start_response(
            "405 Method Not Allowed",
            [
                ("Content-Type", "application/json"),
                ("Allow", "POST"),
            ],
        )
        return [json.dumps({"error": "method not allowed"}).encode()]

    # Read request body
    try:
        length = int(environ.get("CONTENT_LENGTH", 0))
    except (ValueError, TypeError):
        length = 0
    body = environ["wsgi.input"].read(length)

    # Validate HMAC-SHA256
    sig_header = environ.get("HTTP_X_HUB_SIGNATURE_256", "")
    if not sig_header.startswith("sha256="):
        log.warning("missing or malformed X-Hub-Signature-256 header")
        start_response(
            "403 Forbidden",
            [
                ("Content-Type", "application/json"),
            ],
        )
        return [json.dumps({"error": "invalid signature"}).encode()]

    expected = hmac.new(SECRET, body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, sig_header[7:]):
        log.warning("HMAC signature mismatch")
        start_response(
            "403 Forbidden",
            [
                ("Content-Type", "application/json"),
            ],
        )
        return [json.dumps({"error": "invalid signature"}).encode()]

    log.debug("HMAC signature validated successfully")

    # Handle ping
    event = environ.get("HTTP_X_GITHUB_EVENT", "ping")
    log.debug("event=%s", event)
    if event == "ping":
        start_response(
            "200 OK",
            [
                ("Content-Type", "application/json"),
            ],
        )
        return [json.dumps({"msg": "pong"}).encode()]

    # Parse payload
    try:
        payload = json.loads(body)
    except (json.JSONDecodeError, ValueError):
        log.warning("invalid JSON payload")
        start_response(
            "400 Bad Request",
            [
                ("Content-Type", "application/json"),
            ],
        )
        return [json.dumps({"error": "bad payload"}).encode()]

    # Only handle push events
    if event != "push":
        start_response(
            "200 OK",
            [
                ("Content-Type", "application/json"),
            ],
        )
        return [json.dumps({"status": "ignored", "event": event}).encode()]

    # Skip push-delete events
    if payload.get("deleted", False):
        log.info("skipping push-delete event")
        start_response(
            "200 OK",
            [
                ("Content-Type", "application/json"),
            ],
        )
        return [json.dumps({"status": "skipped_delete"}).encode()]

    # Map branch to OBS project
    ref = payload.get("ref", "")
    num_commits = len(payload.get("commits", []))
    pusher = payload.get("pusher", {}).get("name", "unknown")
    log.debug("push: ref=%s commits=%d pusher=%s", ref, num_commits, pusher)
    subproject, branch_key = _map_branch(ref)
    if not subproject:
        log.info("ref %s does not map to a known branch", ref)
        start_response(
            "200 OK",
            [
                ("Content-Type", "application/json"),
            ],
        )
        return [
            json.dumps(
                {
                    "status": "ignored",
                    "reason": "unknown branch",
                    "ref": ref,
                }
            ).encode()
        ]

    # Determine changed packages
    commits = payload.get("commits", [])
    packages = _extract_packages(commits)

    if not packages:
        log.info("no relevant packages changed in %s", ref)
        start_response(
            "200 OK",
            [
                ("Content-Type", "application/json"),
            ],
        )
        return [
            json.dumps(
                {
                    "status": "no_packages",
                    "ref": ref,
                }
            ).encode()
        ]

    log.info(
        "queuing rebuilds: subproject=%s packages=%s",
        subproject,
        sorted(packages),
    )

    # Spawn background thread for OBS commands
    thread = threading.Thread(
        target=_process_rebuilds,
        args=(subproject, packages),
        daemon=True,
    )
    thread.start()

    # Return immediately so GitHub does not time out
    start_response(
        "200 OK",
        [
            ("Content-Type", "application/json"),
        ],
    )
    return [
        json.dumps(
            {
                "status": "queued",
                "subproject": subproject,
                "packages": sorted(packages),
            }
        ).encode()
    ]
