# Shared library dependencies for NETCONF-related software

Please note that a `Verified: +1` vote only means that all these libraries managed to build.
There's no cross-project gating right now.

## Updating software

- Make a modification here, propose it for a review with some topic.
- Make a change in all consumers of this repo with a proper `Depends-on` on this change, using the same Gerrit topic.
Ensure that you include a tenant-specific Gerrit hostname (`cesnet-gerrit-czechlight`, `cesnet-gerrit-public`) before also including the normal FQDN.
- If everything builds, then the change is good to go.

## Adding new repositories

- Create project within Gerrit: `ssh import.gerrit.cesnet.cz gerrit create-project --parent github/acl github/ORGANIZATION/REPO --owner '"Git Importers"' --description "'MIRROR: ...'"`
- Run the first import script as the `github-mirror` user on `gerrit.cesnet.cz`: `REPO=org/repo ./oneshot.sh`
- Update configuration of tenants in Zuul ([example](https://gerrit.cesnet.cz/c/ci/project-config/+/2188))
- Reconfigure Zuul (as `zuul` on `zuul.gerrit.cesnet.cz`, run `zuul-scheduler full-reconfigure`)
- Add the submodule here: `git submodule add ../../github/ORG/REPO REPO`
- Modify `ci/build.sh` to start building this dependency
- Propose changes to all consumers as shown above
