# Oppi fork setup (omo + herdr on a Mac)

This fork connects the Oppi iOS app to `omo` sessions running in `herdr` on your Mac.

You need:

- The Oppi app from the TestFlight invite.
- macOS with `node` (22+), `git`, `omo` and `herdr` on your PATH, and omo set up at `~/.omo/agent`.

## Install

```bash
git clone https://github.com/kristianvast/oppi.git ~/projects/oppi
~/projects/oppi/setup-omo-mac.sh
oppi pair
```

Scan the QR code from the app. Then restart open omo sessions (or run `/reload` in them) so they show up in Oppi.

The script builds the server, installs the `oppi` CLI and a launchd service, and adds `oppi-mirror` to omo's `settings.json`. It also sets the server to launch new sessions as omo in herdr and to use this fork's push relay.

## Away from home Wi-Fi

The phone needs a network route to your Mac, for example NetBird or Tailscale. Pair over that route with `oppi pair --host <mac-vpn-ip>`.

## Update

```bash
cd ~/projects/oppi && git pull && ./setup-omo-mac.sh
```
