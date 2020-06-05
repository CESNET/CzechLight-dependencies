# Shared library dependencies for NETCONF-related software

Please note that a `Verified: +1` vote only means that all these libraries managed to build.
There's no cross-project gating right now.

## Updating software

This is rather fragile process due to the way we are setting up Zuul with multi-tenant support.
(It looks like not a lot of people are using different Zuul tenants talking to one Gerrit server.)

When uploading, make sure that all changes share the same topic in Gerrit (e.g., `git push ... -o topic=update-netconf`).

1) Make a modification here in `CzechLight/dependencies`.
This will be the change **A** ([example](https://gerrit.cesnet.cz/c/CzechLight/dependencies/+/2693)).
This change will be built by both Zuul tenants independently.

2) Update `CzechLight/cla-sysrepo` (change **B**: [example](https://gerrit.cesnet.cz/c/CzechLight/cla-sysrepo/+/2694)).
Use these `Depends-on` footer tags:
```shell
Depends-on: https://cesnet-gerrit-czechlight/c/CzechLight/dependencies/+/${A}
Depends-on: https://gerrit.cesnet.cz/c/CzechLight/dependencies/+/${A}
```
This will result in just one buildset in the private Zuul tenant.

3) Update `CzechLight/netconf-cli` as change **C** ([example](https://gerrit.cesnet.cz/c/CzechLight/netconf-cli/+/2695)):
```shell
Depends-on: https://cesnet-gerrit-czechlight/c/CzechLight/dependencies/+/${A}
Depends-on: https://cesnet-gerrit-public/c/CzechLight/dependencies/+/${A}
Depends-on: https://gerrit.cesnet.cz/c/CzechLight/dependencies/+/${A}
Depends-on: https://gerrit.cesnet.cz/c/CzechLight/cla-sysrepo/+/${B}
```
This repo is built twice.
The private Zuul tenant perform the usual multi-compiler tests, while the `CzechLight-internal` runs an integration check via the `czechlight_clearfog` build job.

4) Finally (and optionally), update `CzechLight/br2-external` so that it includes both `cla-sysrepo` and `netconf-cli` changes ([example](https://gerrit.cesnet.cz/c/CzechLight/br2-external/+/2698)).
The following `Depends-on` are needed:
```shell
Depends-on: https://cesnet-gerrit-czechlight/c/CzechLight/cla-sysrepo/+/${B}
Depends-on: https://gerrit.cesnet.cz/c/CzechLight/cla-sysrepo/+/${B}
Depends-on: https://cesnet-gerrit-czechlight/c/CzechLight/netconf-cli/+/${C}
Depends-on: https://gerrit.cesnet.cz/c/CzechLight/netconf-cli/+/${C}
```

If everything builds, then the change is good to go 🌈 🦄 🍻.

## Adding new repositories

- Create project within Gerrit: `ssh import.gerrit.cesnet.cz gerrit create-project --parent github/acl github/ORGANIZATION/REPO --owner '"Git Importers"' --description "'MIRROR: ...'"`
- Run the first import script as the `github-mirror` user on `gerrit.cesnet.cz`: `REPO=org/repo ./oneshot.sh`
- Update configuration of tenants in Zuul ([example](https://gerrit.cesnet.cz/c/ci/project-config/+/2188))
- Reconfigure Zuul (as `zuul` on `zuul.gerrit.cesnet.cz`, run `zuul-scheduler full-reconfigure`)
- Add the submodule here: `git submodule add ../../github/ORG/REPO REPO`
- Modify `ci/build.sh` to start building this dependency
- Propose changes to all consumers as shown above
