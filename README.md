# Synadia Platform Trial

This is the code repository for the [Synadia Platform Trial](https://docs.synadia.com/platform/trial).

---

## Getting Started

### Bootstrapping

```shell
sh <(curl --location https://raw.githubusercontent.com/synadia-io/platform-trial/refs/heads/main/bootstrap.sh)
```

### No Bootstrap

If using Linux, MacOS, or WSL on Windows, run `./start.sh`.

If you would prefer to not install any packages that `start.sh` requires, you can use a `nix-shell` and run `start-nix.sh` from within a `nix-shell` created with `shell.nix` (used by default if `nix-shell` is ran from this directory).

> [!NOTE]  
> Docker is always required to run the platform trial. If using `nix-shell`, you must still have Docker installed and running on the host system.
