# Contributing to Fiero-Hotspot

Thanks for helping! Bug reports, hardware reports and pull requests are all welcome.

## Reporting a problem

Open an issue with the **Bug report** template. Because Fiero-Hotspot depends so much on the Wi-Fi card, please include the hardware details it asks for (`lspci -k`, `iw list`, the service journal). Remove your passphrase and anything else private from logs first.

Did Fiero-Hotspot work (or not) on your laptop? The **Hardware report** template helps grow the compatibility list.

Security problems: please use [private vulnerability reporting](https://github.com/Fiero1186/Fiero-Hotspot/security/advisories/new) instead of a public issue (see [SECURITY.md](SECURITY.md)).

## Making a change

1. Fork the repository and create a branch per topic (`fix/...`, `feat/...`, `docs/...`).
2. Keep pull requests small: one topic each, easy to review.
3. Run the automated tests (below) and, for anything that touches the hotspot lifecycle, the on-hardware harness.
4. Describe *what* changed and *why* in the pull request, and add an entry under `[Unreleased]` in [CHANGELOG.md](CHANGELOG.md).

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/): `fix(daemon): ...`, `feat(cli): ...`, `docs: ...`, `test: ...`.

## Tests

### Automated (no Wi-Fi hardware needed)

```bash
tests/run.sh             # everything
tests/run.sh daemon      # one suite: daemon, prompt or install
```

This needs Docker. It builds a small Debian image and runs, inside a throwaway container:

- **ShellCheck** on every script
- **`systemd-analyze security`**: the service's exposure score must stay at or below 5.0
- **bats** suites that run the *real* `fiero-hotspot.sh`, `fiero-prompt.sh`, `install.sh` and `uninstall.sh` against test doubles of `create_ap`, `iw`, `notify-send`, `systemctl` and a fake charger (`tests/mocks/`)

The same command runs in CI on every pull request. The suites replace system commands, so they refuse to run outside the container.

On Windows, run it from Git Bash with Docker Desktop started. Make sure your clone uses LF line endings (the repository's `.gitattributes` takes care of this for fresh clones).

### On real hardware

```bash
sudo ./install.sh
sudo ./test_harness.sh
```

Exit code `0` means everything passed **including a real start/stop of the hotspot**. Exit code `2` means the start/stop was skipped (upstream Wi-Fi on an unsupported channel); connect to a supported channel and run it again before reporting a pass.

## Style

- Bash, 4-space indentation (tabs in `test_harness.sh`), see [.editorconfig](.editorconfig).
- Root scripts set a fixed `PATH` and must never trust the caller's environment.
- Only ever touch Fiero-Hotspot's own `create_ap` instance and files; other hotspots on the system must be left alone.
