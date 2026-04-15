# tor-anchor

`tor-anchor` is a small PF-based helper for FreeBSD Tor relay operators.

It builds and manages a dedicated PF anchor for relay ORPorts. The goal is simple: keep the relay-specific filtering logic isolated from the rest of the host firewall, and make it easy to inspect, refresh, load, and remove without rewriting the main `pf.conf`.

This project is intentionally narrow:

- FreeBSD first
- PF only
- shell, not a daemon
- focused on Tor relay ORPorts, not general firewall management

## What it does

`tor-anchor`:

- discovers relay listeners from Tor config
- falls back to `sockstat` when `ORPort` is set without an explicit address
- fetches Tor authority and Snowflake trust lists
- renders a dedicated PF anchor
- loads that anchor without touching the rest of your ruleset
- refreshes trust tables separately from full anchor reloads
- shows the current managed state with a read-only `status` command

The managed commands are:

```sh
./bin/tor-anchor apply
./bin/tor-anchor refresh
./bin/tor-anchor render
./bin/tor-anchor status
./bin/tor-anchor disable
```

Run `./bin/tor-anchor --help` for flags.

## How it fits into PF

This tool does not own your firewall. It only owns one anchor and the tables used by that anchor.

Your main `pf.conf` must include:

```pf
anchor "tor-anchor"
```

After that, `apply` will render the managed rules and load them into that anchor. By default the rendered file lives under:

```text
/var/db/tor-anchor/tor_anchor-anchor.conf
```

If you do not want to touch live PF yet, use `render` first and inspect the output before loading anything.

## Configuration

The sample config is `./etc/tor-anchor.conf`.

It is a plain shell config. No YAML, no JSON.

The main knobs are:

- `TARGETS`
  Explicit OR targets such as `198.51.100.10:9001 [2001:db8::10]:9001`
- `TORRC_PATHS`
  Paths used for auto-discovery
- `EXTRA_TRUST`
  Extra trusted IPs or networks
- `EXEMPT_SERVICES`
  Extra local services to pass quickly in the managed anchor
- `MAX_SRC_STATES`
- `MAX_SRC_CONN`
- `MAX_SRC_CONN_RATE_COUNT`
- `MAX_SRC_CONN_RATE_WINDOW`

CLI flags override the config file. The config file overrides discovery.

## A cautious first run

On a production relay, do not start with `apply`.

Start with:

```sh
./bin/tor-anchor render
```

Then syntax-check the rendered anchor with `pfctl -n`, confirm the discovered targets are correct, and only then load it.

If you want to avoid discovery entirely on the first run, pass explicit targets:

```sh
./bin/tor-anchor --target 198.51.100.10:9001 render
```

Once the anchor is live, you can inspect it with:

```sh
./bin/tor-anchor status
```

And remove only the managed anchor state with:

```sh
./bin/tor-anchor disable
```

## Testing

There is a small shell test harness under `./tests`.

Run it with:

```sh
./tests/run.sh
```

The tests use stubs for `pfctl`, `curl`, and `sockstat`, so they verify the project logic and workflow without touching a real firewall.

## Notes

- This is not a Linux iptables port.
- This is not a general-purpose PF framework.
- OpenBSD support may come later, but the current target is FreeBSD.

If you are evaluating it on a live relay, treat `render` and `pfctl -n` as the normal starting point, not as optional extra caution.
