# orport-guard

FreeBSD PF-based ORPort protection for Tor relays.

`orport-guard` keeps Tor relay DDoS mitigation small and inspectable:

- discovers relay listeners from Tor config
- falls back to `sockstat` when needed
- rewrites public targets to the PF-visible local address on NATed hosts when that mapping is unambiguous
- fetches Tor authority and Snowflake trust lists
- renders one dedicated PF anchor instead of owning the whole firewall
- refreshes trust tables and expires block entries without reloading the full ruleset every time

## Install

Download the latest standalone release artifact:

```sh
curl -fsSLo orport-guard https://github.com/MinorGlitch/orport-guard/releases/latest/download/orport-guard
chmod +x ./orport-guard
./orport-guard --help
```

Update that standalone script later with:

```sh
./orport-guard update
```

Commands that need PF or crontab access will try to re-run themselves through `doas`, then `sudo`, if you did not elevate them first.

## Usage

Typical first install:

```sh
./orport-guard check
./orport-guard enable
./orport-guard status
```

What those do:

- `check` discovers targets and validates the rendered PF anchor without touching live PF
- `enable` installs the root PF hook if needed, reloads `pf.conf`, and loads the managed anchor
- `status` shows the live anchor state, detected targets, trust/block counts, and recent refresh/expire timestamps

If you want exact expiry cleanup and periodic trust refresh:

```sh
./orport-guard install-cron
```

That installs:

- `expire` every minute
- `refresh` every 6 hours

Useful day-2 commands:

```sh
./orport-guard apply
./orport-guard refresh
./orport-guard expire
./orport-guard disable
./orport-guard remove-cron
```

- `apply` reloads only the managed anchor after the PF root hook already exists
- `refresh` updates trust tables only
- `expire` removes old blocked entries immediately
- `disable` unloads the managed anchor and flushes its tables
- `remove-cron` removes only the managed cron block

## Notes

`orport-guard` manages one PF anchor:

```pf
anchor "orport-guard"
```

`enable` installs that hook automatically when it is missing. If you need to do it manually:

```sh
./orport-guard install-hook
pfctl -nf /etc/pf.conf
pfctl -f /etc/pf.conf
```

On NATed VPS setups, PF often sees the local post-NAT address instead of the public relay IP. `orport-guard` tries to detect that automatically. If there are multiple possible local addresses, it refuses to guess.

When inspecting live state, use anchor-scoped PF commands:

```sh
doas pfctl -a orport-guard -vvs rules
doas pfctl -a orport-guard -s Tables
doas pfctl -a orport-guard -t orport_guard_trust_v4 -T show | wc -l
doas pfctl -a orport-guard -t orport_guard_block_v4 -T show | wc -l
```

If you need to confirm what PF is actually seeing on FreeBSD, use `tcpdump` on the real interface, not `any`:

```sh
ifconfig -l
doas tcpdump -ni <interface> 'port <orport>'
```

For the full CLI surface, use:

```sh
./orport-guard --help
```

For local development from the repo instead of the release artifact:

```sh
./bin/orport-guard --help
```
