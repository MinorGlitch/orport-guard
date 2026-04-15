# tor-anchor

`tor-anchor` is a FreeBSD-first PF operator CLI for protecting Tor relay ORPorts with a dedicated PF anchor.

## Commands

```sh
./bin/tor-anchor apply
./bin/tor-anchor refresh
./bin/tor-anchor render
./bin/tor-anchor status
./bin/tor-anchor disable
```

## PF integration

The tool does not rewrite your main `pf.conf`. Your root ruleset must contain a hook for the managed anchor:

```pf
anchor "tor-anchor"
```

Once that hook exists, `apply` renders the anchor into the state directory and loads it with:

```sh
pfctl -a tor-anchor -f /var/db/tor-anchor/tor_anchor-anchor.conf
```

## Configuration

The sample config lives at `./etc/tor-anchor.conf`. It is a shell-style config with space-separated lists for:

- `TARGETS` such as `198.51.100.10:9001 [2001:db8::10]:9001`
- `EXTRA_TRUST` for explicit trust entries
- `EXEMPT_SERVICES` for explicitly passed local services

CLI flags override the config file. Config values override discovery.

## Discovery

The tool discovers targets from Tor config first and uses `sockstat` as a fallback when `ORPort` is configured without an explicit address. When discovery still cannot identify any target, `apply` fails safely unless explicit `TARGETS` or `--target` values were provided.

## Testing

Run the shell test harness with:

```sh
./tests/run.sh
```
