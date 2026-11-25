import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import {
  ApiError,
  dash,
  parseActionPayload,
  parseScriptBody,
  pollJob,
  postScript,
  readJob,
  readUiConfig,
} from "../src/core/api.ts";
import {
  analyzeKeyExpiry,
  describeState,
  formatBytes,
  formatDateTime,
  formatHandshakeAge,
} from "../src/core/format.ts";
import {
  cidr4Overlaps,
  findOverlappingPeerRoutes,
  isAccessingFromTailnet,
  isHttpLoginServer,
  isSafeHttpUrl,
  validArch,
  validAuthKey,
  validBool01,
  validCidr4,
  validCidr4List,
  validDnsName,
  validHostname,
  validIpv4,
  validLang,
  validLoginServer,
  validMirror,
  validMode,
  validName,
  validParam,
  validPort,
  validSnat,
  validTailnetIp,
  validUint,
} from "../src/core/validate.ts";
import {
  getKumoTranslations,
  t,
  translateCheck,
  translateError,
  translatePhase,
  translateState,
} from "../src/i18n/index.ts";
import { en } from "../src/i18n/en.ts";
import { zhCN } from "../src/i18n/zh-CN.ts";
import { createPreviewServer, sanitizeScriptResponse } from "../preview/server.mjs";
import { once } from "node:events";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "../..");
const SRC_ROOT = resolve(__dirname, "../src");

function extractShellValidateCases() {
  // Reuse the shell suite's generated one-argument cases without creating a router sandbox.
  const suite = readFileSync(join(REPO_ROOT, "tests/shell/t_validate.sh"), "utf8");
  const driver = `
set -eu
t_setup() { :; }
t_load() { . plugin/bifrost/lib/env.sh; }
t_done() { :; }
emit() {
  if [ "$#" -eq 4 ]; then printf '%s\\037%s\\037%s\\037%s\\036' "$@"; fi
}
ok() { emit 1 "$@"; }
no() { emit 0 "$@"; }
`;
  const raw = execFileSync("/bin/sh", {
    cwd: REPO_ROOT,
    input: suite.replace(". tests/shell/lib.sh", driver),
    encoding: "utf8",
  });
  return raw
    .split("\x1e")
    .filter(Boolean)
    .map((record) => {
      const [expected, label, fn, value] = record.split("\x1f");
      return { expected: expected === "1", label, fn, value };
    });
}

describe("validate.ts parity with plugin/bifrost/lib/validate.sh (via tests/shell/t_validate.sh)", () => {
  const tsValidators = {
    valid_uint: validUint,
    valid_port: validPort,
    valid_bool01: validBool01,
    valid_snat: validSnat,
    valid_lang: validLang,
    valid_mode: validMode,
    valid_arch: validArch,
    valid_name: validName,
    valid_param: validParam,
    valid_ipv4: validIpv4,
    valid_cidr4: validCidr4,
    valid_cidr4_list: validCidr4List,
    valid_hostname: validHostname,
    valid_dns_name: validDnsName,
    valid_login_server: validLoginServer,
    valid_authkey: validAuthKey,
    valid_mirror: validMirror,
    valid_tailnet_ip: validTailnetIp,
  };

  it("matches the one-argument validator test vectors in tests/shell/t_validate.sh", () => {
    const cases = extractShellValidateCases();
    assert.ok(cases.length >= 100, `expected >= 100 cases from t_validate.sh, got ${cases.length}`);

    const seenFns = new Set();
    for (const c of cases) {
      const validator = tsValidators[c.fn];
      assert.ok(validator, `unmapped shell validator in t_validate.sh: ${c.fn}`);
      seenFns.add(c.fn);
      assert.equal(
        validator(c.value),
        c.expected,
        `mismatch for ${c.fn}(${JSON.stringify(c.value)}) [${c.label}]`,
      );
    }
    for (const fn of Object.keys(tsValidators)) {
      assert.ok(seenFns.has(fn), `expected t_validate.sh to cover ${fn}`);
    }
  });

  it("validates http(s) URL safety and http login server warning helper", () => {
    assert.equal(isHttpLoginServer("http://192.0.2.10:8080"), true);
    assert.equal(isHttpLoginServer("https://hs.example.org"), false);

    assert.equal(isSafeHttpUrl("https://login.tailscale.com/a/demo"), true);
    assert.equal(isSafeHttpUrl("http://192.0.2.10:8080/register/1"), true);
    assert.equal(isSafeHttpUrl("javascript:alert(1)"), false);
    assert.equal(isSafeHttpUrl("JAVASCRIPT:alert(1)"), false);
    assert.equal(isSafeHttpUrl("data:text/html,<script>alert(1)</script>"), false);
    assert.equal(isSafeHttpUrl("ftp://example.org/a"), false);
    assert.equal(isSafeHttpUrl(""), false);
    assert.equal(isSafeHttpUrl("not a url"), false);
  });

  it("detects CIDR overlaps and tailnet access origins", () => {
    assert.equal(cidr4Overlaps("192.168.1.0/24", "192.168.1.128/25"), true);
    assert.equal(cidr4Overlaps("192.168.1.0/24", "192.168.0.0/16"), true);
    assert.equal(cidr4Overlaps("192.168.1.0/24", "192.168.2.0/24"), false);

    const overlaps = findOverlappingPeerRoutes("192.168.1.0/24", [
      {
        name: "office-gw",
        dns_name: "office-gw.example.ts.net",
        ip: "100.64.0.5",
        ips: ["100.64.0.5"],
        os: "linux",
        online: true,
        path: "direct",
        relay: "",
        last_handshake: 0,
        rx: 0,
        tx: 0,
        exit_node_option: false,
        routes: ["198.51.100.0/24", "192.168.0.0/16"],
      },
    ]);
    assert.deepEqual(overlaps, [{ peer: "office-gw", cidr: "192.168.0.0/16" }]);

    const self = {
      hostname: "router",
      dns_name: "router.example.ts.net",
      ips: ["100.64.0.1", "fd7a:115c:a1e0::1"],
      tailnet: "example.ts.net",
      magicdns_suffix: "example.ts.net",
      control: "",
      official: true,
      key_expiry: "",
      relay: "tok",
      online: true,
    };
    assert.equal(isAccessingFromTailnet("100.64.0.1", self), true);
    assert.equal(isAccessingFromTailnet("[fd7a:115c:a1e0::1]", self), true);
    assert.equal(isAccessingFromTailnet("router.example.ts.net", self), true);
    assert.equal(isAccessingFromTailnet("192.168.1.1", self), false);
    assert.equal(isAccessingFromTailnet("127.0.0.1", self), false);
  });
});

describe("preview server contract compliance (valid_param and safe responses)", () => {
  it("sanitizes responses containing forbidden & + % = characters", () => {
    assert.equal(sanitizeScriptResponse({ ok: true, value: "router-1" }), '{"ok":true,"value":"router-1"}');
    for (const bad of ["a&b", "a+b", "a%20b", "a=b"]) {
      assert.equal(
        sanitizeScriptResponse({ ok: true, value: bad }),
        '{"ok":false,"code":"internal"}',
      );
    }
  });

  it("enforces valid_name and valid_param on POST /_api/ params", async (ctx) => {
    const server = createPreviewServer({ initialState: "running" });
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    ctx.after(() => new Promise((resolveClose) => server.close(resolveClose)));
    const base = `http://127.0.0.1:${server.address().port}`;

    const callApi = async (params) => {
      const res = await fetch(`${base}/_api/`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" },
        body: JSON.stringify({ id: 1, method: "bifrost_config.sh", params, fields: {} }),
      });
      return JSON.parse(parseScriptBody(await res.text()).result);
    };

    assert.deepEqual(await callApi(["BadAction"]), { ok: false, code: "invalid_param" });
    assert.deepEqual(await callApi(["set", "hostname", "bad;cmd"]), { ok: false, code: "invalid_param" });
    assert.deepEqual(await callApi(["set", "hostname", "bad host"]), { ok: false, code: "invalid_param" });
    assert.deepEqual(await callApi(["set", "hostname", "ok-router"]), { ok: true, value: "ok-router" });
  });
});

describe("i18n dictionaries, translators, and unused key guard", () => {
  it("keeps zh-CN and en keys strictly aligned", () => {
    assert.deepEqual(Object.keys(en).sort(), Object.keys(zhCN).sort());
  });

  it("has no unused static message keys in zh-CN / en", () => {
    const walk = (dir) => {
      const out = [];
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = join(dir, entry.name);
        if (entry.isDirectory()) out.push(...walk(full));
        else if (/\.(ts|tsx)$/.test(entry.name)) out.push(full);
      }
      return out;
    };
    const sourceText = walk(SRC_ROOT)
      .filter((p) => !p.endsWith("zh-CN.ts") && !p.endsWith("en.ts"))
      .map((p) => readFileSync(p, "utf8"))
      .join("\n");

    const dynamicPrefixes = ["err.", "phase.", "state.", "check."];
    const unused = Object.keys(zhCN).filter(
      (key) =>
        !dynamicPrefixes.some((p) => key.startsWith(p)) &&
        !sourceText.includes(`"${key}"`) &&
        !sourceText.includes(`'${key}'`),
    );
    assert.deepEqual(unused, []);
  });

  it("builds Kumo translations strictly from the dictionaries", () => {
    const zhKumo = getKumoTranslations("zh-CN");
    const enKumo = getKumoTranslations("en");
    assert.equal(zhKumo.label?.optional, zhCN["common.optional"]);
    assert.equal(zhKumo.layerDialog?.close, zhCN["common.close"]);
    assert.equal(zhKumo.breadcrumbs?.label, zhCN["kumo.breadcrumbLabel"]);
    assert.equal(enKumo.label?.optional, en["common.optional"]);
    assert.equal(enKumo.layerDialog?.close, en["common.close"]);
    assert.equal(enKumo.breadcrumbs?.label, en["kumo.breadcrumbLabel"]);
  });

  it("replaces {name} placeholders only", () => {
    assert.equal(t("zh-CN", "overview.keyExpiringSoon", { days: 7 }), "密钥将在 7 天后到期，建议尽快重新登录。");
    assert.equal(t("en", "overview.keyExpiringSoon", { days: 7 }), "Device key expires in 7 days. Consider re-authenticating soon.");
    assert.equal(t("en", "overview.keyExpiringSoon", {}), "Device key expires in {days} days. Consider re-authenticating soon.");
  });

  it("translates every contract error code, phase, state, check and falls back cleanly", () => {
    const errorCodes = [
      "invalid_param", "unknown_action", "not_implemented", "internal", "busy",
      "timeout", "not_running", "already_running", "conflict", "core_missing",
      "no_tun", "state_not_writable", "start_failed", "watchdog_gave_up", "cli_failed",
      "not_logged_in", "login_expired", "bad_server", "bad_authkey", "no_conf_dir",
      "no_magicdns", "fw_failed", "unknown_peer", "orig_missing", "orig_still_running",
      "migrate_verify_failed", "migrate_rollback_failed", "download_failed", "bad_signature",
      "bad_manifest", "old_serial", "plugin_too_old", "no_arch", "hash_mismatch",
      "no_space", "core_test_failed", "update_verify_failed", "no_prev",
      "arch_unsupported", "up_to_date",
    ];
    for (const code of errorCodes) {
      assert.equal(Object.hasOwn(zhCN, `err.${code}`), true, `missing err.${code}`);
      for (const lang of ["zh-CN", "en"]) {
        const msg = translateError(lang, code);
        assert.ok(msg.length > 0 && !msg.includes(`(${code})`) && !msg.includes(`（错误码：${code}）`));
      }
    }
    assert.match(translateError("zh-CN", "future_code"), /future_code/);
    assert.match(translateError("en", "future_code"), /future_code/);
    assert.match(translateError("zh-CN", "http_error", 503), /503/);

    const phases = [
      "queued", "start", "precheck", "starting", "waiting", "prefs", "firewall",
      "dns", "stopping", "cleanup", "purge", "running", "record", "backup",
      "stop_original", "wait_original", "copy", "verify", "rollback", "manifest",
      "verify_manifest", "space", "download", "unpack", "test", "snapshot",
      "swap", "verify_running", "finalize", "done",
    ];
    for (const ph of phases) {
      assert.equal(Object.hasOwn(zhCN, `phase.${ph}`), true, `missing phase.${ph}`);
      assert.ok(!translatePhase("zh-CN", ph).includes(`（${ph}）`));
      assert.ok(!translatePhase("en", ph).includes(`(${ph})`));
    }
    assert.match(translatePhase("zh-CN", "custom_phase"), /custom_phase/);

    const states = [
      "disabled", "conflict", "core_missing", "starting", "needs_login",
      "needs_approval", "stopped", "running", "error",
    ];
    for (const s of states) {
      assert.equal(Object.hasOwn(zhCN, `state.${s}`), true, `missing state.${s}`);
      assert.ok(!translateState("zh-CN", s).includes(`（${s}）`));
      assert.ok(!translateState("en", s).includes(`(${s})`));
    }
    assert.match(translateState("en", "brand_new"), /brand_new/);

    const checks = ["fw_incomplete", "prefs_drift", "dns_stale", "watchdog_gave_up", "clock_unsynced"];
    for (const c of checks) {
      assert.equal(Object.hasOwn(zhCN, `check.${c}`), true, `missing check.${c}`);
      assert.ok(!translateCheck("zh-CN", c).includes(`（${c}）`));
      assert.ok(!translateCheck("en", c).includes(`(${c})`));
    }
    assert.match(translateCheck("zh-CN", "new_check"), /new_check/);
  });
});

describe("api.ts envelope parsing, request contract, and pollJob recovery", () => {
  it("converts empty params to dash", () => {
    assert.equal(dash(""), "-");
    assert.equal(dash("abc"), "abc");
  });

  it("parses Koolshare httpdb string result envelopes and error responses", () => {
    assert.deepEqual(parseActionPayload({ result: '{"ok":true,"value":41641}' }), { ok: true, value: 41641 });
    assert.deepEqual(parseActionPayload({ result: { ok: true } }), { ok: true });
    assert.throws(
      () => parseActionPayload({ result: '{"ok":false,"code":"busy"}' }),
      (err) => err instanceof ApiError && err.code === "busy",
    );
    assert.throws(
      () => parseActionPayload({ result: "not-json" }),
      (err) => err instanceof ApiError && err.code === "invalid_response",
    );
  });

  it("reads the software center's unescaped script replies", () => {
    // Body as returned by software center 1.9.61: the reply is not escaped.
    assert.deepEqual(parseScriptBody('{"result": "{"ok":true}"}'), { result: '{"ok":true}' });
    assert.deepEqual(
      parseActionPayload(parseScriptBody('{"result": "{"ok":true,"msg":"a \\"b\\""}"}\n')),
      { ok: true, msg: 'a "b"' },
    );
    assert.deepEqual(parseScriptBody(JSON.stringify({ result: '{"ok":true}' })), { result: '{"ok":true}' });
    for (const bad of ["", "ok", '{"result": "x"', '<html>{"result": ""}</html>']) {
      assert.throws(() => parseScriptBody(bad), (err) => err instanceof ApiError && err.code === "invalid_response");
    }
  });

  it("sends POST /_api/ with empty fields, no-store cache, and form-urlencoded content-type", async () => {
    const calls = [];
    const origFetch = globalThis.fetch;
    globalThis.fetch = async (url, init) => {
      calls.push({ url, init });
      if (url === "/_api/bifrost") {
        return new Response(JSON.stringify({ result: [{ bifrost_ui_lang: "en", bifrost_ui_mode: "unknown" }] }));
      }
      return new Response(JSON.stringify({ result: '{"ok":true,"job":"update"}' }));
    };
    try {
      const ui = await readUiConfig();
      assert.deepEqual(ui, { lang: "en", mode: "dark" });

      const res = await postScript("bifrost_config.sh", ["core-check"]);
      assert.deepEqual(res, { ok: true, job: "update" });

      const post = calls[1];
      assert.equal(post.url, "/_api/");
      assert.equal(post.init.cache, "no-store");
      assert.equal(post.init.method, "POST");
      assert.equal(post.init.headers["Content-Type"], "application/x-www-form-urlencoded; charset=UTF-8");
      const body = JSON.parse(post.init.body);
      assert.deepEqual(body.fields, {});
      assert.equal(body.method, "bifrost_config.sh");
      assert.deepEqual(body.params, ["core-check"]);
      assert.ok(Number.isInteger(body.id) && body.id > 0);
    } finally {
      globalThis.fetch = origFetch;
    }
  });

  it("polls job until running becomes false and retries transient errors", async () => {
    let step = 0;
    const origFetch = globalThis.fetch;
    globalThis.fetch = async () => {
      step++;
      if (step === 1 || step === 2) {
        return new Response("temporary outage", { status: 503 });
      }
      const running = step < 4;
      return new Response(
        JSON.stringify({
          schema: 1,
          job: "update",
          running,
          phase: running ? "download" : "done",
          progress: running ? 50 : 100,
          ok: running ? null : true,
          code: null,
          started: 1,
          finished: running ? null : 2,
          pid: 10,
          data: {},
        }),
      );
    };
    try {
      const seen = [];
      const finalState = await pollJob("update", {
        intervalMs: 5,
        notifyAfterErrors: 4,
        onUpdate: (s) => seen.push(s.phase),
      });
      assert.deepEqual(seen, ["download", "done"]);
      assert.equal(finalState.running, false);
      assert.equal(finalState.ok, true);
    } finally {
      globalThis.fetch = origFetch;
    }
  });

  it("continues at a slower interval beyond the fast poll budget and reports a single outage once", async (ctx) => {
    const delays = [];
    const notices = [];
    const nativeTimeout = globalThis.setTimeout;
    ctx.mock.method(globalThis, "setTimeout", (fn, delay, ...args) => {
      delays.push(delay);
      return nativeTimeout(fn, 0, ...args);
    });
    let reads = 0;
    ctx.mock.method(globalThis, "fetch", async () => {
      reads++;
      if (reads > 1 && reads < 7) return new Response("", { status: 503 });
      return Response.json({ job: "update", running: reads === 1, phase: reads === 1 ? "queued" : "done", data: {} });
    });
    const final = await pollJob("update", {
      fastPolls: 2, intervalMs: 5, slowIntervalMs: 50, notifyAfterErrors: 2,
      onUnavailable: (err) => notices.push(err.httpStatus),
    });
    assert.deepEqual(delays, [5, 50, 50, 50, 50, 50]);
    assert.deepEqual(notices, [503]);
    assert.equal(final.running, false);
  });

  it("rejects malformed job files and bounds a stalled read", async (ctx) => {
    ctx.mock.method(globalThis, "fetch", async () => new Response("null"));
    await assert.rejects(readJob("update"), { code: "invalid_response" });
    ctx.mock.method(AbortSignal, "timeout", () => AbortSignal.abort(new DOMException("Timed out", "TimeoutError")));
    globalThis.fetch = async (_url, init) => { init.signal.throwIfAborted(); };
    await assert.rejects(readJob("update"), { code: "timeout" });
  });

  it("continues through read errors without a notification handler until cancelled", async (ctx) => {
    const ctrl = new AbortController();
    let reads = 0;
    ctx.mock.method(globalThis, "fetch", async () => {
      if (++reads === 4) ctrl.abort();
      return new Response("", { status: 503 });
    });
    await assert.rejects(pollJob("update", { signal: ctrl.signal, intervalMs: 1, notifyAfterErrors: 2 }),
      { name: "AbortError" });
    assert.equal(reads, 4);
  });
});

describe("format.ts state mapping and formatting", () => {
  const baseStatus = {
    schema: 1,
    time: 1795430000,
    state: "running",
    error: null,
    plugin: { version: "0.1.0", enabled: true },
    core: {
      tailscale: "1.104.7",
      revision: 1,
      serial: 7,
      arch: "arm",
      kernel_arch: "aarch64",
      size: 25100448,
      installed: 1795000000,
      prev: true,
      update: null,
      build: { go: "1.27.4", commit: "cbc74fe48ef1", omit: ["ts_omit_aws"] },
    },
    daemon: { running: true, pid: 1234, restarts: 0 },
    conflict: { original_installed: false, original_running: false },
    self: null,
    prefs: null,
    routes: [],
    exit_node: { advertised: false, approved: false },
    settings: {
      port: 41641,
      local_access: true,
      lan_masq: true,
      snat: "auto",
      snat_effective: false,
      magicdns: false,
      no_logs: true,
      no_logs_forced: false,
      mirror: "",
    },
    lan: { ip: "192.168.1.1", cidr: "192.168.1.0/24", sw_mode: 1 },
    dns: { conf_dir: true, active: false },
    auth_url: "",
    health: [],
    checks: [],
    peers: [],
  };

  it("maps every PageState to expected primary action, disable/auth flags, and view flags", () => {
    const disabled = describeState({ ...baseStatus, state: "disabled" });
    assert.equal(disabled.primaryAction, "enable");

    const conflict = describeState({ ...baseStatus, state: "conflict" });
    assert.equal(conflict.primaryAction, "migrate");
    assert.equal(conflict.showMigrateCard, true);

    const missing = describeState({ ...baseStatus, state: "core_missing" });
    assert.equal(missing.primaryAction, "goto_core");

    const starting = describeState({ ...baseStatus, state: "starting" });
    assert.equal(starting.primaryAction, "disable");

    const needsLogin = describeState({ ...baseStatus, state: "needs_login" });
    assert.equal(needsLogin.primaryAction, "disable");
    assert.equal(needsLogin.showLoginView, true);

    const needsApproval = describeState({ ...baseStatus, state: "needs_approval" });
    assert.equal(needsApproval.badgeVariant, "warning");
    assert.equal(needsApproval.primaryAction, "disable");

    const stopped = describeState({ ...baseStatus, state: "stopped" });
    assert.equal(stopped.primaryAction, "connect");
    assert.equal(stopped.secondaryAction, "disable");

    const running = describeState({ ...baseStatus, state: "running" });
    assert.equal(running.showOverviewDetails, true);
    assert.equal(running.showAuthActions, true);
    assert.equal(running.primaryAction, "disable");

    const err = describeState({ ...baseStatus, state: "error" });
    assert.equal(err.badgeVariant, "error");
    assert.equal(err.primaryAction, "enable");

    assert.equal(
      describeState({
        ...baseStatus,
        state: "disabled",
        conflict: { original_installed: true, original_running: false },
      }).showMigrateCard,
      true,
    );
  });

  it("analyzes key expiry and formats sizes/dates/ages via dictionary", () => {
    const now = Date.parse("2026-11-23T00:00:00Z");
    assert.equal(analyzeKeyExpiry("2026-12-01T00:00:00Z", now)?.expiringSoon, true);
    assert.equal(analyzeKeyExpiry("2027-05-01T00:00:00Z", now)?.expiringSoon, false);
    assert.equal(analyzeKeyExpiry("2026-11-20T00:00:00Z", now)?.expired, true);

    assert.equal(formatBytes(512), "512 B");
    assert.equal(formatBytes(2048), "2.0 KB");
    // Decimal units, as in docs/PLAN.md.
    assert.equal(formatBytes(25_100_448), "25.1 MB");
    assert.equal(formatBytes(999_600), "1.0 MB");
    assert.equal(formatDateTime(0), "—");
    assert.match(formatDateTime(1795000000), /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/);

    const tZh = (k, vars) => t("zh-CN", k, vars);
    const tEn = (k, vars) => t("en", k, vars);
    const nowSec = 500_000;
    assert.equal(formatHandshakeAge(0, nowSec, tZh), "无");
    assert.equal(formatHandshakeAge(nowSec - 10, nowSec, tEn), "10s ago");
    assert.equal(formatHandshakeAge(0, nowSec, tEn), "Never");
    assert.equal(formatHandshakeAge(nowSec - 180, nowSec, tZh), "3 分钟前");
    assert.equal(formatHandshakeAge(nowSec - 7200, nowSec, tEn), "2h ago");
    assert.equal(formatHandshakeAge(nowSec - 172800, nowSec, tZh), "2 天前");
  });
});
