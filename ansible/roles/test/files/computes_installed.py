#!/usr/bin/python3

import os
import io
import sys
import shutil
import xmlrunner
import unittest
import tempfile
import subprocess


class InstallTests_computesinstalled(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        try:
            num_computes = os.environ['num_computes']
        except KeyError:
            cls.fail("Environment variable '$num_computes' not found")

        try:
            cls.num_computes = int(num_computes)
        except ValueError:
            cls.fail(
                "Environment variable '$num_computes' not a number: " +
                num_computes)

        cls.tempfile_fd, cls.tempfile_name = tempfile.mkstemp()

    @classmethod
    def tearDownClass(cls):
        try:
            os.remove(cls.tempfile_name)
        except FileNotFoundError:
            pass

    # verify num_computes > 0
    def test_01_numcomputes_greater_than_zero(self):
        self.assertGreater(self.num_computes, 0)

    # verify koomie_cf is available
    def test_02_koomie_cf_available(self):
        self.assertIsNotNone(shutil.which('koomie_cf'))

    # ensure correct number of hosts available
    def test_03_nonzero_results_from_uptime(self):
        cmd = ["koomie_cf", "-x", "c\\d+", "cat /proc/uptime"]
        subprocess.call(
            cmd,
            stdout=os.fdopen(
                self.tempfile_fd,
                'w'),
            stderr=subprocess.STDOUT)
        self.assertGreater(os.path.getsize(self.tempfile_name), 0)

    def test_04_correct_number_of_hosts_booted(self):
        num_lines = sum(1 for line in open(self.tempfile_name, 'r'))
        self.assertEqual(num_lines, self.num_computes)

    # verify uptimes are reasonable
    def test_05_verify_boot_times_are_reasonable(self):
        # max uptime expected in seconds
        uptimeThreshold = 3600
        numBad = 0

        with open(self.tempfile_name, 'r') as fh:
            entries = fh.readlines()
            entries = [x.strip() for x in entries]
            self.assertGreater(len(entries), 0)
            for line in entries:
                vals = line.split()
                print(line)
                if float(vals[1]) >= uptimeThreshold:
                    numBad += 1
                    print(
                        "Uptime on %s is %s and greater than threshold %s" %
                         (
                             vals[0],
                             vals[1],
                             uptimeThreshold,
                         ),
                    )

        self.assertEqual(numBad, 0)


if __name__ == '__main__':

    out = io.StringIO()
    test_result = unittest.main(
        exit=False,
        testRunner=xmlrunner.XMLTestRunner(
            output=out,
            descriptions=True,
            verbosity=2,
            outsuffix='',
        ),
    )

    out.seek(0)
    # update XML classnames for consistency
    output = str(
        out.read()).replace(
        'InstallTests_computesinstalled',
        'InstallTests.computes_installed',
    )

    dirname, _ = os.path.split(os.path.abspath(__file__))
    outfile = os.path.join(dirname, 'computes_installed.log.xml')

    with open(outfile, "w") as f:
        f.writelines(output)

    if not test_result.result.wasSuccessful():
        sys.exit(1)
