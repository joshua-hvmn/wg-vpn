setup() {
	load 'test_helper'
	setup_mocks
}

teardown() {
	:
}

conf_val() {
	sed -n "s/^$1=//p" "$XDG_CONFIG_HOME/wg-vpn/wg-vpn.conf" | tail -1
}

@test "config wg <dir> sets WG_CONFIG_DIR" {
	mkdir -p "$BATS_TEST_TMPDIR/wgdir"
	run ./wg-vpn config wg "$BATS_TEST_TMPDIR/wgdir"
	[ "$status" -eq 0 ]
	[ "$(conf_val WG_CONFIG_DIR)" = "$BATS_TEST_TMPDIR/wgdir" ]
}

@test "config wg <file.conf> sets dir and file" {
	mkdir -p "$BATS_TEST_TMPDIR/wgdir"
	touch "$BATS_TEST_TMPDIR/wgdir/wg0.conf"
	run ./wg-vpn config wg "$BATS_TEST_TMPDIR/wgdir/wg0.conf"
	[ "$status" -eq 0 ]
	[ "$(conf_val WG_CONFIG_DIR)" = "$BATS_TEST_TMPDIR/wgdir" ]
	[ "$(conf_val WG_CONFIG_FILE)" = "wg0.conf" ]
}

@test "config wg --silent sets dir to \$PWD with no output" {
	touch "$XDG_CONFIG_HOME/wg-vpn/subnets.list"
	local wg_vpn_bin
	wg_vpn_bin="$(pwd)/wg-vpn"
	cd "$BATS_TEST_TMPDIR"
	run "$wg_vpn_bin" config wg --silent
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ "$(conf_val WG_CONFIG_DIR)" = "$BATS_TEST_TMPDIR" ]
}

@test "config subnets <cidr> adds by default" {
	run ./wg-vpn config subnets 203.0.113.0/24
	[ "$status" -eq 0 ]
	grep -qF "203.0.113.0/24" "$XDG_CONFIG_HOME/wg-vpn/subnets.list"
}

@test "config subnets <cidr> rm removes it" {
	./wg-vpn config subnets 203.0.113.0/24
	run ./wg-vpn config subnets 203.0.113.0/24 rm
	[ "$status" -eq 0 ]
	run ! grep -qF "203.0.113.0/24" "$XDG_CONFIG_HOME/wg-vpn/subnets.list"
}

@test "config subnets <cidr> deny is an alias for rm" {
	./wg-vpn config subnets 203.0.113.0/24
	run ./wg-vpn config subnets 203.0.113.0/24 deny
	[ "$status" -eq 0 ]
	run ! grep -qF "203.0.113.0/24" "$XDG_CONFIG_HOME/wg-vpn/subnets.list"
}

@test "config init seeds subnets file" {
	rm -f "$XDG_CONFIG_HOME/wg-vpn/subnets.list"
	run ./wg-vpn config init <<<"n"
	[ "$status" -eq 0 ]
	[ -f "$XDG_CONFIG_HOME/wg-vpn/subnets.list" ]
}

@test "config unknown subcommand exits 1 with usage" {
	run ./wg-vpn config bogus
	[ "$status" -eq 1 ]
	[[ "$output" == *"Usage: wg-vpn config"* ]]
}

@test "args are forwarded past the first arg (routing regression)" {
	mkdir -p "$BATS_TEST_TMPDIR/argtest"
	run ./wg-vpn config wg "$BATS_TEST_TMPDIR/argtest"
	[ "$status" -eq 0 ]
	[ "$(conf_val WG_CONFIG_DIR)" = "$BATS_TEST_TMPDIR/argtest" ]
}
