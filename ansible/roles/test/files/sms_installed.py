#!/usr/bin/python3

import io
import os
import sys
import unittest
import xmlrunner


class InstallTests_sms_installed(unittest.TestCase):

    # verify hostname
    def test_01_verify_hostname_matches_expectation(self):
        sms_expected = os.environ['SMS']
        myhost = os.uname()[1]
        self.assertEqual(sms_expected, myhost)

    # verify BaseOS
    def test_02_base_os_check(self):
        baseOS = os.environ['BaseOS']

        if baseOS == "centos7.3":
            self.assertTrue(os.path.isfile("/etc/centos-release"))
            with open("/etc/centos-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertEqual(entries[0],
                             'CentOS Linux release 7.3.1611 (Core)')
        elif baseOS == "centos7.4":
            self.assertTrue(os.path.isfile("/etc/centos-release"))
            with open("/etc/centos-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertEqual(entries[0],
                             'CentOS Linux release 7.4.1708 (Core)')
        elif baseOS == "centos7.5":
            self.assertTrue(os.path.isfile("/etc/centos-release"))
            with open("/etc/centos-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertTrue(entries[0].startswith(
                'CentOS Linux release 7.5.1804'))
        elif baseOS == "centos7.6":
            self.assertTrue(os.path.isfile("/etc/centos-release"))
            with open("/etc/centos-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertTrue(entries[0].startswith(
                'CentOS Linux release 7.6.1810'))
        elif baseOS == "centos7.7":
            self.assertTrue(os.path.isfile("/etc/centos-release"))
            with open("/etc/centos-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertTrue(entries[0].startswith(
                'CentOS Linux release 7.7.1908'))
        elif baseOS == "centos8.1":
            self.assertTrue(os.path.isfile("/etc/centos-release"))
            with open("/etc/centos-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertTrue(entries[0].startswith(
                'CentOS Linux release 8.1.1911'))
        elif baseOS == "centos8.2":
            self.assertTrue(os.path.isfile("/etc/centos-release"))
            with open("/etc/centos-release", "r") as fh:
                entries = fh.readlines()
            entries = [x.strip() for x in entries]
            self.assertTrue(entries[0].startswith(
                'CentOS Linux release 8.2.2004'))
        elif baseOS == "sles12sp2":
            self.assertTrue(os.path.isfile("/etc/os-release"))
            with open("/etc/os-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertEqual(entries[0], 'NAME=\"SLES\"')
            self.assertEqual(entries[1], 'VERSION=\"12-SP2\"')
        elif baseOS == "sles12sp3":
            self.assertTrue(os.path.isfile("/etc/os-release"))
            with open("/etc/os-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertEqual(entries[0], 'NAME=\"SLES\"')
            self.assertEqual(entries[1], 'VERSION=\"12-SP3\"')
        elif baseOS == "sles12sp4":
            self.assertTrue(os.path.isfile("/etc/os-release"))
            with open("/etc/os-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertEqual(entries[0], 'NAME=\"SLES\"')
            self.assertEqual(entries[1], 'VERSION=\"12-SP4\"')
        elif baseOS == "leap15.1":
            self.assertTrue(os.path.isfile("/etc/os-release"))
            with open("/etc/os-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertEqual(entries[0], 'NAME=\"openSUSE Leap\"')
            self.assertEqual(entries[1], 'VERSION=\"15.1 \"')

        elif baseOS == "leap15.3":
            self.assertTrue(os.path.isfile("/etc/os-release"))
            with open("/etc/os-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertEqual(entries[0], 'NAME=\"openSUSE Leap\"')
            self.assertEqual(entries[1], 'VERSION=\"15.3\"')

        elif baseOS == "leap15.5":
            self.assertTrue(os.path.isfile("/etc/os-release"))
            with open("/etc/os-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertEqual(entries[0], 'NAME=\"openSUSE Leap\"')
            self.assertEqual(entries[1], 'VERSION=\"15.5\"')

        elif baseOS == "openEuler_22.03":
            self.assertTrue(os.path.isfile("/etc/os-release"))
            with open("/etc/os-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertEqual(entries[0], 'NAME="openEuler"')
            self.assertEqual(entries[1], 'VERSION="22.03 LTS"')

        elif baseOS == "rocky8.8":
            self.assertTrue(os.path.isfile("/etc/os-release"))
            with open("/etc/os-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertEqual(entries[0], 'NAME="Rocky Linux"')
            self.assertEqual(entries[1], 'VERSION="8.8 (Green Obsidian)"')

        elif baseOS == "rocky9.2":
            self.assertTrue(os.path.isfile("/etc/os-release"))
            with open("/etc/os-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertEqual(entries[0], 'NAME="Rocky Linux"')
            self.assertTrue(entries[1].startswith('VERSION="9'))

        elif baseOS == "almalinux9.2":
            self.assertTrue(os.path.isfile("/etc/os-release"))
            with open("/etc/os-release", "r") as fh:
                entries = fh.readlines()

            entries = [x.strip() for x in entries]
            self.assertEqual(entries[0], 'NAME="AlmaLinux"')
            self.assertEqual(entries[1], 'VERSION="9.2 (Turquoise Kodkod)"')

        else:
            print("Unknown BaseOS")
            self.assertTrue(False)


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
        'InstallTests_sms_installed',
        'InstallTests.sms_installed',
    )

    dirname, _ = os.path.split(os.path.abspath(__file__))
    outfile = os.path.join(dirname, 'sms_installed.log.xml')

    with open(outfile, "w") as f:
        f.writelines(output)

    if not test_result.result.wasSuccessful():
        sys.exit(1)
