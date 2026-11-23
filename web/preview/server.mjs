// Adapted from po0fw asus-merlin (MIT), commit 0d9532d.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import {
  SAMPLE_DIAG,
  SAMPLE_LATEST_CORE,
  SAMPLE_LOGS_TEXT,
  SAMPLE_NETCHECK_REPORT,
  SAMPLE_NOW,
  createStatusFixture,
} from "../test/fixtures/index.mjs";
import {
  validArch,
  validAuthKey,
  validBool01,
  validCidr4List,
  validHostname,
  validLang,
  validLoginServer,
  validMirror,
  validMode,
  validName,
  validParam,
  validPort,
  validSnat,
  validTailnetIp,
} from "../src/core/validate.ts";

const pluginDir = new URL("../../plugin/bifrost/", import.meta.url);
const staticFiles = new Map([
  ["/res/icon-bifrost.png", ["image/png", new URL("res/icon-bifrost.png", pluginDir)]],
  ["/index_style.css", ["text/css", new URL("./shell.css", import.meta.url)]],
  ["/state.js", ["text/javascript", new URL("./shell.js", import.meta.url)]],
]);
const emptyAssets = new Map([
  ...["/js/jquery.js", "/help.js", "/general.js", "/popup.js", "/res/softcenter.js"].map((p) => [
    p,
    "text/javascript",
  ]),
  ...["/form_style.css", "/css/element.css", "/res/softcenter.css"].map((p) => [p, "text/css"]),
  ["/images/favicon.png", "image/png"],
]);

function undash(v) {
  return v === "-" ? "" : v;
}

// Mirror common.sh respond(): reject response text containing & + % = (PLAN 2.4 item 14).
export function sanitizeScriptResponse(payload) {
  const encoded = JSON.stringify(payload);
  if (/[&+%=]/.test(encoded)) {
    return '{"ok":false,"code":"internal"}';
  }
  return encoded;
}

export function createPreviewServer({
  initialState = process.env.BIFROST_STATE || "running",
  lang,
  mode,
  pageFile = new URL("../dist/Module_bifrost.asp", import.meta.url),
  resources = new URL("../dist/res/", import.meta.url),
  jobStepMs = 60,
  mutateStatus,
  initialJobs,
  migrateMode = "ok",
  loginExpires = false,
  loginStayWaiting = false,
  onSetReadBack,
} = {}) {
  const dbus = {};
  if (lang !== undefined) dbus.bifrost_ui_lang = lang;
  if (mode !== undefined) dbus.bifrost_ui_mode = mode;

  const status = createStatusFixture(initialState);
  if (mutateStatus) mutateStatus(status);

  const diag = {
    ...SAMPLE_DIAG,
    fw_complete: status.daemon.running ? true : null,
    conflict: status.conflict.original_running,
  };
  const logsText = SAMPLE_LOGS_TEXT;
  const jobs = new Map(Object.entries(structuredClone(initialJobs ?? {})));
  const jobTimers = new Map();

  function clearJobTimer(jobName) {
    const t = jobTimers.get(jobName);
    if (t) {
      clearTimeout(t);
      jobTimers.delete(jobName);
    }
  }

  function runJobSteps(jobName, state, steps, onFinish) {
    let idx = 0;
    const advance = () => {
      jobTimers.delete(jobName);
      if (idx < steps.length) {
        const step = steps[idx++];
        state.phase = step.phase;
        state.progress = step.progress ?? null;
        if (step.data) Object.assign(state.data, step.data);
        if (step.effect) step.effect();
        if (step.waitForever) return;
        jobTimers.set(jobName, setTimeout(advance, jobStepMs));
        return;
      }
      const outcome = onFinish(state);
      state.running = false;
      state.finished = SAMPLE_NOW + 5;
      if (outcome.ok) {
        state.ok = true;
        state.code = null;
        state.phase = "done";
        state.progress = 100;
      } else {
        state.ok = false;
        state.code = outcome.code ?? "internal";
      }
    };

    jobTimers.set(jobName, setTimeout(advance, jobStepMs));
  }

  function scheduleJob(jobName, initialData, steps, onFinish) {
    const existing = jobs.get(jobName);
    if (existing?.running) return false;
    const state = {
      schema: 1,
      job: jobName,
      running: true,
      phase: "queued",
      progress: 0,
      ok: null,
      code: null,
      started: SAMPLE_NOW,
      finished: null,
      pid: 4321,
      data: { ...initialData },
    };
    jobs.set(jobName, state);
    runJobSteps(jobName, state, steps, onFinish);
    return true;
  }

  function cancelWaitingLogin() {
    const login = jobs.get("login");
    if (login?.running) {
      clearJobTimer("login");
      login.running = false;
      login.ok = false;
      login.code = "cli_failed";
      login.finished = SAMPLE_NOW + 3;
    }
  }

  function handleAction(action, args) {
    if (!validName(action)) return { ok: false, code: "invalid_param" };
    for (const p of args) {
      if (!validParam(p)) return { ok: false, code: "invalid_param" };
    }

    switch (action) {
      case "ui": {
        if (args.length !== 2) return { ok: false, code: "invalid_param" };
        const [nextLang, nextMode] = args;
        if (!validLang(nextLang) || !validMode(nextMode)) return { ok: false, code: "invalid_param" };
        dbus.bifrost_ui_lang = nextLang;
        dbus.bifrost_ui_mode = nextMode;
        return { ok: true };
      }

      case "enable": {
        if (args.length !== 0) return { ok: false, code: "invalid_param" };
        if (status.conflict.original_running) return { ok: false, code: "conflict" };
        const ok = scheduleJob(
          "daemon",
          { action: "start" },
          [
            { phase: "precheck", progress: 20 },
            { phase: "starting", progress: 45 },
            { phase: "waiting", progress: 70 },
            { phase: "firewall", progress: 90 },
          ],
          () => {
            status.plugin.enabled = true;
            status.daemon = { running: true, pid: 1235, restarts: 0 };
            status.state = "running";
            status.error = null;
            status.checks = [];
            status.health = [];
            if (!status.self) {
              const running = createStatusFixture("running");
              status.self = running.self;
              status.prefs = running.prefs;
              status.routes = running.routes;
              status.peers = running.peers;
            }
            return { ok: true };
          },
        );
        return ok ? { ok: true, job: "daemon" } : { ok: false, code: "busy" };
      }

      case "disable": {
        if (args.length !== 0) return { ok: false, code: "invalid_param" };
        const ok = scheduleJob(
          "daemon",
          { action: "stop" },
          [
            {
              phase: "stopping",
              progress: 40,
              effect: () => {
                cancelWaitingLogin();
              },
            },
            { phase: "cleanup", progress: 80 },
          ],
          () => {
            status.plugin.enabled = false;
            status.daemon = { running: false, pid: null, restarts: 0 };
            status.state = "disabled";
            status.auth_url = "";
            status.self = null;
            status.prefs = null;
            status.routes = [];
            status.peers = [];
            return { ok: true };
          },
        );
        return ok ? { ok: true, job: "daemon" } : { ok: false, code: "busy" };
      }

      case "connect": {
        if (args.length !== 0) return { ok: false, code: "invalid_param" };
        if (!status.daemon.running) return { ok: false, code: "not_running" };
        status.state = "running";
        if (status.self) status.self.online = true;
        return { ok: true };
      }

      case "logout": {
        if (args.length !== 0) return { ok: false, code: "invalid_param" };
        if (!status.daemon.running) return { ok: false, code: "not_running" };
        status.state = "needs_login";
        status.auth_url = "";
        status.peers = [];
        status.routes = [];
        if (status.self) {
          status.self.ips = [];
          status.self.online = false;
        }
        return { ok: true };
      }

      case "purge": {
        if (args.length !== 0) return { ok: false, code: "invalid_param" };
        const ok = scheduleJob(
          "daemon",
          { action: "purge" },
          [
            {
              phase: "stopping",
              progress: 35,
              effect: () => {
                cancelWaitingLogin();
              },
            },
            { phase: "purge", progress: 75 },
          ],
          () => {
            status.plugin.enabled = false;
            status.daemon = { running: false, pid: null, restarts: 0 };
            status.state = "disabled";
            status.auth_url = "";
            status.self = null;
            status.prefs = null;
            status.routes = [];
            status.peers = [];
            return { ok: true };
          },
        );
        return ok ? { ok: true, job: "daemon" } : { ok: false, code: "busy" };
      }

      case "login": {
        if (args.length !== 2) return { ok: false, code: "invalid_param" };
        const server = undash(args[0]);
        const authKey = undash(args[1]);
        if (server && !validLoginServer(server)) return { ok: false, code: "bad_server" };
        if (authKey && !validAuthKey(authKey)) return { ok: false, code: "bad_authkey" };
        const official = server === "";
        const ok = scheduleJob(
          "login",
          { action: "login", official },
          [
            {
              phase: "running",
              progress: 50,
              waitForever: loginStayWaiting && !authKey,
              effect: () => {
                if (!authKey) {
                  status.state = "needs_login";
                  status.auth_url = official
                    ? "https://example.org/a/interactive-demo"
                    : `${server.replace(/\/$/, "")}/register/demo-id`;
                  if (status.self) {
                    status.self.official = official;
                    status.self.control = server;
                  }
                }
              },
            },
          ],
          () => {
            if (loginExpires && !authKey) {
              status.auth_url = "";
              return { ok: false, code: "login_expired" };
            }
            if (authKey) {
              const running = createStatusFixture("running");
              status.state = "running";
              status.auth_url = "";
              status.self = {
                ...running.self,
                official,
                control: server,
              };
              status.settings.no_logs_forced = !official;
              if (!official) status.settings.no_logs = true;
              status.prefs = running.prefs;
              status.routes = running.routes;
              status.peers = running.peers;
            }
            return { ok: true };
          },
        );
        return ok ? { ok: true, job: "login" } : { ok: false, code: "busy" };
      }

      case "relogin": {
        if (args.length !== 0) return { ok: false, code: "invalid_param" };
        if (!status.daemon.running) return { ok: false, code: "not_running" };
        const ok = scheduleJob(
          "login",
          { action: "relogin", official: status.self?.official ?? true },
          [
            {
              phase: "running",
              progress: 50,
              effect: () => {
                status.state = "needs_login";
                status.auth_url = "https://example.org/a/relogin-demo";
              },
            },
          ],
          () => ({ ok: true }),
        );
        return ok ? { ok: true, job: "login" } : { ok: false, code: "busy" };
      }

      case "set": {
        if (args.length !== 2) return { ok: false, code: "invalid_param" };
        const key = args[0];
        const value = undash(args[1]);
        const prefsKeys = new Set(["advertise_routes", "advertise_exit_node", "accept_routes", "hostname"]);
        if (prefsKeys.has(key) && (!status.daemon.running || !status.prefs)) {
          return { ok: false, code: "not_running" };
        }
        const readBack = (k, v) => (onSetReadBack ? onSetReadBack(k, v) : v);
        switch (key) {
          case "advertise_routes": {
            if (value !== "" && !validCidr4List(value)) return { ok: false, code: "invalid_param" };
            const list = readBack(key, value ? value.split(",") : []);
            status.prefs.advertise_routes = list;
            status.routes = list.map((cidr) => ({
              cidr,
              approved: cidr === status.lan.cidr,
            }));
            return { ok: true, value: list };
          }
          case "advertise_exit_node": {
            if (!validBool01(value)) return { ok: false, code: "invalid_param" };
            const b = readBack(key, value === "1");
            status.prefs.advertise_exit_node = b;
            status.exit_node = { advertised: b, approved: false };
            return { ok: true, value: b };
          }
          case "accept_routes": {
            if (!validBool01(value)) return { ok: false, code: "invalid_param" };
            const b = readBack(key, value === "1");
            status.prefs.accept_routes = b;
            return { ok: true, value: b };
          }
          case "hostname": {
            if (value !== "" && !validHostname(value)) return { ok: false, code: "invalid_param" };
            const finalVal = readBack(key, value);
            status.prefs.hostname = finalVal;
            if (status.self) status.self.hostname = finalVal || "router";
            return { ok: true, value: finalVal };
          }
          case "local_access": {
            if (!validBool01(value)) return { ok: false, code: "invalid_param" };
            const b = readBack(key, value === "1");
            status.settings.local_access = b;
            return { ok: true, value: b };
          }
          case "lan_masq": {
            if (!validBool01(value)) return { ok: false, code: "invalid_param" };
            const b = readBack(key, value === "1");
            status.settings.lan_masq = b;
            return { ok: true, value: b };
          }
          case "snat": {
            if (!validSnat(value)) return { ok: false, code: "invalid_param" };
            const finalVal = readBack(key, value);
            status.settings.snat = finalVal;
            status.settings.snat_effective =
              finalVal === "on" || (finalVal === "auto" && status.lan.sw_mode !== 1);
            return { ok: true, value: finalVal };
          }
          case "magicdns": {
            if (!validBool01(value)) return { ok: false, code: "invalid_param" };
            if (value === "1" && !status.dns.conf_dir) return { ok: false, code: "no_conf_dir" };
            const b = readBack(key, value === "1");
            status.settings.magicdns = b;
            status.dns.active = b && status.daemon.running;
            return { ok: true, value: b };
          }
          case "mirror": {
            if (value !== "" && !validMirror(value)) return { ok: false, code: "invalid_param" };
            const finalVal = readBack(key, value);
            status.settings.mirror = finalVal;
            return { ok: true, value: finalVal };
          }
          case "port": {
            if (!validPort(value)) return { ok: false, code: "invalid_param" };
            const nextPort = Number(readBack(key, Number(value)));
            const ok = scheduleJob(
              "daemon",
              { action: "restart" },
              [
                { phase: "stopping", progress: 35 },
                { phase: "starting", progress: 70 },
                { phase: "firewall", progress: 90 },
              ],
              () => {
                status.settings.port = nextPort;
                return { ok: true };
              },
            );
            return ok ? { ok: true, job: "daemon" } : { ok: false, code: "busy" };
          }
          case "no_logs": {
            if (!validBool01(value)) return { ok: false, code: "invalid_param" };
            const nextVal = readBack(key, value === "1");
            const ok = scheduleJob(
              "daemon",
              { action: "restart" },
              [
                { phase: "stopping", progress: 40 },
                { phase: "starting", progress: 80 },
              ],
              () => {
                status.settings.no_logs = status.settings.no_logs_forced ? true : nextVal;
                return { ok: true };
              },
            );
            return ok ? { ok: true, job: "daemon" } : { ok: false, code: "busy" };
          }
          default:
            return { ok: false, code: "invalid_param" };
        }
      }

      case "migrate": {
        if (args.length !== 0) return { ok: false, code: "invalid_param" };
        if (migrateMode === "rollback") {
          const ok = scheduleJob(
            "migrate",
            { manual_stop: false, rolled_back: false },
            [
              { phase: "precheck", progress: 15 },
              { phase: "record", progress: 30 },
              { phase: "copy", progress: 55 },
              { phase: "verify", progress: 75 },
              { phase: "rollback", progress: 90, data: { rolled_back: true } },
            ],
            () => ({ ok: false, code: "migrate_verify_failed" }),
          );
          return ok ? { ok: true, job: "migrate" } : { ok: false, code: "busy" };
        }
        const ok = scheduleJob(
          "migrate",
          { manual_stop: migrateMode === "manual_stop", rolled_back: false },
          [
            { phase: "precheck", progress: 15 },
            { phase: "record", progress: 30 },
            {
              phase: migrateMode === "manual_stop" ? "wait_original" : "stop_original",
              progress: 45,
              data: { manual_stop: migrateMode === "manual_stop" },
            },
            { phase: "copy", progress: 65, data: { manual_stop: false } },
            { phase: "starting", progress: 80 },
            { phase: "verify", progress: 95 },
          ],
          () => {
            const running = createStatusFixture("running");
            Object.assign(status, running, {
              conflict: { original_installed: true, original_running: false },
            });
            return { ok: true };
          },
        );
        return ok ? { ok: true, job: "migrate" } : { ok: false, code: "busy" };
      }

      case "core-check": {
        if (args.length !== 0) return { ok: false, code: "invalid_param" };
        const ok = scheduleJob(
          "update",
          { action: "check", latest: null, up_to_date: false, kept_prev: status.core.prev },
          [
            { phase: "manifest", progress: 40 },
            { phase: "verify_manifest", progress: 80 },
          ],
          (st) => {
            if (status.core.serial > SAMPLE_LATEST_CORE.serial) {
              status.core.update = null;
              st.data.latest = null;
              st.data.up_to_date = false;
              return { ok: false, code: "old_serial" };
            }
            if (status.core.serial === SAMPLE_LATEST_CORE.serial) {
              status.core.update = null;
              st.data.latest = { ...SAMPLE_LATEST_CORE };
              st.data.up_to_date = true;
              return { ok: true };
            }
            status.core.update = { ...SAMPLE_LATEST_CORE };
            st.data.latest = { ...SAMPLE_LATEST_CORE };
            st.data.up_to_date = false;
            return { ok: true };
          },
        );
        return ok ? { ok: true, job: "update" } : { ok: false, code: "busy" };
      }

      case "core-update": {
        if (args.length !== 0) return { ok: false, code: "invalid_param" };
        const ok = scheduleJob(
          "update",
          { action: "update", latest: SAMPLE_LATEST_CORE, up_to_date: false, kept_prev: true },
          [
            { phase: "manifest", progress: 15 },
            { phase: "verify_manifest", progress: 30 },
            { phase: "download", progress: 55 },
            { phase: "unpack", progress: 70 },
            { phase: "test", progress: 80 },
            { phase: "swap", progress: 90 },
            { phase: "verify_running", progress: 95 },
          ],
          () => {
            status.core.tailscale = SAMPLE_LATEST_CORE.tailscale;
            status.core.revision = SAMPLE_LATEST_CORE.revision;
            status.core.serial = SAMPLE_LATEST_CORE.serial;
            status.core.installed = SAMPLE_NOW;
            status.core.prev = true;
            status.core.update = null;
            return { ok: true };
          },
        );
        return ok ? { ok: true, job: "update" } : { ok: false, code: "busy" };
      }

      case "core-rollback": {
        if (args.length !== 0) return { ok: false, code: "invalid_param" };
        if (!status.core.prev) return { ok: false, code: "no_prev" };
        const ok = scheduleJob(
          "update",
          { action: "rollback", latest: null, up_to_date: false, kept_prev: false },
          [
            { phase: "unpack", progress: 40 },
            { phase: "swap", progress: 75 },
            { phase: "verify_running", progress: 90 },
          ],
          () => {
            status.core.tailscale = "1.104.7";
            status.core.revision = 1;
            status.core.serial = 7;
            status.core.prev = false;
            return { ok: true };
          },
        );
        return ok ? { ok: true, job: "update" } : { ok: false, code: "busy" };
      }

      case "core-arch": {
        if (args.length !== 1 || !validArch(args[0])) return { ok: false, code: "invalid_param" };
        const nextArch = args[0];
        if (nextArch === "arm64" && status.core.kernel_arch !== "aarch64") {
          return { ok: false, code: "arch_unsupported" };
        }
        const ok = scheduleJob(
          "update",
          { action: "arch", latest: null, up_to_date: false, kept_prev: true },
          [
            { phase: "download", progress: 40 },
            { phase: "swap", progress: 80 },
          ],
          () => {
            status.core.arch = nextArch;
            status.core.size = nextArch === "arm64" ? 24_576_160 : 25_100_448;
            return { ok: true };
          },
        );
        return ok ? { ok: true, job: "update" } : { ok: false, code: "busy" };
      }

      case "netcheck": {
        if (args.length !== 0) return { ok: false, code: "invalid_param" };
        const ok = scheduleJob(
          "netcheck",
          {},
          [{ phase: "running", progress: 50 }],
          (st) => {
            st.data.report = structuredClone(SAMPLE_NETCHECK_REPORT);
            return { ok: true };
          },
        );
        return ok ? { ok: true, job: "netcheck" } : { ok: false, code: "busy" };
      }

      case "ping": {
        if (args.length !== 1 || !validTailnetIp(args[0])) return { ok: false, code: "invalid_param" };
        const peer = status.peers.find((p) => p.ip === args[0] || p.ips.includes(args[0]));
        if (!peer) return { ok: false, code: "unknown_peer" };
        return {
          ok: true,
          latency_ms: peer.path === "direct" ? 12 : peer.path === "peer-relay" ? 24 : 38,
          path: peer.path,
          relay: peer.relay,
        };
      }

      case "logs": {
        if (args.length !== 0) return { ok: false, code: "invalid_param" };
        diag.time = SAMPLE_NOW;
        diag.fw_complete = status.daemon.running ? true : null;
        diag.conflict = status.conflict.original_running;
        return { ok: true };
      }

      default:
        return { ok: false, code: "unknown_action" };
    }
  }

  const server = createServer(async (req, res) => {
    const parsed = new URL(req.url, "http://localhost");
    const path = parsed.pathname;
    const send = (type, content, code = 200, cache = "no-store") => {
      res.writeHead(code, { "Content-Type": type, "Cache-Control": cache });
      res.end(content);
    };

    try {
      // Router rejects any /res/ request with a query string.
      if (path.startsWith("/res/") && req.url.includes("?")) {
        return send("text/plain", "Not found", 404);
      }

      if (req.method === "POST" && path === "/_api/") {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const body = JSON.parse(Buffer.concat(chunks).toString());
        const { id, method, params, fields } = body;
        if (!Number.isInteger(id) || id < 0) return send("text/plain", "Invalid id", 400);
        if (fields && Object.keys(fields).length > 0) {
          return send(
            "application/json",
            JSON.stringify({ id, result: sanitizeScriptResponse({ ok: false, code: "invalid_param" }) }),
          );
        }
        if (method === "bifrost_status.sh") {
          status.time = SAMPLE_NOW;
          return send(
            "application/json",
            JSON.stringify({ id, result: sanitizeScriptResponse({ ok: true }) }),
          );
        }
        if (method !== "bifrost_config.sh" || !Array.isArray(params) || typeof params[0] !== "string") {
          return send(
            "application/json",
            JSON.stringify({ id, result: sanitizeScriptResponse({ ok: false, code: "invalid_param" }) }),
          );
        }
        const [action, ...rest] = params;
        const payload = rest.every((value) => typeof value === "string")
          ? handleAction(action, rest)
          : { ok: false, code: "invalid_param" };
        return send(
          "application/json",
          JSON.stringify({ id, result: sanitizeScriptResponse(payload) }),
        );
      }

      if (req.method !== "GET") return send("text/plain", "Method not allowed", 405);

      if (path === "/_api/bifrost") {
        return send("application/json", JSON.stringify({ result: [{ ...dbus }] }));
      }

      if (path === "/_temp/bifrost_status.json") {
        return send("application/json", JSON.stringify(status));
      }
      if (path === "/_temp/bifrost_diag.json") {
        return send("application/json", JSON.stringify(diag));
      }
      if (path === "/_temp/bifrost_logs.txt") {
        return send("text/plain; charset=utf-8", logsText);
      }
      const jobMatch = /^\/_temp\/bifrost_(daemon|login|migrate|update|netcheck)\.json$/.exec(path);
      if (jobMatch) {
        const jobState = jobs.get(jobMatch[1]);
        if (!jobState) return send("text/plain", "Not found", 404);
        return send("application/json", JSON.stringify(jobState));
      }

      if (path === "/Module_Softcenter.asp") {
        return send("text/plain; charset=utf-8", "软件中心");
      }

      if (emptyAssets.has(path)) {
        return send(emptyAssets.get(path), "", 204);
      }

      const bundle = /^\/res\/(bifrost-app\.[0-9a-f]{20}\.(js|css))$/.exec(path);
      if (bundle) {
        const type = bundle[2] === "js" ? "text/javascript; charset=utf-8" : "text/css; charset=utf-8";
        return send(type, await readFile(new URL(bundle[1], resources)), 200, "public, max-age=31536000, immutable");
      }

      if (path === "/" || path === "/Module_bifrost.asp") {
        const html = (await readFile(pageFile, "utf8")).replace('<% nvram_get("sc_skin"); %>', "ASUSWRT");
        return send("text/html; charset=utf-8", html);
      }

      if (staticFiles.has(path)) {
        const [type, file] = staticFiles.get(path);
        return send(type, await readFile(file));
      }

      return send("text/plain", "Not found", 404);
    } catch (error) {
      const statusCode = error?.code === "ENOENT" ? 404 : 400;
      return send(
        "text/plain",
        error?.code === "ENOENT" ? "Run npm run build first" : "Invalid request",
        statusCode,
      );
    }
  });

  server.on("close", () => {
    for (const timer of jobTimers.values()) clearTimeout(timer);
    jobTimers.clear();
  });

  return server;
}

if (import.meta.main) {
  const server = createPreviewServer();
  server.listen(Number(process.env.PORT ?? 4173), "127.0.0.1", () => {
    console.log(`http://127.0.0.1:${server.address().port}/Module_bifrost.asp`);
  });
}
