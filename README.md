# Shared library dependencies for NETCONF-related software

Please note that a `Verified: +1` vote only means that all these libraries managed to build.
There's no cross-project gating right now.
Here's how to make changes:

- make a modification here, propose it for a review with some topic
- make a change in all consumers of this repo with a proper `Depends-on` on this change, using the same Gerrit topic
- if everything builds, then the change is good to go
