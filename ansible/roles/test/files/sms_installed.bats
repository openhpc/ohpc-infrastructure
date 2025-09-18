#!/usr/bin/env -S bats --report-formatter junit --formatter tap -j 2
# shellcheck disable=SC1091,SC2154

@test "Verify hostname matches expectations" {
	[ "$NODE_NAME" == "$(hostname)" ]
}

@test "Base OS check" {
	[ -e /etc/os-release ]

	. /etc/os-release

	case ${DISTRIBUTION} in
	openEuler_22.03)
		[ "$NAME" == "openEuler" ]
		[[ "$VERSION" == "22.03"* ]]
		;;
	leap15.5)
		[ "$NAME" == "openSUSE Leap" ]
		[ "$VERSION" == "15.5" ]
		;;
	rocky8)
		[ "$NAME" == "Rocky Linux" ]
		[[ "$VERSION" == "8."* ]]
		;;
	rocky9)
		[ "$NAME" == "Rocky Linux" ]
		[[ "$VERSION" == "9."* ]]
		;;
	almalinux9)
		[ "$NAME" == "AlmaLinux" ]
		[[ "$VERSION" == "9."* ]]
		;;
	almalinux10)
		[ "$NAME" == "AlmaLinux" ]
		[[ "$VERSION" == "10."* ]]
		;;
	*)
		echo "Unknown DISTRIBUTION ${DISTRIBUTION}. Error!"
		false
		;;
	esac
}
