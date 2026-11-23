# Bifrost development contract

This file fixes the interfaces between the work packages. `docs/PLAN.md` says
what the product does; this file says how the pieces talk to each other.
Only the integrator changes this file. A package that needs a change writes it
in its report ("Contract change requests") and works around it meanwhile.

Files marked **baseline** below exist before the packages start. Packages do
not edit baseline files; they report needed changes instead.

## 1. Packages and file ownership

| Package | Owns (creates and edits) |
|---|---|
| baseline | `plugin/bifrost/lib/{env,validate,common}.sh`, `plugin/bifrost/scripts/{bifrost_config,bifrost_status}.sh`, `plugin/bifrost/version`, `tests/shell/{Dockerfile,run.sh,inner.sh,lib.sh,router-applets.txt}`, `tests/shell/mock/{base.sh,bifrostd}`, `tests/shell/mock/bin/{dbus,nvram,cru,logger,service,pidof,ip,uname}`, `tests/shell/t_{validate,common,dispatch}.sh`, `tools/check-sh.sh`, `tools/check-private.sh`, `.shellcheckrc`, `docs/dev/contract.md`, `docs/PLAN.md` |
| P1 core | `core/**`, `plugin/bifrost/lib/update.sh`, `plugin/bifrost/keys/**`, `tools/sign.sh`, `tools/dev-keys.sh`, `.github/workflows/core.yml`, `tests/shell/t_update*.sh`, `tests/shell/fixtures/update/**`, `tests/shell/mock/bin/{curl,df}` |
| P2 runtime | `plugin/bifrost/lib/{daemon,login,settings,migrate}.sh`, `plugin/bifrost/bin/bifrost`, `tests/shell/t_{daemon,login,settings,migrate}*.sh`, `tests/shell/fixtures/runtime/**` |
| P3 net | `plugin/bifrost/lib/{fw,dns,status,diag}.sh`, `tests/shell/t_{fw,dns,status,diag}*.sh`, `tests/shell/fixtures/net/**`, `tests/shell/mock/bin/{iptables,ip6tables}` |
| P4 web | `web/**`, `plugin/bifrost/webs/Module_bifrost.asp`, `plugin/bifrost/res/icon-bifrost.png`, `docs/images/**` |
| P5 release | `plugin/bifrost/{install.sh,uninstall.sh,.valid}`, `packaging/**`, `tests/container/**`, `tests/install/**`, `.github/workflows/{ci,release}.yml`, `NOTICE.md`, `CHANGELOG.md`, `README.md`, `README.en.md`, `docs/README.md`, `.gitignore` (append only) |

A package may read every file. It must not create or edit files outside its row.

## 2. Shell conventions

These add to PLAN section 14 and `AGENTS.md`.

- Load order: `base.sh` (top level, so it sees `$1`), `env.sh`, `validate.sh`,
  `common.sh`, then `daemon fw dns status login settings migrate update diag`
  (each only if present). See `scripts/bifrost_config.sh`.
- Lib files define functions and nothing else: no commands at the top level,
  no `exit`. Tunables use `: "${BIFROST_<NAME>:=<default>}"` in the owning lib
  file and are listed in the package report.
- Function names: `act_*` page actions, `job_*` background jobs, `hook_*` init.d
  hooks, `<lib>_*` everything else (for example `fw_apply`, `daemon_start`).
  Variables inside functions use a `_<abbr>_` prefix unique to the function.
- Errors: a function that fails calls `fail <code>` (sets `BIFROST_ERR`) and
  returns 1. Codes come from section 5 only. A function that runs at the end of
  a pipeline runs in a subshell, so its `BIFROST_ERR` is lost: do not rely on it.
- Locks: only entry points take the `state` lock (`with_lock state ...`):
  the dispatcher's hooks, `local watchdog`, `job_run`, and `act_*` functions
  that change state without a job. Lib functions (`daemon_start`, `fw_apply`,
  ...) never lock. `install.sh` and `uninstall.sh` take the `state` lock with
  `lock_acquire state 60` for their whole run.
- Responses: an `act_*` function never calls `respond`. It returns 0 or 1. On
  success it may set `BIFROST_RESULT` to a compact JSON object whose fields are
  added to `{"ok":true}`. Response text must not contain `& + % =` (see PLAN 2.4
  item 14); `respond` replaces such a response with `internal`.
- Anything that can take more than about 10 seconds is a job (section 6.2):
  the `act_*` function validates, then calls `job_start <job> [args]`.
- Commands that can hang run through `run_timeout` (or `ts_cli`/`ts_cli_t`).
- Use `cfg <key>` to read a Bifrost dbus key; never `dbus get` it directly.
- Secrets (auth keys, auth URLs) never go to logs, dbus, job files or responses.
- Paths always come from `env.sh` variables. No literal `/koolshare`, `/tmp`,
  `/jffs` paths in lib files.

## 3. Shared functions (baseline, `lib/common.sh`)

`fail`, `has_cmd`, `now`, `log <tag> <msg>`, `cfg`, `cfg_set`,
`atomic_write <path> [mode]` (stdin), `json_write <path>` (stdin),
`run_timeout <secs> cmd...` (124 on timeout), `ts_cli args...` (10 s),
`ts_cli_t <secs> args...`, `lock_acquire <name> [wait]`, `lock_release <name>`,
`with_lock <name> <wait> cmd...`, `bg_job`, `bg_drain` (tests), `respond`,
`respond_ok`, `respond_err <code>`, `job_file <job>`, `job_begin <job>`,
`job_run <job> args...`, `job_phase <job> <phase> [0-100]`,
`job_data <job> <json object>`, `job_end <job> ok|fail [code]`,
`job_running <job>`, `job_start <job> args...`, `daemon_pid`,
`daemon_running`, `orig_running`, `orig_installed`, `tun_exists`,
`sha256_file <file>`, `file_size <file>`.

Read the comments in `common.sh` for exact behaviour.

## 4. Entry points

`scripts/bifrost_config.sh` (baseline) checks every page parameter with
`valid_param` and the parameter count, turns `-` into an empty string, and
calls the function below through `run_act`, which sends exactly one response.

| Page action | Params | Function (owner) | Kind | Job |
|---|---|---|---|---|
| `enable` | — | `act_enable` (P2) | job | `daemon` |
| `disable` | — | `act_disable` (P2) | job | `daemon` |
| `connect` | — | `act_connect` (P2) | sync | — |
| `login` | server, auth key (`-` = empty) | `act_login` (P2) | job | `login` |
| `relogin` | — | `act_relogin` (P2) | job | `login` |
| `logout` | — | `act_logout` (P2) | sync | — |
| `purge` | — | `act_purge` (P2) | job | `daemon` |
| `set` | key, value (`-` = empty) | `act_set` (P2) | sync, or job `daemon` when a restart is needed | — / `daemon` |
| `migrate` | — | `act_migrate` (P2) | job | `migrate` |
| `core-check` | — | `act_core_check` (P1) | job | `update` |
| `core-update` | — | `act_core_update` (P1) | job | `update` |
| `core-rollback` | — | `act_core_rollback` (P1) | job | `update` |
| `core-arch` | `arm` or `arm64` | `act_core_arch` (P1) | job | `update` |
| `netcheck` | — | `act_netcheck` (P3) | job | `netcheck` |
| `ping` | tailnet IP | `act_ping` (P3) | sync, result fields | — |
| `logs` | — | `act_logs` (P3) | sync, writes `bifrost_logs.txt` and `bifrost_diag.json` | — |
| `ui` | lang, mode | `act_ui` (baseline) | sync | — |

`bifrost_status.sh <id>` calls `status_refresh` (P3), which writes
`bifrost_status.json`, then answers `{"ok":true}`.

Hooks and internal calls (dispatcher, under `with_lock state`):

| Call | Function (owner) |
|---|---|
| `start` (`init.d/S99bifrost.sh`, WAN up) | `hook_start` (P2): start when `bifrost_enable=1` and not running |
| `start_nat` (`init.d/N99bifrost.sh`) | `hook_start_nat` (P2): `fw_apply` when the daemon runs |
| `stop` | `hook_stop` (P2): `daemon_stop` |
| `local watchdog` (cru, every 2 min, lock wait 0) | `watchdog_run` (P2) |
| `local job <name> args` | `job_run` (common) → `job_<name>` |

`set` keys: `advertise_routes` (CIDR list, empty clears), `advertise_exit_node`
(0/1), `accept_routes` (0/1), `hostname` (empty = system name) go to tailscaled
with `tailscale set`; `port`, `local_access`, `lan_masq`, `snat`, `magicdns`,
`no_logs`, `mirror` are the dbus keys `bifrost_<key>`. Prefs keys need the
daemon running (`not_running` otherwise). After a sync `set`, `BIFROST_RESULT`
is `{"value":<read-back value>}`: a string for text keys, a boolean for 0/1
keys, a number for `port`, an array for `advertise_routes`.

`ping` result fields: `{"latency_ms":<int>,"path":"direct"|"derp"|"peer-relay","relay":"<derp code or empty>"}`.
Only IPs that `valid_tailnet_ip` accepts and that belong to a peer in the
current status are pinged (`unknown_peer` otherwise).

## 5. Error codes

The page translates these. Scripts use no other codes.

| Code | Meaning |
|---|---|
| `invalid_param` | a parameter failed validation |
| `unknown_action` | no such action |
| `not_implemented` | the function is missing (development only) |
| `internal` | unexpected failure; details in the script log |
| `busy` | the lock or the same job is taken |
| `timeout` | a command did not finish in time |
| `not_running` | the action needs the daemon |
| `already_running` | the daemon already runs |
| `conflict` | another tailscaled runs (the original plugin or the user's) |
| `core_missing` | the core file is missing or does not run |
| `no_tun` | `/dev/net/tun` is missing and `tun` cannot be loaded |
| `state_not_writable` | the state directory cannot be written |
| `start_failed` | the daemon exited or its socket did not appear in time |
| `watchdog_gave_up` | three restarts in 30 minutes failed |
| `cli_failed` | a `tailscale` command failed |
| `not_logged_in` | the action needs a logged-in device |
| `login_expired` | the interactive login was not finished in 10 minutes |
| `bad_server` | the control server URL is not accepted |
| `bad_authkey` | the auth key has the wrong format |
| `no_conf_dir` | dnsmasq has no `conf-dir` for `/jffs/configs/dnsmasq.d` |
| `no_magicdns` | the tailnet has no MagicDNS suffix |
| `fw_failed` | a firewall rule could not be added or confirmed |
| `unknown_peer` | the IP is not a device in this tailnet |
| `orig_missing` | migration: the original plugin's state file is missing |
| `orig_still_running` | migration: the original must be stopped in its own page first |
| `migrate_verify_failed` | migration: identity or state did not match; rolled back |
| `migrate_rollback_failed` | migration: the rollback also failed; see the log |
| `download_failed` | a download failed or was cut |
| `bad_signature` | no public key verifies the manifest |
| `bad_manifest` | the manifest has the wrong schema or fields |
| `old_serial` | the manifest's serial is not newer than the installed one |
| `plugin_too_old` | the core needs a newer plugin (`min_plugin`) |
| `no_arch` | the manifest has no file for this architecture |
| `hash_mismatch` | a size or sha256 does not match the manifest |
| `no_space` | not enough space for the new core |
| `core_test_failed` | the new core did not report the expected version |
| `update_verify_failed` | the new core did not come up; the old one is back |
| `no_prev` | no previous core to roll back to |
| `arch_unsupported` | the kernel cannot run the requested architecture |
| `up_to_date` | no newer core (core-check result, not shown as an error) |

## 6. Files the page reads

All in `$BIFROST_UPLOAD` (`/tmp/upload`), written with `json_write` or
`atomic_write`, read by the page as `GET /_temp/<name>`.

### 6.1 `bifrost_status.json` (P3 writes, P4 reads)

```json
{
  "schema": 1,
  "time": 1795430000,
  "state": "running",
  "error": null,
  "plugin": { "version": "0.1.0", "enabled": true },
  "core": {
    "tailscale": "1.104.7", "revision": 1, "serial": 7, "arch": "arm",
    "kernel_arch": "aarch64", "size": 25100448, "installed": 1795000000,
    "prev": true, "update": null
  },
  "daemon": { "running": true, "pid": 1234, "restarts": 0 },
  "conflict": { "original_installed": true, "original_running": false },
  "self": {
    "hostname": "router", "dns_name": "router.example.ts.net",
    "ips": ["100.64.0.1", "fd7a:115c:a1e0::1"], "tailnet": "example.ts.net",
    "magicdns_suffix": "example.ts.net", "control": "", "official": true,
    "key_expiry": "2027-05-01T00:00:00Z", "relay": "tok", "online": true
  },
  "prefs": {
    "advertise_routes": ["192.168.1.0/24"], "advertise_exit_node": false,
    "accept_routes": false, "hostname": ""
  },
  "routes": [{ "cidr": "192.168.1.0/24", "approved": true }],
  "exit_node": { "advertised": false, "approved": false },
  "settings": {
    "port": 41641, "local_access": true, "lan_masq": true, "snat": "auto",
    "snat_effective": false, "magicdns": false, "no_logs": true,
    "no_logs_forced": false, "mirror": ""
  },
  "lan": { "ip": "192.168.1.1", "cidr": "192.168.1.0/24", "sw_mode": 1 },
  "dns": { "conf_dir": true, "active": false },
  "auth_url": "",
  "health": [],
  "checks": [],
  "peers": [{
    "name": "laptop", "dns_name": "laptop.example.ts.net", "ip": "100.64.0.2",
    "ips": ["100.64.0.2"], "os": "macOS", "online": true, "path": "direct",
    "relay": "", "last_handshake": 1795429990, "rx": 1024, "tx": 2048,
    "exit_node_option": false, "routes": []
  }]
}
```

- `state`: `disabled`, `conflict`, `core_missing`, `starting`, `needs_login`,
  `needs_approval`, `stopped`, `running`, `error` (PLAN 7.1). Order of checks:
  core missing → `core_missing`; `bifrost_enable=0` → `disabled`; another
  tailscaled runs → `conflict`; `$BIFROST_DAEMON_ERR` has a code → `error`
  (that code is `error`); daemon not running → `error` with `start_failed`;
  then `BackendState`: `NoState`/`Starting` → `starting`, `NeedsLogin` →
  `needs_login`, `NeedsMachineAuth` → `needs_approval`, `Stopped` →
  `stopped`, `Running` → `running`.
- `self`, `prefs` are `null` when the daemon does not answer. `peers` is `[]`.
- `control` is `""` for Tailscale's own server; `official` is true then.
- `core.update` is `null` or `{"tailscale","revision","serial","tag"}` from
  `$BIFROST_RUN/core_latest.json` (P1 writes it) when its serial is larger.
- `core.installed` and `core.size` come from the installed core file
  (`date -r`, `file_size`). `core.prev`: `bifrostd.prev.gz` exists.
- `daemon.restarts`: watchdog restarts in the last 30 minutes
  (`$BIFROST_RUN/watchdog.restarts`, one Unix time per line, P2 writes).
- `routes[].approved`: the CIDR is in `Self.PrimaryRoutes` (or `AllowedIPs`)
  of `status --json`.
- `checks`: Bifrost's own findings, codes from `fw_incomplete`,
  `prefs_drift`, `dns_stale`, `watchdog_gave_up`, `clock_unsynced`.
- `auth_url` only in `needs_login`. Never in logs.
- `peers` holds at most 500 entries, online first, then by name.
- `path`: `direct` (CurAddr set), `peer-relay` (PeerRelay set), `derp`
  (otherwise); `relay`: DERP region code.

### 6.2 Job files `bifrost_<job>.json` (common writes the frame)

```json
{ "schema": 1, "job": "update", "running": true, "phase": "download",
  "progress": 40, "ok": null, "code": null, "started": 1795430000,
  "finished": null, "pid": 4321, "data": {} }
```

`phase` values (P4 translates them; an unknown phase is shown as is):

| Job | Phases | `data` |
|---|---|---|
| `daemon` | `queued start precheck starting waiting prefs firewall dns stopping cleanup purge done` | `{"action":"start"\|"stop"\|"restart"\|"purge"}` |
| `login` | `queued start running done` | `{"action":"login"\|"relogin","official":bool}` |
| `migrate` | `queued start precheck record backup stop_original wait_original copy starting verify rollback done` | `{"manual_stop":bool,"rolled_back":bool}` |
| `update` | `queued start manifest verify_manifest space download verify unpack test snapshot swap verify_running finalize rollback done` | `{"action":"check"\|"update"\|"rollback"\|"arch","latest":{tailscale,revision,serial,tag}\|null,"kept_prev":bool}` |
| `netcheck` | `queued start running done` | `{"report":{...}}` (below) |

`netcheck` report: `{"udp":bool,"ipv4":bool,"ipv6":bool,"mapping_varies":bool|null,"portmap":"<string>","preferred_derp":"<code>","derp":[{"code":"tok","latency_ms":30}]}`.

### 6.3 Other files

- `bifrost_logs.txt` (P3, `logs`): the diagnostic text, redacted (PLAN
  13.10). The page shows it and copies it as is for "复制诊断信息", so the
  page never redacts anything itself. Content, in English:
  1. one line listing the replacement kinds that were applied;
  2. `== summary ==`: plugin and core versions, state, `BackendState`,
     settings, prefs, environment checks (one `key: value` per line);
  3. `== bifrost.log ==` and its last 200 lines;
  4. `== bifrostd.log ==` and its last 200 lines.
- `bifrost_diag.json` (P3, `logs`): the environment checks for the
  diagnostics page (PLAN 13.4):
  `{"schema":1,"time":<unix>,"tun":bool,"fw_complete":bool|null,"conflict":bool,"wan_cgnat":bool|null,"jffs_free_kb":<int>|null,"time_synced":bool|null,"dnsmasq_conf_dir":bool}`.
  `null` means "could not be checked". `fw_complete` is `null` when the
  daemon does not run.

## 7. Cross-package functions

| Function | Owner | Used by | Contract |
|---|---|---|---|
| `daemon_start` | P2 | P1, P2, P5 | Full start sequence (PLAN 6.2) including `fw_apply`, `dns_apply`, watchdog. Writes a code to `$BIFROST_DAEMON_ERR` on failure, removes it on success |
| `daemon_stop` | P2 | P1, P2, P5 | Stop sequence (PLAN 6.3) including `fw_clear`, `dns_clear`. Succeeds when nothing runs |
| `daemon_restart` | P2 | P1, P2 | stop + start |
| `daemon_wait_ready <secs>` | P2 | P1 | 0 when `status --json` answers within the time |
| `prefs_json` | P2 | P3 | Prints `debug prefs` output (JSON) or fails `not_running` |
| `backend_state` | P2 | P1, P3 | Prints `BackendState` or fails |
| `fw_apply` / `fw_clear` | P3 | P2 | PLAN 9.3. Idempotent. `fw_apply` fails with `fw_failed` |
| `fw_check` | P3 | P2 (watchdog), P3 | 0 when every chain exists and its jump is first |
| `dns_apply` / `dns_clear` | P3 | P2 | PLAN 10. `dns_apply` with `bifrost_magicdns=0` equals `dns_clear` |
| `dns_check` | P3 | P2 (watchdog) | 0 when the dnsmasq file matches the current suffix |
| `status_refresh` | P3 | status script, P2 | Writes `bifrost_status.json` |
| `redact` | P3 | P3 | stdin → stdout, PLAN 13.10 |
| `lan_cidr` | P3 | P3, P2 | Prints the LAN prefix from `nvram get lan_ipaddr`/`lan_netmask` |
| `core_version` | P1 | P3, P5 | Prints the installed core's Tailscale version (`$BIFROST_CORE --version` first line) |
| `core_install_file <gz> <manifest json> <arch>` | P1 | P5 | Unpack, check `raw_sha256`, test `--version`, swap in (PLAN 15.1 step 4). Daemon must be stopped |
| `manifest_verify <json> <sig>` | P1 | P1, P5 (packaging) | 0 when any key in `$BIFROST_KEYS` verifies |

A package that needs another package's function before it exists stubs it in
its own tests, not in plugin files.

## 8. Core manifest and keys (P1 owns, everyone reads)

PLAN 12.2 plus a `build` object (for the core page):

```json
{
  "schema": 1, "serial": 7, "tailscale": "1.104.7", "revision": 1,
  "tag": "core-1.104.7-1", "min_plugin": "0.1.0",
  "build": { "go": "1.27.4", "commit": "cbc74fe48ef1b1649f69a4d9a602319427e25102",
             "omit": ["aws", "..."] },
  "assets": { "arm": { "file": "bifrost-core-1.104.7-1-linux-arm.gz",
                       "size": 9590179, "sha256": "...",
                       "raw_size": 25100448, "raw_sha256": "..." } }
}
```

- Installed copy: `$BIFROST_MANIFEST`. The package copy: `bin/core.json`
  next to `bin/bifrostd.gz` (unsigned in the package; it is checked against
  the file hashes only).
- Public keys: `$BIFROST_KEYS/*.pub.pem` (ECDSA P-256, PEM). The repository
  ships no production key until the owner creates one; tests make their own
  keys under `/tmp`.
- `$BIFROST_RUN/core_latest.json`: the last verified channel manifest.

## 9. Tests

- Shell tests: `tests/shell/t_<area>.sh`, run with `tests/shell/run.sh`
  (all) or `tests/shell/run.sh t_<area>.sh`. Use `tests/shell/lib.sh`.
  Fixtures under `tests/shell/fixtures/<package>/`. All example data is made
  up: `example.ts.net`, `100.64.0.0/10`, `192.168.1.0/24`, documentation
  prefixes (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`).
- The fake core (`tests/shell/mock/bifrostd`) and the mocks are documented in
  their headers. A package that needs more mock behaviour adds a mock it owns
  (section 1) or stubs functions in its test file.
- `BIFROST_BG_SYNC=1` (set by `t_setup`) queues jobs; call `bg_drain`.
- Tests must not need the network, the router, or root on the host.
- Install, upgrade and uninstall tests (PLAN 13.11 "安装测试", 15) live in
  `tests/install/` (P5), not in `web/test/`.

## 10. Page assets (P4 builds, P5 packages)

- `web/build.mjs` writes `web/dist/Module_bifrost.asp`,
  `web/dist/res/bifrost-app.<20 hex>.js` and `.css`. The hash is the first 20
  hex digits of sha256 over the JS and CSS contents.
- `plugin/bifrost/webs/Module_bifrost.asp` is the template with the
  placeholder `__BIFROST_ASSETS__`.
- `packaging/build.sh` runs the web build and puts the generated `.asp` in
  `webs/` and the pair in `res/` of the package. Install order: PLAN 15.1 step 6.
- The page uses only the requests in PLAN 13.6 and section 4 here, and reads
  only the files in section 6.

## 11. Gates

Every package must pass, from the repository root:

```sh
tools/check-sh.sh          # shellcheck, BusyBox 1.25 sh -n, forbidden patterns
tools/check-private.sh     # no private details
tests/shell/run.sh         # all shell tests, including the baseline ones
```

P4 also: `cd web && npm ci && npm run check && npm test && npm run build`
(the scripts are defined by P4 and listed in its report). P5 also its own
container and packaging checks.
