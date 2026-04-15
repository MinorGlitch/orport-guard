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
./bin/tor-anchor apply
./bin/tor-anchor refresh
./bin/tor-anchor render
./bin/tor-anchor status
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

That is the only required hook. After that, `apply` will render and load the managed anchor. By default the rendered file ends up here:

```text
/var/db/tor-anchor/tor_anchor-anchor.conf
```

If you do not want to touch live PF yet, use `render` first, inspect the file, and run `pfctl -n` against it yourself.

## Quick start

I would test it like this on a live relay:

```sh
./bin/tor-anchor render
pfctl -n -a tor-anchor -f /var/db/tor-anchor/tor_anchor-anchor.conf
./bin/tor-anchor status
```

If discovery is not what you want yet, force the exact target:

```sh
./bin/tor-anchor --target 198.51.100.10:9001 render
```

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

CLI flags override the config. The config overrides discovery.

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
