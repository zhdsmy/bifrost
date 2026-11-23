import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  ApiError,
  dash,
  parseActionPayload,
  pollJob,
  postScript,
  readUiConfig,
} from "../src/core/api.ts";
import {
  analyzeKeyExpiry,
  describeState,
  formatBytes,
  formatHandshakeAge,
} from "../src/core/format.ts";
import {
  cidr4Overlaps,
  findOverlappingPeerRoutes,
  isAccessingFromTailnet,
  isHttpLoginServer,
  validAuthKey,
  validCidr4,
  validCidr4List,
  validHostname,
  validIpv4,
  validLoginServer,
  validMirror,
  validPort,
  validTailnetIp,
  validUint,
} from "../src/core/validate.ts";
import {
  t,
  translateCheck,
  translateError,
  translatePhase,
  translateState,
} from "../src/i18n/index.ts";
import { en } from "../src/i18n/en.ts";
import { zhCN } from "../src/i18n/zh-CN.ts";

describe("validate.ts parity with plugin/bifrost/lib/validate.sh", () => {
  it("validates unsigned ints and ports", () => {
    assert.equal(validUint("0"), true);
    assert.equal(validUint("41641"), true);
    assert.equal(validUint("01"), false);
    assert.equal(validUint("-1"), false);
    assert.equal(validUint(""), false);

    assert.equal(validPort("1024"), true);
    assert.equal(validPort("41641"), true);
    assert.equal(validPort("65535"), true);
    assert.equal(validPort("1023"), false);
    assert.equal(validPort("65536"), false);
    assert.equal(validPort("041641"), false);
  });

  it("validates IPv4, canonical CIDRs, and CIDR lists", () => {
    assert.equal(validIpv4("192.168.1.1"), true);
    assert.equal(validIpv4("256.0.0.1"), false);
    assert.equal(validIpv4("192.168.01.1"), false);

    assert.equal(validCidr4("192.168.1.0/24"), true);
    assert.equal(validCidr4("10.0.0.0/8"), true);
    assert.equal(validCidr4("192.0.2.1/32"), true);
    assert.equal(validCidr4("0.0.0.0/0"), false);
    assert.equal(validCidr4("192.168.1.1/24"), false);
    assert.equal(validCidr4("192.168.1.0/33"), false);

    assert.equal(validCidr4List("192.168.1.0/24,198.51.100.0/24"), true);
    assert.equal(validCidr4List("192.168.1.0/24,192.168.1.0/24"), false);
    assert.equal(validCidr4List(""), false);
    const seventeen = Array.from({ length: 17 }, (_, i) => `10.0.${i}.0/24`).join(",");
    assert.equal(validCidr4List(seventeen), false);
    const sixteen = Array.from({ length: 16 }, (_, i) => `10.0.${i}.0/24`).join(",");
    assert.equal(validCidr4List(sixteen), true);
  });

  it("validates hostnames, login servers, auth keys, mirrors, and tailnet IPs", () => {
    assert.equal(validHostname("router"), true);
    assert.equal(validHostname("home-router-01"), true);
    assert.equal(validHostname("-router"), false);
    assert.equal(validHostname("router-"), false);
    assert.equal(validHostname("a".repeat(64)), false);

    assert.equal(validLoginServer("https://hs.example.org"), true);
    assert.equal(validLoginServer("http://192.0.2.10:8080/ts"), true);
    assert.equal(validLoginServer("ftp://hs.example.org"), false);
    assert.equal(validLoginServer("https://hs.example.org?q=1"), false);
    assert.equal(validLoginServer("https://user@hs.example.org"), false);
    assert.equal(validLoginServer("https://hs.example.org:99999"), false);
    assert.equal(isHttpLoginServer("http://192.0.2.10:8080"), true);
    assert.equal(isHttpLoginServer("https://hs.example.org"), false);

    assert.equal(validAuthKey("bifrost_test_key_0001"), true);
    assert.equal(validAuthKey("short_key"), false);
    assert.equal(validAuthKey("bad key with space 123456"), false);

    assert.equal(validMirror("https://mirror.example.org/"), true);
    assert.equal(validMirror("https://mirror.example.org/sub/"), true);
    assert.equal(validMirror("https://mirror.example.org"), false);
    assert.equal(validMirror("http://mirror.example.org/"), false);
    assert.equal(validMirror("https:///"), false);

    assert.equal(validTailnetIp("100.64.0.1"), true);
    assert.equal(validTailnetIp("100.127.255.254"), true);
    assert.equal(validTailnetIp("100.63.0.1"), false);
    assert.equal(validTailnetIp("100.128.0.1"), false);
    assert.equal(validTailnetIp("fd7a:115c:a1e0::1"), true);
    assert.equal(validTailnetIp("192.168.1.1"), false);
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

describe("i18n dictionaries and translators", () => {
  it("keeps zh-CN and en keys strictly aligned", () => {
    assert.deepEqual(Object.keys(en).sort(), Object.keys(zhCN).sort());
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

describe("api.ts envelope parsing and request contract", () => {
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

  it("polls job until running becomes false", async () => {
    let step = 0;
    const origFetch = globalThis.fetch;
    globalThis.fetch = async () => {
      step++;
      const running = step < 3;
      return new Response(
        JSON.stringify({
          schema: 1,
          job: "update",
          running,
          phase: running ? "download" : "done",
          progress: running ? step * 30 : 100,
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
        onUpdate: (s) => seen.push(s.phase),
      });
      assert.deepEqual(seen, ["download", "download", "done"]);
      assert.equal(finalState.running, false);
      assert.equal(finalState.ok, true);
    } finally {
      globalThis.fetch = origFetch;
    }
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
      tailscale: "1.104.7", revision: 1, serial: 7, arch: "arm",
      kernel_arch: "aarch64", size: 25100448, installed: 1795000000, prev: true, update: null,
    },
    daemon: { running: true, pid: 1234, restarts: 0 },
    conflict: { original_installed: false, original_running: false },
    self: null,
    prefs: null,
    routes: [],
    exit_node: { advertised: false, approved: false },
    settings: {
      port: 41641, local_access: true, lan_masq: true, snat: "auto",
      snat_effective: false, magicdns: false, no_logs: true, no_logs_forced: false, mirror: "",
    },
    lan: { ip: "192.168.1.1", cidr: "192.168.1.0/24", sw_mode: 1 },
    dns: { conf_dir: true, active: false },
    auth_url: "",
    health: [],
    checks: [],
    peers: [],
  };

  it("maps every PageState to expected primary action and view flags", () => {
    assert.equal(describeState({ ...baseStatus, state: "disabled" }).primaryAction, "enable");
    assert.equal(describeState({ ...baseStatus, state: "conflict" }).primaryAction, "migrate");
    assert.equal(describeState({ ...baseStatus, state: "core_missing" }).primaryAction, "goto_core");
    assert.equal(describeState({ ...baseStatus, state: "starting" }).primaryAction, "disable");
    assert.equal(describeState({ ...baseStatus, state: "needs_login" }).showLoginView, true);
    assert.equal(describeState({ ...baseStatus, state: "needs_approval" }).badgeVariant, "warning");
    assert.equal(describeState({ ...baseStatus, state: "stopped" }).primaryAction, "connect");
    assert.equal(describeState({ ...baseStatus, state: "running" }).showOverviewDetails, true);
    assert.equal(describeState({ ...baseStatus, state: "error" }).badgeVariant, "error");
    assert.equal(
      describeState({ ...baseStatus, state: "disabled", conflict: { original_installed: true, original_running: false } }).showMigrateCard,
      true,
    );
  });

  it("analyzes key expiry and formats sizes/ages", () => {
    const now = Date.parse("2026-11-23T00:00:00Z");
    assert.equal(analyzeKeyExpiry("2026-12-01T00:00:00Z", now)?.expiringSoon, true);
    assert.equal(analyzeKeyExpiry("2027-05-01T00:00:00Z", now)?.expiringSoon, false);
    assert.equal(analyzeKeyExpiry("2026-11-20T00:00:00Z", now)?.expired, true);

    assert.equal(formatBytes(512), "512 B");
    assert.equal(formatBytes(2048), "2.0 KB");
    assert.equal(formatHandshakeAge(0, 100, "zh-CN"), "无");
    assert.equal(formatHandshakeAge(90, 100, "en"), "10s ago");
  });
});
