#!/usr/bin/env python3
#
# Utility to rebuild OBS-built SRPMs in Fedora COPR.
#
# --srpm-dir is the OBS build directory (usually /srv/obs/build):
#   <srpm-dir>/OpenHPC4:4.3:Factory/EL_10/aarch64/<package>/*.src.rpm
# All releases of one major version are searched and only the SRPM from the
# highest release is built for each package. Scan mode does this once, watch
# mode repeats it every --scan-interval seconds.
#
# The SRPMs are built one after the other. An SRPM is built after the SRPMs
# that provide its build dependencies. The dependencies are read from the RPM
# headers of the SRPM and of the binary RPMs in the same package directory.
# --
import argparse
import json
import logging
import os
import re
import signal
import struct
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

import coloredlogs
from copr.v3 import Client
from copr.v3.exceptions import CoprAuthException, CoprException

try:
    import rpmfile
except ImportError:
    rpmfile = None

logger = logging.getLogger(__name__)

# Terminal build states from copr.v3
TERMINAL_STATES = ("succeeded", "skipped", "failed", "canceled")

# No RPM header contains the dependency on these packages. ohpc-filesystem
# installs the RPM macros that every other package needs for its build, and
# ohpc-buildroot needs the modules environment that lmod-ohpc provides.
FOUNDATION_PACKAGES = ("ohpc-filesystem", "lmod-ohpc")

# Default retry settings for transient errors
MAX_RETRIES = 5
RETRY_BASE_SECONDS = 10


def ERROR(output):
    logger.error(output)
    sys.exit(1)


def now_iso():
    """Return current UTC time as ISO 8601 string."""
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%S")


class CoprBridge:
    """Bridge OBS SRPMs to Fedora COPR builds."""

    STATE_VERSION = 1

    def __init__(self, args):
        self.srpm_dir = args.srpm_dir
        self.distro = args.distro
        self.arch = args.arch
        self.scan_interval = args.scan_interval
        self.copr_project = args.copr_project or f"@openhpc/openhpc-{args.major}.x"
        # OBS names a patch release either 4.2.1 or 4.2:Update1.
        self.release_pattern = re.compile(
            rf"^OpenHPC\d*:{args.major}\.(\d+)(?:\.(\d+)|:Update(\d+))?:Factory$"
        )
        self.chroot = args.chroot
        self.state_file = args.state_file
        self.dryrun = args.dryrun
        self.ignore_errors = args.ignore_errors
        self.force_rebuild = args.force_rebuild
        self.poll_interval = args.poll_interval
        self.debug = args.debug

        self.skip_patterns = [re.compile(p) for p in args.skip_pattern]
        self.include_patterns = [re.compile(p) for p in args.include_pattern]

        self.ownername, self.projectname = self._parse_copr_project()

        if not self.dryrun:
            config_path = getattr(args, "copr_config", None)
            if config_path:
                self.client = Client.create_from_config_file(Path(config_path))
            else:
                self.client = Client.create_from_config_file()
        else:
            self.client = None

        self.state = self.load_state()
        self._shutdown = False
        # A failed or dry-run SRPM is not marked as processed in the state
        # file. Without this set watch mode would submit it again on every
        # rescan.
        self._attempted = set()
        self._last_scan = None

    def _parse_copr_project(self):
        """Split copr_project into (ownername, projectname)."""
        if "/" not in self.copr_project:
            ERROR(
                f"Invalid --copr-project format '{self.copr_project}'. "
                "Expected 'owner/project' or '@group/project'."
            )
        parts = self.copr_project.split("/", 1)
        return parts[0], parts[1]

    def load_state(self):
        """Load state from JSON file. Return empty state if missing or corrupt."""
        if not os.path.exists(self.state_file):
            logger.debug("No state file found at %s, starting fresh", self.state_file)
            return self._empty_state()

        try:
            with open(self.state_file) as f:
                state = json.load(f)
            logger.info(
                "Loaded state from %s (%d builds tracked)",
                self.state_file,
                len(state.get("builds", {})),
            )
            return state
        except (json.JSONDecodeError, OSError) as e:
            logger.warning(
                "Failed to read state file %s: %s. Starting with empty state.",
                self.state_file,
                e,
            )
            return self._empty_state()

    def _empty_state(self):
        return {
            "version": self.STATE_VERSION,
            "srpm_dir": self.srpm_dir,
            "copr_project": self.copr_project,
            "chroot": self.chroot,
            "builds": {},
            "last_succeeded": None,
            "blocked_on": None,
        }

    def save_state(self):
        """Write state to JSON file atomically (write temp, then rename)."""
        tmp_path = self.state_file + ".tmp"
        try:
            with open(tmp_path, "w") as f:
                json.dump(self.state, f, indent=2)
                f.write("\n")
            os.rename(tmp_path, self.state_file)
        except OSError as e:
            logger.error("Failed to save state file: %s", e)

    def _parse_release(self, project_name):
        """Return (minor, patch) for an OBS project of the major release."""
        m = self.release_pattern.match(project_name)
        if not m:
            return None
        return int(m.group(1)), int(m.group(2) or m.group(3) or 0)

    def _sleep(self, seconds):
        """Sleep in one second steps so that a signal ends the wait early."""
        deadline = time.monotonic() + seconds
        while not self._shutdown and time.monotonic() < deadline:
            time.sleep(1)

    def scan_srpms(self):
        """Return the newest SRPM of each package, sorted by mtime ascending."""
        srpm_dir = Path(self.srpm_dir)
        if not srpm_dir.is_dir():
            ERROR(f"SRPM directory does not exist: {self.srpm_dir}")

        releases = []
        for project_dir in srpm_dir.iterdir():
            release = self._parse_release(project_dir.name)
            if release is not None:
                releases.append((release, project_dir))
        releases.sort()

        total = 0
        newest = {}
        for release, project_dir in releases:
            # OBS keeps its own data in directories like ":full" and ":repo".
            pattern = f"{self.distro}/{self.arch}/[!:]*/*.src.rpm"
            for srpm_path in project_dir.glob(pattern):
                nvr = self._parse_srpm_nvr(srpm_path.name)
                if nvr is None:
                    logger.warning("Could not parse NVR from %s, ignoring", srpm_path)
                    continue
                try:
                    mtime = srpm_path.stat().st_mtime
                except FileNotFoundError:
                    # OBS replaced the SRPM between the glob and the stat.
                    continue
                total += 1
                candidate = (release, mtime, srpm_path)
                if nvr[0] not in newest or candidate[:2] > newest[nvr[0]][:2]:
                    newest[nvr[0]] = candidate

        summary = (
            f"Found {total} SRPMs for {self.distro}/{self.arch} in "
            f"{len(releases)} releases, {len(newest)} are the newest of their package"
        )
        logger.log(
            logging.INFO if summary != self._last_scan else logging.DEBUG, summary
        )
        self._last_scan = summary

        srpms = sorted(newest.values(), key=lambda c: c[1])
        return [srpm_path for _release, _mtime, srpm_path in srpms]

    def should_process(self, srpm_name):
        """Check if an SRPM should be processed based on include/skip patterns."""
        if self.include_patterns and not any(
            p.search(srpm_name) for p in self.include_patterns
        ):
            logger.debug("SRPM %s: no include pattern matched, skipping", srpm_name)
            return False

        for pattern in self.skip_patterns:
            if pattern.search(srpm_name):
                logger.debug(
                    "SRPM %s: matched skip pattern '%s'",
                    srpm_name,
                    pattern.pattern,
                )
                return False

        return True

    def already_processed(self, srpm_name):
        """Check if an SRPM was already processed in a prior run."""
        if srpm_name not in self.state["builds"]:
            return False

        entry = self.state["builds"][srpm_name]
        # Dry-run entries do not count as processed
        if entry.get("reason") == "dry-run":
            return False
        # --force-rebuild overrides the COPR existence check
        if self.force_rebuild and entry.get("reason") == "already-in-copr":
            return False
        return entry["status"] in ("succeeded", "skipped")

    def submit_build(self, srpm_path):
        """Upload SRPM to COPR and return the build object."""
        logger.info("Submitting %s to COPR %s", srpm_path.name, self.copr_project)

        try:
            buildopts = {}
            if self.chroot:
                buildopts["chroots"] = [self.chroot]
            build = self.client.build_proxy.create_from_file(
                ownername=self.ownername,
                projectname=self.projectname,
                path=str(srpm_path),
                buildopts=buildopts if buildopts else None,
            )
            logger.info(
                "Build submitted: id=%d, url=https://copr.fedorainfracloud.org"
                "/coprs/build/%d/",
                build.id,
                build.id,
            )
            return build
        except CoprAuthException as e:
            ERROR(f"COPR authentication failed: {e}\nCheck your ~/.config/copr token.")
        except CoprException as e:
            logger.error("COPR API error submitting %s: %s", srpm_path.name, e)
            return None

    def poll_build(self, build_id):
        """Poll COPR for build status until a terminal state is reached."""
        last_state = None
        retries = 0

        while not self._shutdown:
            try:
                build = self.client.build_proxy.get(build_id)
                retries = 0
            except (CoprException, OSError) as e:
                retries += 1
                if retries > MAX_RETRIES:
                    logger.error(
                        "Failed to poll build %d after %d retries: %s",
                        build_id,
                        MAX_RETRIES,
                        e,
                    )
                    return None
                wait_time = RETRY_BASE_SECONDS * (2 ** (retries - 1))
                logger.warning(
                    "Poll failed (attempt %d/%d), retrying in %ds: %s",
                    retries,
                    MAX_RETRIES,
                    wait_time,
                    e,
                )
                time.sleep(wait_time)
                continue

            if build.state != last_state:
                logger.info(
                    "Build %d: %s -> %s",
                    build_id,
                    last_state or "(new)",
                    build.state,
                )
                last_state = build.state

            if build.state in TERMINAL_STATES:
                return build

            if build.state == "unknown":
                logger.error("Build %d entered unknown state", build_id)
                return build

            self._sleep(self.poll_interval)

        return None

    def process_srpm(self, srpm_path):
        """Submit an SRPM to COPR, poll until done, update state. Return True on success."""
        srpm_name = srpm_path.name
        mtime = srpm_path.stat().st_mtime

        entry = self.state["builds"].get(srpm_name, {})
        resume = entry.get("status") == "pending" and entry.get("copr_build_id")

        if self.dryrun and resume:
            logger.info("[dry-run] Would resume COPR build for %s", srpm_name)
            return True

        if self.dryrun:
            logger.info("[dry-run] Would submit %s to %s", srpm_name, self.copr_project)
            self.state["builds"][srpm_name] = {
                "status": "skipped",
                "reason": "dry-run",
                "mtime": mtime,
            }
            self.save_state()
            return True

        if resume:
            # The bridge was stopped while this build was running in COPR.
            # Submitting the SRPM again would start a duplicate build.
            build_id = entry["copr_build_id"]
            logger.info("Resuming COPR build %d for %s", build_id, srpm_name)
        else:
            build = self.submit_build(srpm_path)
            if build is None:
                self.state["builds"][srpm_name] = {
                    "status": "failed",
                    "reason": "submission error",
                    "submitted_at": now_iso(),
                    "mtime": mtime,
                }
                self.state["blocked_on"] = srpm_name
                self.save_state()
                return False

            build_id = build.id
            self.state["builds"][srpm_name] = {
                "status": "pending",
                "copr_build_id": build_id,
                "submitted_at": now_iso(),
                "mtime": mtime,
            }
            self.save_state()

        result = self.poll_build(build_id)

        if result is None and self._shutdown:
            logger.info("Build %d stays pending and is resumed on restart", build_id)
            return False

        if result is None:
            self.state["builds"][srpm_name]["status"] = "failed"
            self.state["builds"][srpm_name]["reason"] = "poll failure"
            self.state["builds"][srpm_name]["completed_at"] = now_iso()
            self.state["blocked_on"] = srpm_name
            self.save_state()
            return False

        build_url = f"https://copr.fedorainfracloud.org/coprs/build/{result.id}/"

        if result.state == "succeeded":
            self.state["builds"][srpm_name]["status"] = "succeeded"
            self.state["builds"][srpm_name]["completed_at"] = now_iso()
            self.state["last_succeeded"] = srpm_name
            self.save_state()
            logger.info("Build succeeded: %s (%s)", srpm_name, build_url)
            return True

        self.state["builds"][srpm_name]["status"] = result.state
        self.state["builds"][srpm_name]["completed_at"] = now_iso()
        self.state["builds"][srpm_name]["build_url"] = build_url
        self.state["blocked_on"] = srpm_name
        self.save_state()
        logger.error("Build %s for %s. See: %s", result.state, srpm_name, build_url)
        return False

    @staticmethod
    def _parse_srpm_nvr(srpm_name):
        """Parse (name, version, release) from SRPM filename.

        For example 'ohpc-filesystem-4.2-420.ohpc.1.1.src.rpm'
        returns ('ohpc-filesystem', '4.2', '420.ohpc.1.1').
        """
        base = srpm_name
        base = base.removesuffix(".src.rpm")
        parts = base.rsplit("-", 2)
        if len(parts) != 3:
            return None
        return parts[0], parts[1], parts[2]

    def _fetch_existing_builds(self):
        """Fetch successful builds from COPR, return set of (name, version-release)."""
        if self.client is None or self.force_rebuild:
            return set()

        logger.info("Checking existing builds in COPR %s ...", self.copr_project)
        existing = set()
        offset = 0
        limit = 100

        try:
            while True:
                builds = self.client.build_proxy.get_list(
                    ownername=self.ownername,
                    projectname=self.projectname,
                    pagination={"limit": limit, "offset": offset},
                )
                if not builds:
                    break
                for build in builds:
                    if build.state != "succeeded":
                        continue
                    pkg = build.source_package
                    if not pkg:
                        continue
                    name = pkg.get("name")
                    version = pkg.get("version")
                    if name and version:
                        existing.add((name, version))
                if len(builds) < limit:
                    break
                offset += limit
        except (CoprException, OSError) as e:
            logger.warning("Failed to fetch existing builds from COPR: %s", e)
            logger.warning("Proceeding without COPR build check")
            return set()

        logger.info("Found %d unique successful builds in COPR", len(existing))
        return existing

    def _already_in_copr(self, srpm_name, existing_builds):
        """Check if an SRPM already has a successful build in COPR."""
        if not existing_builds:
            return False
        nvr = self._parse_srpm_nvr(srpm_name)
        if nvr is None:
            logger.warning("Could not parse NVR from %s, will not skip", srpm_name)
            return False
        name, version, release = nvr
        return (name, f"{version}-{release}") in existing_builds

    def _auto_reset_blocked(self):
        """If processing is blocked on a failed SRPM, reset it automatically."""
        blocked = self.state.get("blocked_on")
        if not blocked:
            return
        entry = self.state["builds"].get(blocked)
        if entry and entry["status"] in ("failed", "canceled"):
            logger.warning(
                "Auto-resetting previously failed SRPM '%s' for retry",
                blocked,
            )
            del self.state["builds"][blocked]
        self.state["blocked_on"] = None
        self.save_state()

    def _skip(self, srpm_path, reason):
        self.state["builds"][srpm_path.name] = {
            "status": "skipped",
            "reason": reason,
            "mtime": srpm_path.stat().st_mtime,
        }
        self.save_state()

    @staticmethod
    def _read_header(rpm_path, tag):
        """Return the list of strings that an RPM header stores for tag."""
        try:
            with rpmfile.open(rpm_path) as rpm:
                values = rpm.headers.get(tag, [])
        except (OSError, ValueError, AssertionError, struct.error) as e:
            logger.warning("Cannot read the RPM header of %s: %s", rpm_path, e)
            return []
        if not isinstance(values, list):
            values = [values]
        return [v.decode() if isinstance(v, bytes) else str(v) for v in values]

    def _dependencies(self, srpms):
        """Map each SRPM name to the names of the SRPMs it has to be built after."""
        provider = {}
        requires = {}
        foundation = {}
        for srpm_path in srpms:
            name = srpm_path.name
            package = self._parse_srpm_nvr(name)[0]
            if package in FOUNDATION_PACKAGES:
                foundation[package] = name
            # The requirements of an SRPM are the BuildRequires of its spec file.
            requires[name] = set(self._read_header(srpm_path, "requirename"))
            for rpm_path in srpm_path.parent.glob("*.rpm"):
                if rpm_path.name.endswith(".src.rpm"):
                    continue
                # A package that needs this binary RPM for its build also
                # needs the runtime requirements of the binary RPM installed.
                requires[name].update(self._read_header(rpm_path, "requirename"))
                for capability in self._read_header(rpm_path, "provides"):
                    provider[capability] = name

        dependencies = {}
        for name, capabilities in requires.items():
            package = self._parse_srpm_nvr(name)[0]
            if package in FOUNDATION_PACKAGES:
                index = FOUNDATION_PACKAGES.index(package)
                earlier = FOUNDATION_PACKAGES[:index]
                dependencies[name] = {foundation[p] for p in earlier if p in foundation}
                continue
            dependencies[name] = {provider[c] for c in capabilities if c in provider}
            dependencies[name].update(foundation.values())
            dependencies[name].discard(name)
        return dependencies

    def order_by_dependencies(self, srpms):
        """Sort SRPMs so that each one comes after the SRPMs it depends on."""
        if rpmfile is None:
            logger.warning(
                "Python module rpmfile is not installed, "
                "building in mtime order without dependency resolution"
            )
            return srpms

        dependencies = self._dependencies(srpms)
        remaining = list(srpms)
        ordered = []
        while remaining:
            names = {p.name for p in remaining}
            ready = [p for p in remaining if not dependencies[p.name] & names]
            if not ready:
                # The remaining SRPMs depend on each other in a cycle.
                ready = [remaining[0]]
                logger.warning(
                    "Dependency cycle among %d SRPMs, building %s first",
                    len(remaining),
                    remaining[0].name,
                )
            # Only the first ready SRPM is taken so that SRPMs without a
            # dependency on each other stay in mtime order.
            ordered.append(ready[0])
            remaining.remove(ready[0])
            logger.debug(
                "Build order: %s after %s",
                ready[0].name,
                sorted(dependencies[ready[0].name]) or "nothing",
            )
        return ordered

    def run_scan(self, stop_on_failure=True):
        """Build the newest SRPM of each package that COPR does not have yet."""
        srpms = self.scan_srpms()
        existing_builds = None
        pending = []
        succeeded_names = []
        skipped_names = []
        failed_names = []

        for srpm_path in srpms:
            srpm_name = srpm_path.name

            if self.already_processed(srpm_name):
                status = self.state["builds"][srpm_name]["status"]
                logger.debug("Skipping %s (already %s)", srpm_name, status)
                skipped_names.append(srpm_name)
                continue

            if srpm_name in self._attempted:
                continue

            if not self.should_process(srpm_name):
                self._skip(srpm_path, "filtered")
                skipped_names.append(srpm_name)
                continue

            if existing_builds is None:
                existing_builds = self._fetch_existing_builds()

            if self._already_in_copr(srpm_name, existing_builds):
                logger.info("Skipping %s (already built in COPR)", srpm_name)
                self._skip(srpm_path, "already-in-copr")
                skipped_names.append(srpm_name)
                continue

            pending.append(srpm_path)

        if len(pending) > 1:
            pending = self.order_by_dependencies(pending)

        for srpm_path in pending:
            if self._shutdown:
                logger.info("Shutdown requested, stopping scan")
                break

            srpm_name = srpm_path.name
            self._attempted.add(srpm_name)
            if self.process_srpm(srpm_path):
                succeeded_names.append(srpm_name)
                continue
            if self._shutdown:
                break
            failed_names.append(srpm_name)
            if stop_on_failure and not self.ignore_errors:
                break
            self.state["blocked_on"] = None
            self.save_state()

        return succeeded_names, skipped_names, failed_names, len(srpms)

    @staticmethod
    def _log_summary(succeeded_names, skipped_names, failed_names, total):
        logger.info(
            "Scan complete: %d succeeded, %d skipped, %d failed (of %d total)",
            len(succeeded_names),
            len(skipped_names),
            len(failed_names),
            total,
        )
        for title, names in (
            ("Succeeded", succeeded_names),
            ("Skipped", skipped_names),
            ("Failed", failed_names),
        ):
            if names:
                logger.info("  %s:", title)
                for name in names:
                    logger.info("    - %s", name)

    def run_once(self):
        """Scan mode: process the SRPM tree once."""
        self._auto_reset_blocked()
        self._log_summary(*self.run_scan())

    def run_watch(self):
        """Watch mode: process the SRPM tree every scan_interval seconds."""
        self._auto_reset_blocked()
        logger.info("Scanning %s every %d seconds", self.srpm_dir, self.scan_interval)
        while not self._shutdown:
            succeeded_names, _skipped, failed_names, total = self.run_scan(
                stop_on_failure=False
            )
            if succeeded_names or failed_names:
                self._log_summary(succeeded_names, [], failed_names, total)
            self._sleep(self.scan_interval)

    def reset_failed(self, srpm_name):
        """Remove a failed SRPM from state so it will be retried."""
        if srpm_name not in self.state["builds"]:
            ERROR(f"SRPM '{srpm_name}' not found in state file")

        entry = self.state["builds"][srpm_name]
        if entry["status"] not in ("failed", "canceled"):
            ERROR(
                f"SRPM '{srpm_name}' has status '{entry['status']}', not failed/canceled"
            )

        old_status = entry["status"]
        del self.state["builds"][srpm_name]

        if self.state["blocked_on"] == srpm_name:
            self.state["blocked_on"] = None

        self.save_state()
        logger.info(
            "Removed '%s' (was '%s') from state. It will be retried on next run.",
            srpm_name,
            old_status,
        )

    def setup_signal_handlers(self):
        """Register handlers for graceful shutdown on SIGINT/SIGTERM."""

        def handler(signum, _frame):
            signame = signal.Signals(signum).name
            logger.info("Received %s, shutting down gracefully...", signame)
            self._shutdown = True

        signal.signal(signal.SIGINT, handler)
        signal.signal(signal.SIGTERM, handler)


def main():
    parser = argparse.ArgumentParser(
        description="Bridge OBS SRPMs to Fedora COPR",
    )
    parser.add_argument(
        "--srpm-dir",
        required=True,
        help="OBS build directory containing the <project>:<release>:Factory "
        "directories (usually /srv/obs/build)",
        type=str,
    )
    parser.add_argument(
        "--major",
        default=4,
        help="OpenHPC major release whose releases are searched (default: 4)",
        type=int,
    )
    parser.add_argument(
        "--distro",
        default="EL_10",
        help="OBS repository to take SRPMs from (default: EL_10)",
        type=str,
    )
    parser.add_argument(
        "--arch",
        default="aarch64",
        help="OBS architecture to take SRPMs from (default: aarch64)",
        type=str,
    )
    parser.add_argument(
        "--copr-project",
        help="COPR project (default: @openhpc/openhpc-<major>.x)",
        type=str,
    )
    parser.add_argument(
        "--chroot",
        help="COPR chroot to build for (default: all project chroots)",
        type=str,
    )
    parser.add_argument(
        "--state-file",
        default="copr_bridge_state.json",
        help="path to JSON state file (default: copr_bridge_state.json)",
        type=str,
    )
    parser.add_argument(
        "--mode",
        choices=["scan", "watch"],
        default="scan",
        help="scan processes the SRPMs once, watch keeps running and scans "
        "again every --scan-interval seconds (default: scan)",
        type=str,
    )
    parser.add_argument(
        "--scan-interval",
        default=300,
        help="seconds between scans in watch mode (default: 300)",
        type=int,
    )
    parser.add_argument(
        "--skip-pattern",
        action="append",
        default=[],
        help="regex pattern for SRPMs to skip (repeatable)",
    )
    parser.add_argument(
        "--include-pattern",
        action="append",
        default=[],
        help="regex pattern for SRPMs to include (repeatable)",
    )
    parser.add_argument(
        "--reset-failed",
        help="reset a failed SRPM to allow processing to continue",
        type=str,
    )
    parser.add_argument(
        "--ignore-errors",
        dest="ignore_errors",
        help="skip failed packages and continue with the next one",
        action="store_true",
    )
    parser.add_argument(
        "--force-rebuild",
        dest="force_rebuild",
        help="rebuild packages even if they already exist in COPR",
        action="store_true",
    )
    parser.add_argument(
        "--dry-run",
        dest="dryrun",
        help="show what would be submitted without actually doing it",
        action="store_true",
    )
    parser.add_argument(
        "--poll-interval",
        default=60,
        help="seconds between COPR build status polls (default: 60)",
        type=int,
    )
    parser.add_argument(
        "--copr-config",
        help="path to COPR config file (default: ~/.config/copr)",
        type=str,
    )
    parser.add_argument(
        "--debug",
        dest="debug",
        help="enable debug logging",
        action="store_true",
    )

    parser.set_defaults(dryrun=False, ignore_errors=False, force_rebuild=False)
    args = parser.parse_args()

    def loglevel(debug):
        if debug:
            return "DEBUG"
        return "INFO"

    coloredlogs.install(level=loglevel(args.debug), fmt="%(message)s")

    bridge = CoprBridge(args)
    bridge.setup_signal_handlers()

    if args.reset_failed:
        bridge.reset_failed(args.reset_failed)
        return

    if args.mode == "scan":
        bridge.run_once()
    elif args.mode == "watch":
        bridge.run_watch()


if __name__ == "__main__":
    main()
