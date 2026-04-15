# tor-anchor

This is my attempt to make the Tor relay DDoS mitigation work that people have been doing on Linux usable on FreeBSD with PF.

The other projects in this space are built around `iptables`, `ipset`, `conntrack`, `recent`, and similar Linux pieces. That does not help much if your relay is on FreeBSD. The point of this repository is not to port those scripts line by line. The point is to keep the same idea, but express it in a way that fits PF and can live on a BSD relay without owning the whole firewall.

## How does it work?

`tor-anchor` manages one dedicated PF anchor for your relay ORPorts.

It does a few things:

- discovers relay listeners from Tor config
- falls back to `sockstat` if `ORPort` exists but the address is not explicit
- fetches Tor authority and Snowflake trust lists
- renders PF rules for the discovered ORPorts
- loads those rules into one anchor instead of rewriting the host firewall
- refreshes trust tables without needing a full reload

The general rule set is:

1. never let this tool own your full `pf.conf`
2. trust Tor authorities and Snowflakes first
3. protect only the relay ORPorts
4. use PF state tracking and overload tables to block abusive sources
5. keep the managed state easy to inspect and easy to remove

## Commands

The main commands are:

```sh
./bin/tor-anchor enable
./bin/tor-anchor check
./bin/tor-anchor apply
./bin/tor-anchor refresh
./bin/tor-anchor render
./bin/tor-anchor status
./bin/tor-anchor install-hook
./bin/tor-anchor disable
```

If you just want the flags:

```sh
./bin/tor-anchor --help
```

## PF integration

This tool only manages one anchor and the tables used by that anchor.

Your main `pf.conf` must contain:

```pf
anchor "tor-anchor"
```

You can add that line with the CLI:

```sh
./bin/tor-anchor install-hook
```

That edits `/etc/pf.conf` by default. If you keep your PF config somewhere else, use `--pf-conf /path/to/pf.conf`.
The hook is placed before the first PF filter rule so it actually sees relay traffic.

After adding the hook, reload PF:

```sh
pfctl -nf /etc/pf.conf
pfctl -f /etc/pf.conf
```

That is the only required root hook. After that, `apply` will render and load the managed anchor. By default the rendered file ends up here:

```text
/var/db/tor-anchor/tor_anchor-anchor.conf
```

If you do not want to touch live PF yet, use `render` first, inspect the file, and run `pfctl -n` against it yourself.

## Quick start

For most operators, the flow should be:

```sh
./bin/tor-anchor check
./bin/tor-anchor enable
./bin/tor-anchor status
```

`check` renders the anchor and runs PF syntax checks without loading it.
`enable` makes sure the root hook exists, reloads `pf.conf`, then applies the managed anchor.

If you want the lower-level steps, those still exist.

If discovery is not what you want yet, force the exact target:

```sh
./bin/tor-anchor --target 198.51.100.10:9001 render
```

If `TARGETS` or `--target` is set, explicit targets take precedence and autodiscovery is skipped.

When you are happy with what it found and rendered:

```sh
./bin/tor-anchor apply
```

If you want to back it out:

```sh
./bin/tor-anchor disable
```

## Configuration

The sample config is:

```text
./etc/tor-anchor.conf
```

It is just a shell config file. No YAML, no JSON, no extra parser.

The main settings are:

- `PROFILE`
  `default` or `aggressive`
- `TARGETS`
  explicit OR targets such as `198.51.100.10:9001 [2001:db8::10]:9001`
- `TORRC_PATHS`
  where discovery should look for Tor config
- `EXTRA_TRUST`
  extra trusted IPs or networks
- `EXEMPT_SERVICES`
  extra local services to pass quickly in the managed anchor
- `MAX_SRC_STATES`
- `MAX_SRC_CONN`
- `MAX_SRC_CONN_RATE_COUNT`
- `MAX_SRC_CONN_RATE_WINDOW`
- `BLOCK_EXPIRE_SECONDS`
  lazily expire overload-blocked sources once they are older than this many seconds

CLI flags override the config. The config overrides discovery.

## Aggressive mode

The default profile is intentionally conservative.

If your relay is under active ORPort abuse, use:

```sh
./bin/tor-anchor --profile aggressive apply
```

That profile tightens the defaults to roughly match the sharper Linux-era recipes:

- `max-src-states 4`
- `max-src-conn 4`
- `max-src-conn-rate 7/1`
- `BLOCK_EXPIRE_SECONDS=300`

Timed block entries are expired lazily on the next `enable`, `apply`, or `refresh` run once they are older than the configured age.
That means a `300` second ban is really "at least 300 seconds, then cleared on the next tor-anchor mutation run".
The default profile also uses the same lazy `300` second expiry and differs mainly in the softer connection and rate thresholds.

## What this is not

This is not:

- a Linux iptables port
- a daemon
- a full PF management framework
- a promise that one ruleset fits every relay host

The scope here is intentionally small. I want one tool that can discover a relay, render the PF rules for it, load them into a dedicated anchor, refresh trust tables, and get out of the way.

## Testing

There is a small shell test harness under:

```text
./tests
```

Run it with:

```sh
./tests/run.sh
```

Those tests use stubs for `pfctl`, `curl`, and `sockstat`, so they verify the shell logic and workflow without touching a real firewall.

## Why another attempt?

Because the base ideas are useful, but the implementation story on BSD is still weak.

If you run your relay on FreeBSD, you should not have to pretend the machine is Linux just to get a relay-specific mitigation layer in front of your ORPort.

That is all this repository is trying to solve.
