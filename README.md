# orport-guard

This is my attempt to make the Tor relay DDoS mitigation work that people have been doing on Linux usable on FreeBSD with PF.

The other projects in this space are built around `iptables`, `ipset`, `conntrack`, `recent`, and similar Linux pieces. That does not help much if your relay is on FreeBSD. The point of this repository is not to port those scripts line by line. The point is to keep the same idea, but express it in a way that fits PF and can live on a BSD relay without owning the whole firewall.

## How does it work?

`orport-guard` manages one dedicated PF anchor for your relay ORPorts.

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
./bin/orport-guard enable
./bin/orport-guard check
./bin/orport-guard apply
./bin/orport-guard refresh
./bin/orport-guard expire
./bin/orport-guard render
./bin/orport-guard status
./bin/orport-guard install-hook
./bin/orport-guard install-cron
./bin/orport-guard remove-cron
./bin/orport-guard disable
```

If you just want the flags:

```sh
./bin/orport-guard --help
```

## PF integration

This tool only manages one anchor and the tables used by that anchor.

Your main `pf.conf` must contain:

```pf
anchor "orport-guard"
```

You can add that line with the CLI:

```sh
./bin/orport-guard install-hook
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
/var/db/orport-guard/orport_guard-anchor.conf
```

If you do not want to touch live PF yet, use `render` first, inspect the file, and run `pfctl -n` against it yourself.

## Quick start

For most operators, the flow should be:

```sh
./bin/orport-guard check
./bin/orport-guard enable
./bin/orport-guard status
```

`check` renders the anchor and runs PF syntax checks without loading it.
`enable` makes sure the root hook exists, reloads `pf.conf`, then applies the managed anchor.
If you want exact expiry cleanup and periodic trust refresh, install the managed cron block afterwards:

```sh
./bin/orport-guard install-cron
```

If you want the lower-level steps, those still exist.

If discovery is not what you want yet, force the exact target:

```sh
./bin/orport-guard --target 198.51.100.10:9001 render
```

If `TARGETS` or `--target` is set, explicit targets take precedence and autodiscovery is skipped.

On NATed VPS setups, PF usually sees the post-NAT local address, not the public relay address.
`orport-guard` now tries to correct that automatically:

- if the configured target is not local and there is one clear PF-visible local address for that family, it rewrites the target to the local address and tells you
- if there are multiple possible local addresses, it refuses to guess and exits with the candidate list

That matters because a rule for the public IP can load cleanly and still never match a packet if the host actually receives traffic on a different local address such as `192.0.2.12`.

When you are happy with what it found and rendered:

```sh
./bin/orport-guard apply
```

If you want to back it out:

```sh
./bin/orport-guard disable
```

## FreeBSD deployment notes

These are the things that matter most on a real FreeBSD relay.

### PF usually sees the local post-NAT address

On VPS setups with provider NAT or 1:1 forwarding, PF often sees the local address on the VM, not the public relay IP.

That means a target such as:

```text
203.0.113.165:9001
```

can be correct from the outside and still be wrong for PF on the host.

`orport-guard` now tries to correct that automatically when there is one clear local address for the listener. If there are multiple possible local addresses, it refuses to guess and tells you what the candidates are.

If you need to confirm what PF is really seeing, look at the live packets on the real interface and check the destination address there.

### Use `tcpdump` on the real interface, not `any`

FreeBSD does not have Linux's `any` pseudo-interface.

Find the interface first:

```sh
ifconfig -l
ifconfig
```

Then capture on the real interface, for example:

```sh
doas tcpdump -ni ext0 'dst host 192.0.2.12 and tcp dst port 9001'
```

or more broadly:

```sh
doas tcpdump -ni ext0 'port 9001'
```

If `tcpdump` shows traffic for the relay port but the `orport-guard protect ...` rule still has zero packets and zero states, your target address is wrong for what PF is actually seeing.

### Use anchor-scoped `pfctl` commands

The managed trust and block tables live inside the `orport-guard` anchor.

Do not inspect them with:

```sh
pfctl -s Tables
```

Use:

```sh
doas pfctl -a orport-guard -s Tables
doas pfctl -a orport-guard -t orport_guard_trust_v4 -T show | wc -l
doas pfctl -a orport-guard -t orport_guard_block_v4 -T show | wc -l
doas pfctl -a orport-guard -vvs rules
```

That is the correct way to verify the live anchor state.

### Verify the managed cron block

If you install the managed cron entries:

```sh
./bin/orport-guard install-cron
```

verify them with:

```sh
doas crontab -l
```

and confirm that `status` reports:

```text
Cron installed: yes
Block expiry: 300s (managed by cron)
```

You can also run the scheduled commands manually once:

```sh
doas ./bin/orport-guard expire
doas ./bin/orport-guard refresh
```

## Configuration

The sample config is:

```text
./etc/orport-guard.conf
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
./bin/orport-guard --profile aggressive apply
```

That profile tightens the defaults to roughly match the sharper Linux-era recipes:

- `max-src-states 4`
- `max-src-conn 4`
- `max-src-conn-rate 7/1`
- `BLOCK_EXPIRE_SECONDS=300`

Timed block entries can be cleaned in two ways:

- manually with `./bin/orport-guard expire`
- automatically with `./bin/orport-guard install-cron`

Without cron, expiry is lazy on the next `enable`, `apply`, or `refresh` run once entries are older than the configured age.
That means a `300` second ban is really "at least 300 seconds, then cleared on the next orport-guard mutation run".
The default profile also uses the same `300` second expiry and differs mainly in the softer connection and rate thresholds.

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
