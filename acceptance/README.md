# Isolated gstack acceptance

Test-only harness for sealed source commit `5ace6cf535399dc706241fac4b938319c43c54d0`.
The bundle contains public upstream base `514fbfdc9799376edfd2536f60659501a48ead64`
and two local tooling/test-fixture repair commits. It includes no application
source, user home, credentials, provider data, dependencies or generated local builds.

`restore.py` verifies payload sizes and SHA-256 hashes, exactly two repair commits above the public base,
source/tree identities and the byte-for-byte repair diff before execution.
The dedicated push workflow runs on an ordinary GitHub-hosted Ubuntu 24.04 VM.
It preserves Chromium sandboxing and the complete strict free-suite runner;
platform/optional-suite skips remain visible. It makes no paid model calls.
The branch is only an acceptance transport: no upstream PR or default-branch merge.

Artifacts contain the pinned identities, setup/test logs, build hashes, exit status
and strict shard logs from this synthetic, credential-free test environment.
The worker token has only contents-read permission and is not persisted.
