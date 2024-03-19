#!/usr/bin/env -S bats --report-formatter junit --formatter tap
# shellcheck disable=SC1091,SC2154

@test "Verify hostname matches expectations" {
	[ "$SMS" == "$(hostname)" ]
}

@test "Base OS check" {
	[ -e /etc/os-release ]

	. /etc/os-release

	case ${BaseOS} in
	openEuler_22.03)
		[ "$NAME" == "openEuler" ]
		[[ "$VERSION" == "22.03"* ]]
		;;
	leap15.5)
		[ "$NAME" == "openSUSE Leap" ]
		[ "$VERSION" == "15.5" ]
		;;
	rocky8.8)
		[ "$NAME" == "Rocky Linux" ]
		[[ "$VERSION" == "8."* ]]
		;;
	rocky9.2)
		[ "$NAME" == "Rocky Linux" ]
		[[ "$VERSION" == "9."* ]]
		;;
	almalinux9.2)
		[ "$NAME" == "AlmaLinux" ]
		[[ "$VERSION" == "9."* ]]
		;;
	*)
		echo "Unkown BaseOS ${BaseOS}. Error!"
		false
		;;
	esac
}
