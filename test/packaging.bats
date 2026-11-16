#!/usr/bin/env bats
# packaging/render: the AUR PKGBUILD each stable release carries. packaging/
# isn't in release tarballs, so these skip there.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SHA=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

render() {
	"$REPO_ROOT/packaging/render" "$@"
}

setup_file() {
	[ -x "$BATS_TEST_DIRNAME/../packaging/render" ] || skip "packaging/ isn't here (a release tarball)"
}

@test "render: fills in the version and the hash, and leaves no placeholders" {
	run render v0.2.0 "$SHA" "$BATS_TEST_TMPDIR/out"
	[ "$status" -eq 0 ]
	[ "$output" = "$BATS_TEST_TMPDIR/out/PKGBUILD" ]
	cd "$BATS_TEST_TMPDIR/out"
	grep -qx 'pkgver=0.2.0' PKGBUILD
	grep -qx "sha256sums=('$SHA'" PKGBUILD
	run grep -q '@[A-Z0-9_]*@' PKGBUILD
	[ "$status" -eq 1 ]
}

@test "render: the PKGBUILD is valid bash, and names the release's signed tarball" {
	render v0.2.0 "$SHA" "$BATS_TEST_TMPDIR/out" >/dev/null
	bash -n "$BATS_TEST_TMPDIR/out/PKGBUILD"
	# shellcheck disable=SC2016 # expanded by the bash that sources the PKGBUILD
	run bash -c 'source "$1" && printf "%s\n" "$pkgver" "${source[@]}" "${sha256sums[@]}"' _ "$BATS_TEST_TMPDIR/out/PKGBUILD"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = 0.2.0 ]
	[ "${lines[1]}" = https://github.com/joshua-hvmn/wg-vpn/releases/download/v0.2.0/wg-vpn-v0.2.0.tar.gz ]
	[ "${lines[2]}" = https://github.com/joshua-hvmn/wg-vpn/releases/download/v0.2.0/wg-vpn-v0.2.0.tar.gz.sig ]
	[ "${lines[3]}" = "$SHA" ]
	[ "${lines[4]}" = SKIP ]
}

@test "render: refuses a prerelease, a version without its v, and anything that isn't a sha256" {
	run render v0.2.0-rc.1 "$SHA" "$BATS_TEST_TMPDIR/out"
	[ "$status" -eq 1 ]
	[[ "$output" == *"'v0.2.0-rc.1' is not a stable vX.Y.Z version; prereleases get no recipes."* ]]

	run render 0.2.0 "$SHA" "$BATS_TEST_TMPDIR/out"
	[ "$status" -eq 1 ]

	run render v0.2.0 "$(printf '%s' "$SHA" | tr a-f A-F)" "$BATS_TEST_TMPDIR/out"
	[ "$status" -eq 1 ]
	[[ "$output" == *"is not a sha256"* ]]

	run render v0.2.0 "$SHA/" "$BATS_TEST_TMPDIR/out"
	[ "$status" -eq 1 ]
	[ ! -e "$BATS_TEST_TMPDIR/out" ]

	run render v0.2.0 "$SHA"
	[ "$status" -eq 2 ]
	[[ "$output" == "usage: "* ]]
}

@test "render: a placeholder it doesn't know stops it, and leaves nothing half-written" {
	cp -R "$REPO_ROOT/packaging" "$BATS_TEST_TMPDIR/packaging"
	echo '# @MAINTAINER@' >>"$BATS_TEST_TMPDIR/packaging/aur/PKGBUILD.in"
	run "$BATS_TEST_TMPDIR/packaging/render" v0.2.0 "$SHA" "$BATS_TEST_TMPDIR/out"
	[ "$status" -eq 1 ]
	[[ "$output" == *"aur/PKGBUILD.in has placeholders render doesn't fill"* ]]
	[ ! -e "$BATS_TEST_TMPDIR/out/PKGBUILD" ]
	[ ! -e "$BATS_TEST_TMPDIR/out/PKGBUILD.tmp" ]
}

@test "the template has placeholders, not a release's version or hash" {
	cd "$REPO_ROOT/packaging"
	grep -qx 'pkgver=@VERSION@' aur/PKGBUILD.in
	grep -qx "sha256sums=('@SHA256@'" aur/PKGBUILD.in
	run grep -Eq '[0-9a-f]{64}|v[0-9]+\.[0-9]+\.[0-9]+' aur/PKGBUILD.in
	[ "$status" -eq 1 ]
}
