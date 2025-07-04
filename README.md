# Distfiles

This repository contains scripts for automating the process of creation and publication of distribution files as [packages](https://docs.gitlab.com/user/packages/package_registry/) suitable for inclusion into [Gentoo](https://gentoo.org) [ebuilds](https://wiki.gentoo.org/wiki/Ebuild). There is a [GitLab CI/CD](https://docs.gitlab.com/ci/) [pipeline](./.gitlab-ci.yml) that regularly checks for new versions of upstream software and updates the packages if necessary. Those are uploaded to the [project's package registry](https://gitlab.com/paveloom-g/personal/gentoo/distfiles/-/packages).

Currently supported distribution file formats:

- [Go](https://golang.org)
  - Vendor tarball (set `method` to `vendor`)
  - Dependency tarball (set `method` to `download`)
- [Rust](https://www.rust-lang.org)
  - Vendor tarball (set `method` to `vendor`)

Git mirrors:
- [Codeberg](https://codeberg.org/paveloom/gentoo-distfiles)
- [GitHub](https://github.com/paveloom/gentoo-distfiles)
- [GitLab](https://gitlab.com/paveloom-g/personal/gentoo/distfiles)

# Run

Required binaries:

- `cargo`
- `curl`
- `go`
- `jq`

Additional binaries can be required by prepare scripts (see [./repos](./repos)).

Here's an example of running a script:

```bash
cp .env.example .env
# set up the environment variables in the `.env` file
source .env
./sync.bash
```

# Use

Here's an example of using a package in an ebuild:

```ebuild
SRC_URI="
	https://github.com/owner/repo/archive/refs/tags/${PV}.tar.gz -> ${P}.tar.gz
	https://gitlab.com/api/v4/projects/69517529/packages/generic/${PN}/${PV}/${P}-deps.tar.xz
"
```

# Acknowledgements

This is a reimplementation of the setup at https://gitlab.fem-net.de/gentoo/fem-overlay-vendored.
