# Security policy

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately: open the repository's Security tab and click "Report a vulnerability". Include your macOS version, the output of `bodycam --version` and the steps to reproduce it.

## Supported versions

Fixes go into new releases only, so check that you're on the latest one before reporting.

## What runs as root

Only Apple's `eslogger` (`/usr/bin/eslogger`, which comes with macOS) runs as root. `bodycam claude` asks for your password through `sudo` to start it, then runs your agent as you. `sudo bodycam` runs bodycam itself as root so it can watch every agent on the Mac; it starts the same `eslogger` and reads its output.

bodycam doesn't install anything, doesn't leave anything running and doesn't make network requests. Reports and the live feed are written to `~/Library/Logs/bodycam` and stay there.

## Checking a release

Every release is built by GitHub Actions from the tagged commit, with a SHA-256 checksum and a build provenance attestation. To check a download:

```sh
shasum -a 256 -c bodycam-darwin-universal.tar.gz.sha256
gh attestation verify bodycam-darwin-universal.tar.gz --repo omlahore/bodycam
```

You can also build it yourself with `go install github.com/omlahore/bodycam@latest`.
