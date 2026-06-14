[< Back to docs index](index.md)

# Installing Wispr Flow for Ubuntu

Install a prebuilt, signed `.deb` package for **amd64 or arm64**.

```bash
curl -fsSL https://pkg.wispr-flow-linux.dev/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/wispr-flow.gpg
echo "deb [signed-by=/usr/share/keyrings/wispr-flow.gpg arch=amd64,arm64] https://pkg.wispr-flow-linux.dev stable main" | sudo tee /etc/apt/sources.list.d/wispr-flow.list
sudo apt update && sudo apt install wispr-flow
```

## APT repository

```bash
# 1. Pin the repository signing key
curl -fsSL https://pkg.wispr-flow-linux.dev/KEY.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/wispr-flow.gpg

# 2. Add the repository
echo "deb [signed-by=/usr/share/keyrings/wispr-flow.gpg arch=amd64,arm64] https://pkg.wispr-flow-linux.dev stable main" \
  | sudo tee /etc/apt/sources.list.d/wispr-flow.list

# 3. Install
sudo apt update && sudo apt install wispr-flow
```

Updates arrive with your regular `sudo apt upgrade`.

## After installing

Run the built-in diagnostic first:

```bash
wispr-flow --doctor
```

Text injection needs write access to `/dev/uinput` (granted by the bundled udev rule via the logind `uaccess` ACL, with the `input` group as a fallback). Group changes take effect on your next login. Full details on env vars, state locations, clipboard deps, and the GNOME Shell extension are in [configuration.md](configuration.md). Symptom-keyed fixes are in [troubleshooting.md](troubleshooting.md).

## Updating

New releases install with your regular `sudo apt upgrade`.

## Uninstalling

```bash
sudo apt remove wispr-flow

# Also remove the repository channel:
sudo rm /etc/apt/sources.list.d/wispr-flow.list /usr/share/keyrings/wispr-flow.gpg
```

User state lives under the paths documented in [configuration.md](configuration.md); remove those separately for a clean slate.

## See also

- [building.md](building.md) — build a `.deb` yourself from an installer you supply
- [compatibility.md](compatibility.md) — validated compositors and per-backend access requirements
- [troubleshooting.md](troubleshooting.md) — `--doctor` output and symptom-keyed fixes
