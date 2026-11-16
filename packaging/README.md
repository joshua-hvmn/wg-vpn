# Packaging

wg-vpn doesn't publish to any package repository itself. Every stable release instead carries
a recipe a packager can publish as it is, attached to its
[release page](https://github.com/joshua-hvmn/wg-vpn/releases) next to the tarball:

| Release asset              | For     | Rendered from     |
| -------------------------- | ------- | ----------------- |
| `PKGBUILD`, `PKGBUILD.sig` | the AUR | `aur/PKGBUILD.in` |

The file here is a template, so it never goes stale. The release workflow fills in `@VERSION@`
and `@SHA256@` with [`render`](render), checks the result (`bash -n`), and signs it with the
same key as the tarball. Prereleases get none: makepkg allows no `-` in `pkgver`, and packages
follow stable releases.

Why not keep the filled-in recipe on `main`? The tarball's sha256 depends on the release commit
(`git archive` writes the commit's ID into it), so the hash only exists once the release is
tagged. A recipe on `main` would always be one release behind.

The recipe builds from the signed tarball with the Makefile's standard variables
(`make test-unit`, `make prefix=... DESTDIR=... install`). Nothing here goes into release
tarballs (see `.gitattributes`). CI renders the PKGBUILD on every push and checks it with
`makepkg --printsrcinfo` and `namcap`, in an Arch container.

## Getting and checking a release's recipe

```sh
v=vX.Y.Z    # the release
base=https://github.com/joshua-hvmn/wg-vpn/releases/download/$v
curl -LO "$base/PKGBUILD" -LO "$base/PKGBUILD.sig"
gpg --verify PKGBUILD.sig PKGBUILD   # the key in the README's "Verifying a release"
```

To render it yourself, from a checkout of the release's tag:

```sh
packaging/render "$v" "$(cut -d ' ' -f 1 "wg-vpn-$v.tar.gz.sha256")" out/
```

## AUR

For Arch and its derivatives. `check()` runs the unit suite against the tarball, and makepkg
checks the tarball's signature against the primary key in `validpgpkeys`.

First, check that the name is free: <https://aur.archlinux.org/packages/wg-vpn>. If it's
taken, change `pkgname` (`_name` stays `wg-vpn`, it's the tarball's name).

```sh
gpg --keyserver keyserver.ubuntu.com --recv-keys 4474376DA30B98D6FC34D217348CC5A7E89CC1CD
git clone ssh://aur@aur.archlinux.org/wg-vpn.git aur-wg-vpn  # a new, empty package
cd aur-wg-vpn
# ...download and verify the release's PKGBUILD here (above), then:
makepkg -si                          # build, test, install
namcap PKGBUILD ./*.pkg.tar.zst      # optional lint
makepkg --printsrcinfo >.SRCINFO
git add PKGBUILD .SRCINFO && git commit -m "wg-vpn X.Y.Z" && git push
```

Each release: the same, with that release's `PKGBUILD`. It already has `pkgrel=1`; bump
`pkgrel` yourself only for a change to the packaging alone.
