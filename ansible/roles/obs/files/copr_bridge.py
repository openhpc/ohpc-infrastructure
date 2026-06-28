#!/usr/bin/env python3
#
# Utility to bridge OBS-built SRPMs to Fedora COPR for ppc64le builds.
# Supports scan and watch modes for processing SRPMs serially.
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
from ctypes import CDLL, c_char_p, c_int, c_uint32, get_errno
from ctypes.util import find_library
from datetime import datetime, timezone
from pathlib import Path

import coloredlogs
from copr.v3 import Client
from copr.v3.exceptions import CoprAuthException, CoprException

# Terminal build states from copr.v3
TERMINAL_STATES = ("succeeded", "skipped", "failed", "canceled")

# Default retry settings for transient errors
MAX_RETRIES = 5
RETRY_BASE_SECONDS = 10


def ERROR(output):
    logging.error(output)
    sys.exit(1)


def now_iso():
    """Return current UTC time as ISO 8601 string."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


class InotifyWatcher:
    """Minimal inotify wrapper using ctypes (Linux only)."""

    IN_CLOSE_WRITE = 0x00000008
    IN_MOVED_TO = 0x00000080
    EVENT_HEADER_SIZE = struct.calcsize("iIII")

    def __init__(self):
        libc = CDLL(find_library("c"), use_errno=True)
        self._inotify_init = libc.inotify_init
        self._inotify_init.restype = c_int
        self._inotify_add_watch = libc.inotify_add_watch
        self._inotify_add_watch.restype = c_int
        self._inotify_add_watch.argtypes = [c_int, c_char_p, c_uint32]
        self._fd = self._inotify_init()
        if self._fd < 0:
            raise OSError(get_errno(), "inotify_init failed")

    def add_watch(self, path, mask):
        """Add an inotify watch on the given path."""
        wd = self._inotify_add_watch(
            c_int(self._fd),
            path.encode(),
            c_uint32(mask),
        )
        if wd < 0:
            raise OSError(get_errno(), "inotify_add_watch failed for %s" % path)
        return wd

    def read_events(self):
        """Block until events are available, then yield (wd, mask, cookie, name) tuples."""
        buf = os.read(self._fd, 8192)
        offset = 0
        while offset < len(buf):
            wd, mask, cookie, name_len = struct.unpack_from("iIII", buf, offset)
            offset += self.EVENT_HEADER_SIZE
            name = buf[offset : offset + name_len].rstrip(b"\x00").decode()
            offset += name_len
            yield (wd, mask, cookie, name)

    def close(self):
        """Close the inotify file descriptor."""
        os.close(self._fd)


class CoprBridge:
    """Bridge OBS SRPMs to Fedora COPR builds."""

    STATE_VERSION = 1

    def __init__(self, args):
        self.srpm_dir = args.srpm_dir
        self.copr_project = args.copr_project
        self.chroot = args.chroot
        self.state_file = args.state_file
        self.dryrun = args.dryrun
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

    def _parse_copr_project(self):
        """Split copr_project into (ownername, projectname)."""
        if "/" not in self.copr_project:
            ERROR(
                "Invalid --copr-project format '%s'. "
                "Expected 'owner/project' or '@group/project'." % self.copr_project
            )
        parts = self.copr_project.split("/", 1)
        return parts[0], parts[1]

    def load_state(self):
        """Load state from JSON file. Return empty state if missing or corrupt."""
        if not os.path.exists(self.state_file):
            logging.debug("No state file found at %s, starting fresh", self.state_file)
            return self._empty_state()

        try:
            with open(self.state_file) as f:
                state = json.load(f)
            logging.info(
                "Loaded state from %s (%d builds tracked)",
                self.state_file,
                len(state.get("builds", {})),
            )
            return state
        except (json.JSONDecodeError, OSError) as e:
            logging.warning(
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
            logging.error("Failed to save state file: %s", e)

    def scan_srpms(self):
        """Scan srpm_dir for *.src.rpm files, return sorted by mtime ascending."""
        srpm_dir = Path(self.srpm_dir)
        if not srpm_dir.is_dir():
            ERROR("SRPM directory does not exist: %s" % self.srpm_dir)

        srpms = list(srpm_dir.glob("*.src.rpm"))
        srpms.sort(key=lambda p: p.stat().st_mtime)
        logging.info("Found %d SRPMs in %s", len(srpms), self.srpm_dir)
        return srpms

    def should_process(self, srpm_name):
        """Check if an SRPM should be processed based on include/skip patterns."""
        if self.include_patterns:
            if not any(p.search(srpm_name) for p in self.include_patterns):
                logging.debug(
                    "SRPM %s: no include pattern matched, skipping", srpm_name
                )
                return False

        for pattern in self.skip_patterns:
            if pattern.search(srpm_name):
                logging.debug(
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
        return entry["status"] in ("succeeded", "skipped", "acknowledged")

    def submit_build(self, srpm_path):
        """Upload SRPM to COPR and return the build object."""
        logging.info("Submitting %s to COPR %s", srpm_path.name, self.copr_project)

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
            logging.info(
                "Build submitted: id=%d, url=https://copr.fedorainfracloud.org"
                "/coprs/build/%d/",
                build.id,
                build.id,
            )
            return build
        except CoprAuthException as e:
            ERROR(
                "COPR authentication failed: %s\nCheck your ~/.config/copr token." % e
            )
        except CoprException as e:
            logging.error("COPR API error submitting %s: %s", srpm_path.name, e)
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
                    logging.error(
                        "Failed to poll build %d after %d retries: %s",
                        build_id,
                        MAX_RETRIES,
                        e,
                    )
                    return None
                wait_time = RETRY_BASE_SECONDS * (2 ** (retries - 1))
                logging.warning(
                    "Poll failed (attempt %d/%d), retrying in %ds: %s",
                    retries,
                    MAX_RETRIES,
                    wait_time,
                    e,
                )
                time.sleep(wait_time)
                continue

            if build.state != last_state:
                logging.info(
                    "Build %d: %s -> %s",
                    build_id,
                    last_state or "(new)",
                    build.state,
                )
                last_state = build.state

            if build.state in TERMINAL_STATES:
                return build

            if build.state == "unknown":
                logging.error("Build %d entered unknown state", build_id)
                return build

            time.sleep(self.poll_interval)

        return None

    def process_srpm(self, srpm_path):
        """Submit an SRPM to COPR, poll until done, update state. Return True on success."""
        srpm_name = srpm_path.name
        mtime = srpm_path.stat().st_mtime

        if self.dryrun:
            logging.info(
                "[dry-run] Would submit %s to %s", srpm_name, self.copr_project
            )
            self.state["builds"][srpm_name] = {
                "status": "skipped",
                "reason": "dry-run",
                "mtime": mtime,
            }
            self.save_state()
            return True

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

        self.state["builds"][srpm_name] = {
            "status": "pending",
            "copr_build_id": build.id,
            "submitted_at": now_iso(),
            "mtime": mtime,
        }
        self.save_state()

        result = self.poll_build(build.id)

        if result is None:
            self.state["builds"][srpm_name]["status"] = "failed"
            self.state["builds"][srpm_name]["reason"] = "poll failure or shutdown"
            self.state["builds"][srpm_name]["completed_at"] = now_iso()
            self.state["blocked_on"] = srpm_name
            self.save_state()
            return False

        build_url = "https://copr.fedorainfracloud.org/coprs/build/%d/" % result.id

        if result.state == "succeeded":
            self.state["builds"][srpm_name]["status"] = "succeeded"
            self.state["builds"][srpm_name]["completed_at"] = now_iso()
            self.state["last_succeeded"] = srpm_name
            self.save_state()
            logging.info("Build succeeded: %s (%s)", srpm_name, build_url)
            return True

        self.state["builds"][srpm_name]["status"] = result.state
        self.state["builds"][srpm_name]["completed_at"] = now_iso()
        self.state["builds"][srpm_name]["build_url"] = build_url
        self.state["blocked_on"] = srpm_name
        self.save_state()
        logging.error("Build %s for %s. See: %s", result.state, srpm_name, build_url)
        return False

    def run_scan(self):
        """Scan mode: process all SRPMs in directory sorted by mtime."""
        if self.state["blocked_on"]:
            blocked = self.state["blocked_on"]
            ERROR(
                "Processing is blocked on failed SRPM: %s\n"
                "Fix the issue and run with --reset-failed '%s' to continue."
                % (blocked, blocked)
            )

        srpms = self.scan_srpms()
        succeeded = 0
        skipped = 0
        failed = 0

        for srpm_path in srpms:
            if self._shutdown:
                logging.info("Shutdown requested, stopping scan")
                break

            srpm_name = srpm_path.name

            if self.already_processed(srpm_name):
                status = self.state["builds"][srpm_name]["status"]
                logging.debug("Skipping %s (already %s)", srpm_name, status)
                skipped += 1
                continue

            if not self.should_process(srpm_name):
                self.state["builds"][srpm_name] = {
                    "status": "skipped",
                    "reason": "filtered",
                    "mtime": srpm_path.stat().st_mtime,
                }
                self.save_state()
                skipped += 1
                continue

            ok = self.process_srpm(srpm_path)
            if ok:
                succeeded += 1
            else:
                failed += 1
                break

        logging.info(
            "Scan complete: %d succeeded, %d skipped, %d failed (of %d total)",
            succeeded,
            skipped,
            failed,
            len(srpms),
        )

    def run_watch(self):
        """Watch mode: initial scan then inotify event loop."""
        # Run initial scan first
        logging.info("Running initial scan before entering watch mode")
        if self.state["blocked_on"]:
            blocked = self.state["blocked_on"]
            ERROR(
                "Processing is blocked on failed SRPM: %s\n"
                "Fix the issue and run with --reset-failed '%s' to continue."
                % (blocked, blocked)
            )

        srpms = self.scan_srpms()
        for srpm_path in srpms:
            if self._shutdown:
                return
            srpm_name = srpm_path.name
            if self.already_processed(srpm_name):
                continue
            if not self.should_process(srpm_name):
                self.state["builds"][srpm_name] = {
                    "status": "skipped",
                    "reason": "filtered",
                    "mtime": srpm_path.stat().st_mtime,
                }
                self.save_state()
                continue
            if not self.process_srpm(srpm_path):
                ERROR(
                    "Build failed during initial scan. "
                    "Fix and restart with --reset-failed."
                )

        # Set up inotify
        watcher = InotifyWatcher()
        mask = InotifyWatcher.IN_CLOSE_WRITE | InotifyWatcher.IN_MOVED_TO
        watcher.add_watch(self.srpm_dir, mask)
        logging.info("Watching %s for new SRPMs...", self.srpm_dir)

        try:
            while not self._shutdown:
                for _wd, _mask, _cookie, name in watcher.read_events():
                    if self._shutdown:
                        break
                    if not name.endswith(".src.rpm"):
                        continue

                    # Brief delay to let file writes settle
                    time.sleep(0.5)

                    srpm_path = Path(self.srpm_dir) / name
                    if not srpm_path.exists():
                        continue

                    srpm_name = srpm_path.name
                    if self.already_processed(srpm_name):
                        logging.debug("Already processed %s, ignoring", srpm_name)
                        continue
                    if not self.should_process(srpm_name):
                        self.state["builds"][srpm_name] = {
                            "status": "skipped",
                            "reason": "filtered",
                            "mtime": srpm_path.stat().st_mtime,
                        }
                        self.save_state()
                        continue

                    logging.info("New SRPM detected: %s", srpm_name)
                    if not self.process_srpm(srpm_path):
                        ERROR(
                            "Build failed for %s. "
                            "Fix and restart with --reset-failed." % srpm_name
                        )
        finally:
            watcher.close()

    def reset_failed(self, srpm_name):
        """Mark a failed SRPM as acknowledged so processing can continue."""
        if srpm_name not in self.state["builds"]:
            ERROR("SRPM '%s' not found in state file" % srpm_name)

        entry = self.state["builds"][srpm_name]
        if entry["status"] not in ("failed", "canceled"):
            ERROR(
                "SRPM '%s' has status '%s', not failed/canceled"
                % (srpm_name, entry["status"])
            )

        entry["original_status"] = entry["status"]
        entry["status"] = "acknowledged"
        entry["acknowledged_at"] = now_iso()

        if self.state["blocked_on"] == srpm_name:
            self.state["blocked_on"] = None

        self.save_state()
        logging.info(
            "Reset '%s' from '%s' to 'acknowledged'. Processing can continue.",
            srpm_name,
            entry["original_status"],
        )

    def setup_signal_handlers(self):
        """Register handlers for graceful shutdown on SIGINT/SIGTERM."""

        def handler(signum, _frame):
            signame = signal.Signals(signum).name
            logging.info("Received %s, shutting down gracefully...", signame)
            self._shutdown = True

        signal.signal(signal.SIGINT, handler)
        signal.signal(signal.SIGTERM, handler)


def main():
    parser = argparse.ArgumentParser(
        description="Bridge OBS SRPMs to Fedora COPR for ppc64le builds",
    )
    parser.add_argument(
        "--srpm-dir",
        required=True,
        help="path to directory containing SRPMs",
        type=str,
    )
    parser.add_argument(
        "--copr-project",
        required=True,
        help="COPR project (e.g. @openhpc/ohpc-ppc64le)",
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
        help="operation mode (default: scan)",
        type=str,
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

    parser.set_defaults(dryrun=False)
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
        bridge.run_scan()
    elif args.mode == "watch":
        bridge.run_watch()


if __name__ == "__main__":
    main()
