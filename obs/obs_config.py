#!/usr/bin/env python3
#
# utility to create parent/child packages in OBS for a new OHPC
# version based on configuration specified in an ini style config
# file.
# --
import argparse
import ast
import configparser
import inspect
import logging
import os
import re
import subprocess
import sys
import tempfile
from xml.etree import ElementTree

import coloredlogs
from semver import VersionInfo

logger = logging.getLogger(__name__)

# global config settings
obsurl = "https://obs.openhpc.community"
configFile = "config.2.x"

# define known compiler/mpi combos to skip
skip_combos = ["arm1-impi", "arm1-mvapich2"]

# osc command
osc_command = ["osc", "-A", obsurl]


# Simple error wrapper to include exit
def ERROR(output):
    logger.error(output)
    sys.exit()


# This function runs an osc command based on
# 'osc_command' with the ability to have a 'dry_run'.
# This functions returns 'False', "" if something failed
# and 'True', <output> if it succeeded.
def run_osc_command(parameters, dry_run=True, fname=""):
    command = osc_command.copy()
    command.extend(parameters)

    logger.debug(f"[{fname}]: (command) {command}")
    if dry_run:
        return True, ""

    try:
        s = subprocess.check_output(command)
    except (subprocess.CalledProcessError, OSError):
        return False, ""

    return True, s


# Main worker class to read config setup from file and interact with OBS
class ohpc_obs_tool:
    def __init__(self, version):
        self.vip = version

        logger.info(f"\nVersion in Progress = {self.vip}")

        self.buildConfig = None
        self.parentCompiler = None
        self.parentMPI = None
        self.dryRun = True
        self.buildsToCancel = []
        self.skip_on_distro = {}

        # parse version to derive obs-specific version info
        vparse = VersionInfo.parse(self.vip)
        self.branchVer = str(vparse.major) + "." + str(vparse.minor)
        self.microVer = str(vparse.patch)

        logger.info(f"--> Branch version  = {self.branchVer}")
        logger.info(f"--> Micro release   = {self.microVer}")

        projectName = "OpenHPC"
        if self.branchVer.startswith("3."):
            projectName += "3"
        elif self.branchVer.startswith("4."):
            projectName += "4"
        projectName += ":"

        if self.microVer == "0":
            self.obsProject = projectName + self.branchVer + ":Factory"
        else:
            self.obsProject = (
                projectName + self.branchVer + "." + self.microVer + ":Factory"
            )
        logger.info(f"--> OBS project     = {self.obsProject}")

    def checkForDisabledComponents(self, components):
        activeComponents = []
        for item in components:
            if item[0] == "!":
                logger.warning(f"--> Skipping disabled component {item}")
            else:
                activeComponents.append(item)
        return activeComponents

    def parseConfig(self, configFile=None, service_file=None):
        assert configFile is not None
        logger.info(f"\nReading config information from file = {configFile}")
        if os.path.isfile(configFile):
            self.buildConfig = configparser.ConfigParser(
                inline_comment_prefixes="#",
                interpolation=configparser.ExtendedInterpolation(),
            )
            self.buildConfig.optionxform = str
            try:
                self.buildConfig.read(configFile)
            except configparser.DuplicateSectionError:
                ERROR(
                    f"\nERROR: Duplicate section detected in configfile: {configFile}"
                )
            except configparser.Error:
                ERROR(f"ERROR; Unable to parse runtime config file: {configFile}")

            logger.info("--> file parsing ok")

            # read global settings for this version in progress
            # vip = version_in_progress

            try:
                self.dryRun = self.buildConfig.getboolean(
                    "global",
                    "dry_run",
                    fallback=True,
                )
                self.serviceFile = self.buildConfig.get(
                    "global",
                    "service_template",
                )
                self.linkFile_compiler = self.buildConfig.get(
                    "global",
                    "link_compiler_template",
                )
                self.linkFile_mpi = self.buildConfig.get(
                    "global",
                    "link_mpi_template",
                )
                self.linkFile_mpi_to_non_mpi = self.buildConfig.get(
                    "global",
                    "link_mpi_to_non_mpi_template",
                )
                self.overrides = self.buildConfig.get(
                    "global",
                    "override_templates",
                )
                self.compilerFamilies = ast.literal_eval(
                    self.buildConfig.get(self.vip, "compiler_families"),
                )
                self.MPIFamilies = ast.literal_eval(
                    self.buildConfig.get(self.vip, "mpi_families"),
                )

            except (configparser.Error, ValueError, SyntaxError):
                ERROR(f"Unable to parse global settings for {self.vip}")

            assert len(self.compilerFamilies) > 0
            assert len(self.MPIFamilies) > 0

            if service_file:
                self.serviceFile = service_file

            # Figure out if we need to disable building packages on
            # one of the distributions for this version.
            if self.vip in self.buildConfig:
                for key in self.buildConfig[self.vip]:
                    if key.startswith("skip_on_distro_"):
                        distro_to_skip = key[len("skip_on_distro") + 1 :]
                        pkgs_to_skip = ast.literal_eval(
                            self.buildConfig.get(self.vip, key),
                        )
                        for pkg in pkgs_to_skip:
                            try:
                                self.skip_on_distro[pkg].append(distro_to_skip)
                            except KeyError:
                                self.skip_on_distro[pkg] = [distro_to_skip]

            # flag to indicate whether to lock new packages
            # after creation (git trigger will unlock)
            self.Lock = True

            self.parentCompiler = self.compilerFamilies[0]
            self.parentMPI = self.MPIFamilies[0]

            logger.info("--> (global) dry run" + " " * 39 + f"= {self.dryRun}")
            logger.info(
                "--> (global) service template" + " " * 30 + f"= {self.serviceFile}"
            )
            logger.info(
                "--> (global) link template (comp)"
                + " " * 26
                + f"= {self.linkFile_compiler}"
            )
            logger.info(
                "--> (global) link template (mpi)" + " " * 27 + f"= {self.linkFile_mpi}"
            )
            logger.info(
                "--> (global) link template "
                + f"(link_mpi_to_non_mpi_template)  = {self.linkFile_mpi}"
            )
            logger.info(f"\nCompiler families ({self.vip}):")

            for family in self.compilerFamilies:
                output = f"--> {family}"
                if family is self.parentCompiler:
                    output += " (parent)"
                logger.info(output)

            logger.info(f"\nMPI families ({self.vip}):")
            for family in self.MPIFamilies:
                output = f"--> {family}"
                if family is self.parentMPI:
                    output += " (parent)"
                logger.info(output)
            logger.info("")

            # parse skip patterns
            self.NoBuildPatterns = {}

            if self.buildConfig.has_option(self.vip, "skip_aarch"):
                self.NoBuildPatterns["aarch64"] = ast.literal_eval(
                    self.buildConfig.get(self.vip, "skip_aarch")
                )
            if self.buildConfig.has_option(self.vip, "skip_x86"):
                self.NoBuildPatterns["x86_64"] = ast.literal_eval(
                    self.buildConfig.get(self.vip, "skip_x86")
                )

            logger.info("Architecture skip patterns:")
            for pattern in self.NoBuildPatterns:
                logger.info(
                    f"--> arch = {pattern:>6}, pattern(s) to skip = {self.NoBuildPatterns[pattern]}"
                )

            logger.info("\nDistribution skip packages:")
            logger.info(f"--> skip_on_distro = {self.skip_on_distro}")

            # cache group definition(s)
            self.groups = {}

            try:
                groups = self.buildConfig.options("groups")
                assert len(groups) > 0
            except (configparser.Error, AssertionError):
                ERROR("Unable to parse [group] names")

            logger.info(f"--> (global) {len(groups)} package groups defined:")

            # read in components assigned to each group
            for group in groups:
                try:
                    components = ast.literal_eval(self.buildConfig.get("groups", group))

                except (configparser.Error, ValueError, SyntaxError):
                    ERROR("Unable to parse component groups")

                self.groups[group] = components

            for group in groups:
                logger.info(
                    f"    --> {group:<20}: {len(self.groups[group]):2} components included"
                )
                for name in self.groups[group]:
                    logger.debug(f"        ... {name}")

            logger.info("")

        else:
            ERROR("--> unable to access input file")

    # query components defined in config file for version in progress
    # Return: list of component names
    def query_components(self, version="unknown"):
        components = {}

        if self.buildConfig.has_option(self.vip, "standalone"):
            components["standalone"] = ast.literal_eval(
                self.buildConfig.get(self.vip, "standalone")
            )
            logger.info("Parsed components:")
            logger.info(f"--> [        standalone]: {components['standalone']}")

            components["standalone"] = self.checkForDisabledComponents(
                components["standalone"]
            )

        if self.buildConfig.has_option(self.vip, "compiler_dependent"):
            components["comp_dep"] = ast.literal_eval(
                self.buildConfig.get(self.vip, "compiler_dependent")
            )
            logger.info(f"--> [          comp_dep]: {components['comp_dep']}")

            components["comp_dep"] = self.checkForDisabledComponents(
                components["comp_dep"]
            )

        if self.buildConfig.has_option(self.vip, "mpi_dependent"):
            components["mpi_dep"] = ast.literal_eval(
                self.buildConfig.get(self.vip, "mpi_dependent")
            )
            logger.info(f"--> [           mpi_dep]: {components['mpi_dep']}")

            components["mpi_dep"] = self.checkForDisabledComponents(
                components["mpi_dep"]
            )

        if self.buildConfig.has_option(self.vip, "mpi_dependent_to_non_mpi"):
            components["mpi_dep_to_non_mpi"] = ast.literal_eval(
                self.buildConfig.get(self.vip, "mpi_dependent_to_non_mpi")
            )
            logger.info(f"--> [mpi_dep_to_non_mpi]: {components['mpi_dep_to_non_mpi']}")

            components["mpi_dep_to_non_mpi"] = self.checkForDisabledComponents(
                components["mpi_dep_to_non_mpi"]
            )

        if self.buildConfig.has_option(self.vip, "with_ucx"):
            components["with_ucx"] = ast.literal_eval(
                self.buildConfig.get(self.vip, "with_ucx")
            )
            logger.info(f"--> [          with_ucx]: {components['with_ucx']}")

            components["with_ucx"] = self.checkForDisabledComponents(
                components["with_ucx"]
            )

        if self.buildConfig.has_option(self.vip, "with_pmix"):
            components["with_pmix"] = ast.literal_eval(
                self.buildConfig.get(self.vip, "with_pmix")
            )
            logger.info(f"--> [         with_pmix]: {components['with_pmix']}")

            components["with_pmix"] = self.checkForDisabledComponents(
                components["with_pmix"]
            )

        numComponents = 0
        if "standalone" not in components:
            components["standalone"] = []
        if "comp_dep" not in components:
            components["comp_dep"] = []
        if "mpi_dep" not in components:
            components["mpi_dep"] = []
        if "mpi_dep_to_non_mpi" not in components:
            components["mpi_dep_to_non_mpi"] = []
        if "with_ucx" not in components:
            components["with_ucx"] = []
        if "with_pmix" not in components:
            components["with_pmix"] = []

        numComponents = (
            len(components["standalone"])
            + len(components["comp_dep"])
            + len(components["mpi_dep"])
            + len(components["mpi_dep_to_non_mpi"])
            + len(components["with_ucx"])
            + len(components["with_pmix"])
        )

        logger.info(f"# of requested components = {numComponents}\n")
        return components

    # query all packages currently defined for given version in obs
    # Return: dict of defined packages
    def queryOBSPackages(self):
        logger.info(
            "[queryOBSPackages]: checking for packages"
            + f"currently defined in OBS ({self.vip})"
        )

        success, output = run_osc_command(
            ["api", "-X", "GET", "/source/" + self.obsProject],
            dry_run=False,
            fname=inspect.stack()[0][3],
        )

        if not success:
            ERROR("Unable to queryPackages from obs")

        results = ElementTree.fromstring(output)

        packages = {}

        for value in results.iter("entry"):
            packages[value.get("name")] = 1

        logger.info(f"[queryOBSPackages]: {len(packages)} packages defined")
        logger.debug(packages)
        return packages

    # check if package is standalone (ie, not compiler or MPI dependent)
    def isStandalone(self, package):
        fname = inspect.stack()[0][3]
        compiler_dep = self.buildConfig.getboolean(
            self.vip + "/" + package,
            "compiler_dep",
            fallback=False,
        )
        mpi_dep = self.buildConfig.getboolean(
            self.vip + "/" + package,
            "mpi_dep",
            fallback=False,
        )

        logger.debug(f"\n[{fname}] - {package}: compiler_dep = {compiler_dep}")
        logger.debug(f"[{fname}] - {package}: mpi_dep      = {mpi_dep}")

        return not (compiler_dep or mpi_dep)

    # check if package is compiler dependent
    # (ie, depends on compiler family, but not MPI)
    def isCompilerDep(self, package):
        fname = inspect.stack()[0][3]
        compiler_dep = self.buildConfig.getboolean(
            self.vip + "/" + package,
            "compiler_dep",
            fallback=False,
        )
        mpi_dep = self.buildConfig.getboolean(
            self.vip + "/" + package,
            "mpi_dep",
            fallback=False,
        )

        logger.debug(f"\n[{fname}] - {package}: compiler_dep = {compiler_dep}")
        logger.debug(f"[{fname}] - {package}: mpi_dep      = {mpi_dep}")

        return bool(compiler_dep and not mpi_dep)

    # check if package is MPI dependent (implies compiler toolchain dependency)
    def isMPIDep(self, package):
        fname = inspect.stack()[0][3]
        mpi_dep = self.buildConfig.getboolean(
            self.vip + "/" + package,
            "mpi_dep",
            fallback=False,
        )

        logger.debug(f"\n[{fname}] - {package}: mpi_dep      = {mpi_dep}")

        return bool(mpi_dep)

    # check which group a package belongs to
    # return: name of group (str)
    def checkPackageGroup(self, package):
        fname = inspect.stack()[0][3]
        found = False
        for group in self.groups:
            if package in self.groups[group]:
                logger.debug(f"[{fname}] {package} belongs to group {group}")
                return group
        if not found:
            ERROR(
                ("package %s not associated with any groups, " + "please check config")
                % package
            )

    # update dryrun option
    def overrideDryRun(self):
        self.dryRun = False

    # update lock option
    def overrideLock(self):
        self.Lock = False

    # return parent compiler
    def getParentCompiler(self):
        return self.parentCompiler

    # return parent cMPI
    def getParentMPI(self):
        return self.parentMPI

    # check package against skip build patterns
    def disableBuild(self, package, arch):
        fname = inspect.stack()[0][3]
        if arch not in self.NoBuildPatterns:
            return False

        for pattern in self.NoBuildPatterns[arch]:
            if re.search(pattern, package):
                logger.debug(f"[{fname}]: {pattern} found in package name ({package})")
                return True
        return False

    # query compiler family builds for given package. Default to
    # global settings unless overridden by package specific settings
    def queryCompilers(self, package, noOverride=False):
        fname = inspect.stack()[0][3]
        compiler_families = self.compilerFamilies

        if noOverride:
            return compiler_families

        # check if any override options exist for this package
        if self.buildConfig.has_option(self.vip, package + "_compiler"):
            compiler_families = ast.literal_eval(
                self.buildConfig.get(self.vip, package + "_compiler")
            )

        logger.debug(f"[{fname}]: {compiler_families}")
        return compiler_families

    # query MPI family builds for given package. Default to
    # global settings unless overridden by package specific settings
    def queryMPIFamilies(self, package):
        fname = inspect.stack()[0][3]
        mpi_families = self.MPIFamilies

        # check if any override options
        if self.buildConfig.has_option(self.vip, package + "_mpi"):
            mpi_families = ast.literal_eval(
                self.buildConfig.get(self.vip, package + "_mpi")
            )
            logger.info(
                "\n--> override of default mpi "
                + f"families requested for package = {package}"
            )
            logger.info(f"--> families {mpi_families}\n")

        logger.debug(f"[{fname}]: {mpi_families}")
        return mpi_families

    # add specified package to OBS
    def addPackage(
        self,
        package,
        parent=True,
        isCompilerDep=False,
        isMPIDep=False,
        compiler=None,
        mpi=None,
        parentName=None,
        gitName=None,
        isMPIDepToNonMPI=False,
        replace=None,
    ):
        fname = inspect.stack()[0][3]
        pad = 15

        # verify we have template _service file and cache contents
        if os.path.isfile(self.serviceFile):
            # use package-specific template if present,
            # otherwise, use default serviceFile
            if os.path.isfile(f"{self.overrides}/_service.{package}"):
                logger.warning(
                    " " * pad
                    + f"--> package-specific _service file provided for {package}"
                )
                fileOverride = f"{self.overrides}/_service.{package}"
                with open(fileOverride, "r") as filehandle:
                    contents = filehandle.read()
                    filehandle.close()
            else:
                with open(self.serviceFile, "r") as filehandle:
                    contents = filehandle.read()
                    filehandle.close()
        else:
            ERROR(f"Unable to read _service file template: {self.serviceFile}")

        # verify we have a group definition for the parent package
        if parent:
            if gitName is not None:
                group = self.checkPackageGroup(gitName)
            else:
                group = self.checkPackageGroup(package)
            logger.debug(f"[{fname}]: group assigned = {group}")

        # Step 1: create _meta file for obs package
        # (this defines new obs package)
        with tempfile.NamedTemporaryFile(delete=True, mode="w+t") as fp:
            fp.writelines(f'<package name = "{package}" project="{self.obsProject}">\n')
            fp.writelines("<title/>\n")
            fp.writelines("<description/>")
            fp.writelines("<build>\n")

            # check skip pattern to define build architectures
            numEnabled = 0
            if self.disableBuild(package, "aarch64"):
                logger.warning(
                    " " * pad + "--> disabling aarch64 build per pattern match request"
                )
                fp.writelines('<disable arch="aarch64"/>\n')
            else:
                fp.writelines('<enable arch="aarch64"/>\n')
                numEnabled += 1

            if self.disableBuild(package, "x86_64"):
                logger.warning(
                    " " * pad + "--> disabling x86_64 build per pattern match request"
                )
                fp.writelines('<disable arch="x86_64"/>\n')
            else:
                fp.writelines('<enable arch="x86_64"/>\n')
                numEnabled += 1

            for skip in self.skip_on_distro:
                if skip in package:
                    for distro in self.skip_on_distro[skip]:
                        logger.warning(
                            " " * pad
                            + f"--> disabling pkg {package} on distro {distro} as requested"
                        )
                        fp.writelines(f'<disable repository="{distro}"/>')

            if numEnabled == 0:
                logger.warning(
                    " " * pad
                    + "--> no remaining architectures enabled, "
                    + "skipping package add"
                )
                return

            fp.writelines("</build>\n")
            fp.writelines("</package>\n")
            fp.flush()

            logger.debug(f"[{fname}]: new package _metadata written to {fp.name}")

            if self.dryRun:
                logger.error(
                    " " * pad
                    + f"--> (dryrun) requesting addition of package: {package}"
                )

            url = "/source/" + self.obsProject + "/" + package + "/_meta"

            success, _ = run_osc_command(
                ["api", "-f", fp.name, "-X", "PUT", url],
                dry_run=self.dryRun,
                fname=fname,
            )

            if not success:
                ERROR(f"\nUnable to add new package ({package}) to OBS")

        # add marker file indicating this is a new OBS addition ready to
        # be rebuilt (nothing in file, simply a marker)
        if True and self.Lock:
            with tempfile.NamedTemporaryFile(delete=False, mode="w+t") as fp:
                fp.flush()

                markerFile = "_obs_config_ready_for_build"
                if self.dryRun:
                    logger.debug(
                        " " * pad
                        + "--> (dryrun) requesting addition "
                        + f" of {markerFile} file for package: {package}"
                    )

                url = "/source/" + self.obsProject + "/" + package + "/" + markerFile
                success, _ = run_osc_command(
                    ["api", "-f", fp.name, "-X", "PUT", url],
                    dry_run=self.dryRun,
                    fname=fname,
                )
                if not success:
                    ERROR(
                        "\nUnable to add marker file for"
                        + f" package ({package}) to OBS"
                    )

        # add a constraint file if present
        if os.path.isfile(f"constraints/{package}"):
            logger.warning(" " * pad + f"--> constraint file provided for {package}")
            constraintFile = f"constraints/{package}"
            if self.dryRun:
                logger.debug(
                    " " * pad
                    + "--> (dryrun) requesting addition of "
                    + f"_constraints file for package: {package}"
                )

            url = "/source/" + self.obsProject + "/" + package + "/" + "_constraints"

            success, _ = run_osc_command(
                ["api", "-f", constraintFile, "-X", "PUT", url],
                dry_run=self.dryRun,
                fname=fname,
            )

            if not success:
                ERROR(
                    "\nUnable to add _constraint file"
                    + f"for package ({package}) to OBS"
                )

        # Step 2a: add _service file for parent package
        if parent:
            # obs needs escape for hyphens in _service file
            group = group.replace("-", "[-]")

            # create package specific _service file

            pname = package
            if gitName is not None:
                pname = gitName
            contents = contents.replace("!GROUP!", group)
            contents = contents.replace("!PACKAGE!", pname)
            if self.branchVer.startswith("3."):
                contents = contents.replace("!VERSION!", "3.x")
            elif self.branchVer.startswith("4."):
                contents = contents.replace("!VERSION!", "4.x")
            else:
                contents = contents.replace("!VERSION!", "2.x")

            with tempfile.NamedTemporaryFile(delete=True, mode="w") as fp_serv:
                fp_serv.write(contents)
                fp_serv.flush()
                logger.debug(f"--> _service file written to {fp_serv.name}")

                url = "/source/" + self.obsProject + "/" + package + "/_service"

                if self.dryRun:
                    logger.error(
                        " " * pad
                        + f"--> (dryrun) adding _service file for package: {package}"
                    )

                success, _ = run_osc_command(
                    ["api", "-f", fp_serv.name, "-X", "PUT", url],
                    dry_run=self.dryRun,
                    fname=fname,
                )

                if not success:
                    ERROR(
                        "\nUnable to add _service file for"
                        + f" package ({package}) to OBS"
                    )

        # Step2b: add _link file for child package
        else:
            if isCompilerDep:
                linkFile = self.linkFile_compiler
                assert compiler is not None
            elif isMPIDep:
                linkFile = self.linkFile_mpi
            elif isMPIDepToNonMPI:
                linkFile = self.linkFile_mpi_to_non_mpi

            assert parentName is not None

            # verify we have template _link file template
            if os.path.isfile(linkFile):
                with open(linkFile, "r") as filehandle:
                    contents = filehandle.read()
                    filehandle.close()
            else:
                ERROR(f"Unable to read _link file template: {linkFile}")

            # create package specific _link file

            contents = contents.replace("!PACKAGE!", parentName)
            contents = contents.replace("!COMPILER!", compiler)
            contents = contents.replace("!PROJECT!", self.obsProject)
            if isMPIDep:
                contents = contents.replace("!MPI!", mpi)

            if replace:
                contents = contents.replace("!REPLACE_ME!", replace)
            else:
                contents = contents.replace("\t!REPLACE_ME!\n", "")
            with tempfile.NamedTemporaryFile(delete=True, mode="w") as fp_link:
                fp_link.write(contents)
                fp_link.flush()
                logger.debug(f"--> _link file written to {fp_link.name}")

                url = "/source/" + self.obsProject + "/" + package + "/_link"

                if self.dryRun:
                    logger.error(
                        " " * pad
                        + "--> (dryrun) adding _link file for"
                        + f" package: {package} (parent={parentName})"
                    )

                success, _ = run_osc_command(
                    ["api", "-f", fp_link.name, "-X", "PUT", url],
                    dry_run=self.dryRun,
                    fname=fname,
                )

                if not success:
                    ERROR(f"\nUnable to add _link file for package ({package}) to OBS")

        # Step 3 - register package to lock build once it kicks off
        self.buildsToCancel.append(package)

    def cancelNewBuilds(self):
        fname = inspect.stack()[0][3]
        numBuilds = len(self.buildsToCancel)

        if self.Lock is False:
            return

        if numBuilds == 0:
            logger.info("\nNo new builds created.")
            return
        else:
            logger.info(f"\n{numBuilds} new build(s) need to be locked:")
            logger.info(
                "--> will lock for now and GitHub"
                + " trigger will unlock on first commit"
            )

        for package in self.buildsToCancel:
            if self.dryRun:
                logger.info(f"--> (dryrun) requesting lock for package: {package}")

            success, _ = run_osc_command(
                ["lock", self.obsProject, package],
                dry_run=self.dryRun,
                fname=fname,
            )

            if not success:
                ERROR(f"\nUnable to add _link file for package ({package}) to OBS")


# top-level


def main():
    # parse command-line args
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--configFile",
        help=(f"filename with package definition options (default = {configFile})"),
        type=str,
    )
    parser.add_argument(
        "--no-dryrun",
        dest="dryrun",
        help="flag to disable dryrun mode and execute obs commands",
        action="store_false",
    )
    parser.add_argument("--version", help="version in progress", type=str)
    parser.add_argument(
        "--no-lock",
        dest="lock",
        help="do not lock new build additions",
        action="store_false",
    )
    parser.add_argument(
        "--package", help="check OBS config for provided package only", type=str
    )
    parser.add_argument(
        "--service-file",
        help=("OBS service file template (default taken from configuration file)"),
        type=str,
    )
    parser.add_argument(
        "--debug",
        dest="debug",
        help="enable debug output",
        action="store_true",
    )

    parser.set_defaults(dryrun=True)
    parser.set_defaults(lock=True)
    args = parser.parse_args()

    def loglevel(debug):
        if debug:
            return "DEBUG"
        return "INFO"

    coloredlogs.install(level=loglevel(args.debug), fmt="%(message)s")

    if args.version is None:
        logger.error("\nPlease specify desired version\n")
        parser.print_help()
        parser.exit()

    # main worker bee class
    obs = ohpc_obs_tool(args.version)

    # read config file and parse component packages desired for current version
    obs.parseConfig(configFile=args.configFile, service_file=args.service_file)
    components = obs.query_components()

    # override dryrun option if requested
    if not args.dryrun:
        logger.info("--no-dryrun command line arg requested: will execute commands\n")
        obs.overrideDryRun()

    # override lock option if requested
    if not args.lock:
        logger.info("--no-lock command line arg requested: will not lock new builds\n")
        obs.overrideLock()

    if args.package:
        logger.info(f"checking on single package only: {args.package}")

    # query components defined in existing OBS project
    obsPackages = obs.queryOBSPackages()

    # Check if desired package(s) are present in OBS and add them if
    # not. Different logic applies to (1) standalone packages,
    # (2) packages with a compiler dependency, and (3) packages with an
    # MPI dependency

    logger.info("")

    # (1) standalone packages
    for package in components["standalone"]:
        ptype = "standalone"
        if package in obsPackages:
            logger.info(f"{package:>34} ({ptype:>13}): present in OBS")
        else:
            logger.info(
                f"{package:>34} ({ptype:>13}): *not* present in OBS, need to add"
            )
            obs.addPackage(package, parent=True)

    # (2) compiler dependent packages
    for package in components["comp_dep"]:
        # check if override package is desired
        if args.package and (package != args.package):
            logger.info(f"skipping {package}")
            continue

        ptype = "compiler dep"
        parent = package + "-" + obs.getParentCompiler()

        compilers = obs.queryCompilers(package)
        Defcompilers = obs.queryCompilers(package, noOverride=True)

        if compilers != Defcompilers:
            pad = 22
            logger.warning(
                " " * pad
                + f"--> override of default compiler families requested for {package}"
            )
            logger.warning(" " * pad + f"--> families =  {compilers}")

        # check on parent first (it must exist before any children are linked)
        if parent in obsPackages:
            logger.info(f"{parent:>34} ({ptype:>13}): present in OBS")
        else:
            logger.info(
                f"{parent:>34} ({ptype:>13}): *not* present in OBS, need to add"
            )
            obs.addPackage(parent, parent=True, isCompilerDep=True, gitName=package)

        # now, check on children
        for compiler in compilers:
            # verify compiler is known (as user could override with unknown
            # compiler family)
            if compiler not in Defcompilers:
                ERROR(
                    f"requested compiler {compiler} is not one"
                    " of known compiler families; double check config file"
                )

            if compiler == obs.getParentCompiler():
                logger.debug("...skipping parent compiler...")
                continue

            child = package + "-" + compiler
            logger.debug(
                " " * 22 + f"checking on child compiler dependent package: {child}"
            )
            if child in obsPackages:
                logger.info(f"{child:>34} ({ptype:>13}): present in OBS")
            else:
                logger.info(
                    f"{child:>34} ({ptype:>13}): *not* present in OBS, need to add"
                )
                obs.addPackage(
                    child,
                    parent=False,
                    isCompilerDep=True,
                    compiler=compiler,
                    parentName=parent,
                )

        for compiler in compilers:
            if package in components["with_ucx"]:
                child = package + "-ucx-" + compiler
                if child in obsPackages:
                    logger.info(f"{child:>34} ({ptype:>13}): present in OBS")
                else:
                    logger.info(
                        f"{child:>34} ({ptype:>13}): *not* present in OBS, need to add"
                    )
                    obs.addPackage(
                        child,
                        parent=False,
                        isCompilerDep=True,
                        compiler=compiler,
                        parentName=parent,
                        replace="<topadd>%define with_ucx 1</topadd>",
                    )

            if package in components["with_pmix"]:
                child = package + "-pmix-" + compiler
                if child in obsPackages:
                    logger.info(f"{child:>34} ({ptype:>13}): present in OBS")
                else:
                    logger.info(
                        f"{child:>34} ({ptype:>13}): *not* present in OBS, need to add"
                    )
                    obs.addPackage(
                        child,
                        parent=False,
                        isCompilerDep=True,
                        compiler=compiler,
                        parentName=parent,
                        replace="<topadd>%define RMS_DELIM -pmix</topadd>",
                    )

    # (3) MPI dependent packages
    for package in components["mpi_dep"]:
        ptype = "MPI dep"
        parent = package + "-" + obs.getParentCompiler() + "-" + obs.getParentMPI()
        compilers = obs.queryCompilers(package)
        mpiFams = obs.queryMPIFamilies(package)

        # check on parent first (it must exist before any children are linked)
        if parent in obsPackages:
            logger.info(f"{parent:>34} ({ptype:>13}): present in OBS")
        else:
            logger.info(
                f"{parent:>34} ({ptype:>13}): *not* present in OBS, need to add"
            )
            obs.addPackage(parent, parent=True, isMPIDep=True, gitName=package)

        # now, check on children
        for compiler in compilers:
            for mpi in mpiFams:
                child = package + "-" + compiler + "-" + mpi
                if child == parent:
                    logger.debug(f"...skipping parent package {child}")
                    continue

                combo = compiler + "-" + mpi
                if combo in skip_combos:
                    continue

                if child in obsPackages:
                    logger.info(f"{child:>34} ({ptype:>13}): present in OBS")
                else:
                    logger.info(
                        f"{child:>34} ({ptype:>13}): *not* present in OBS, need to add"
                    )
                    obs.addPackage(
                        child,
                        parent=False,
                        isMPIDep=True,
                        compiler=compiler,
                        mpi=mpi,
                        parentName=parent,
                    )

        if package in components["mpi_dep_to_non_mpi"]:
            ptype = "non MPI dep"
            for compiler in compilers:
                child = package + "-" + compiler
                if child in obsPackages:
                    logger.info(f"{child:>34} ({ptype:>13}): present in OBS")
                else:
                    logger.info(
                        f"{child:>34} ({ptype:>13}): *not* present in OBS, need to add"
                    )
                    obs.addPackage(
                        child,
                        parent=False,
                        isMPIDep=False,
                        compiler=compiler,
                        mpi=mpi,
                        parentName=parent,
                        isMPIDepToNonMPI=True,
                    )

    obs.cancelNewBuilds()


if __name__ == "__main__":
    main()
