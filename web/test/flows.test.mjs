import assert from "node:assert/strict";
import { test } from "node:test";
import { choose, clickTab, openPreview, ready } from "./fixture.mjs";
import { SAMPLE_LOGS_TEXT, SAMPLE_NETCHECK_REPORT, SAMPLE_NOW } from "./fixtures/index.mjs";

const PASTE_SHORTCUT = process.platform === "darwin" ? "Meta+v" : "Control+v";

async function withStatusReadHeld(page, verify) {
  const release = Promise.withResolvers();
  const path = "**/_temp/bifrost_status.json";
  await page.route(path, async (route) => {
    await release.promise;
    await route.continue();
  }, { times: 1 });
  try {
    await Promise.all([page.waitForRequest(path), verify()]);
  } finally {
    release.resolve();
  }
}

test("all nine PLAN 7.1 page states render expected status and primary actions", async (t) => {
  const cases = [
    ["disabled", "未启用", "启用"],
    ["conflict", "有冲突", "迁移并切换"],
    ["core_missing", "核心缺失", "前往核心页"],
    ["starting", "启动中", "停用"],
    ["needs_login", "需要登录", "停用"],
    ["needs_approval", "等待批准", "停用"],
    ["stopped", "已停止", "连接"],
    ["running", "运行中", "停用"],
    ["error", "出错", "启用"],
  ];

  for (const [state, label, primaryBtn] of cases) {
    const { page, url } = await openPreview(t, { initialState: state });
    await page.goto(url);
    await ready(page);
    await page.getByRole("heading", { name: label }).waitFor();
    await page.getByRole("button", { name: primaryBtn, exact: true }).first().waitFor();
    if (state === "error") {
      await page.getByText("not in map poll", { exact: true }).waitFor();
    }
    await page.close();
  }
});

test("disable requires confirmation and warns when accessed via tailnet", async (t) => {
  // Normal LAN access: cancel keeps running, confirm disables.
  const lan = await openPreview(t, {
    initialState: "running",
    fastJobPoll: true,
    jobStepMs: 20,
  });
  let disablePosts = 0;
  lan.page.on("request", (req) => {
    if (req.method() === "POST" && JSON.parse(req.postData()).params?.[0] === "disable") disablePosts++;
  });
  await lan.page.goto(lan.url);
  await ready(lan.page);
  await lan.page.getByRole("button", { name: "停用", exact: true }).click();
  const lanDialog = lan.page.getByRole("alertdialog");
  await lanDialog.waitFor();
  await lanDialog.getByText(/停用会停止后台服务/).waitFor();
  await lanDialog.getByRole("button", { name: "取消", exact: true }).click();
  await lanDialog.waitFor({ state: "hidden" });
  assert.equal(disablePosts, 0);
  await lan.page.getByRole("heading", { name: "运行中" }).waitFor();

  await lan.page.getByRole("button", { name: "停用", exact: true }).click();
  await lanDialog.waitFor();
  await lanDialog.getByRole("button", { name: "确认", exact: true }).click();
  await lan.page.getByRole("heading", { name: "未启用" }).waitFor();

  assert.equal(disablePosts, 1);

  // Tailnet-origin access: shows tailnet disconnect warning.
  const tailnet = await openPreview(t, {
    initialState: "running",
    fastJobPoll: true,
    jobStepMs: 20,
    mutateStatus: (s) => {
      s.self.ips.push("127.0.0.1");
    },
  });
  await tailnet.page.goto(tailnet.url);
  await ready(tailnet.page);
  await tailnet.page.getByRole("button", { name: "停用", exact: true }).click();
  const tnDialog = tailnet.page.getByRole("alertdialog");
  await tnDialog.waitFor();
  await tnDialog.getByText(/正通过 tailnet 访问/).waitFor();
  await tnDialog.getByRole("button", { name: "确认", exact: true }).click();
  await tailnet.page.getByRole("heading", { name: "未启用" }).waitFor();
});

test("login flow: interactive QR, custom server notice, http warning, authkey login, expiry, and unsafe auth_url", async (t) => {
  const { page, url } = await openPreview(t, {
    viewport: { width: 420, height: 900 },
    initialState: "needs_login",
    fastJobPoll: true,
    jobStepMs: 25,
  });
  await page.goto(url);
  await ready(page);

  // Open advanced options, test http:// warning and invalid server validation.
  await page.getByRole("button", { name: /高级选项/ }).click();
  const serverInput = page.getByLabel("控制服务器地址", { exact: true });
  await serverInput.fill("ftp://bad.example.org");
  await page.getByRole("button", { name: "获取登录链接", exact: true }).click();
  await page.getByRole("alert").getByText(/控制服务器地址必须以/).waitFor();

  await serverInput.fill("http://192.0.2.10:8080");
  await page.getByText(/明文 http:\/\//).waitFor();

  // Interactive login against custom control server shows QR SVG and custom server hint.
  await serverInput.fill("https://hs.example.org");
  await page.getByRole("button", { name: "获取登录链接", exact: true }).click();
  await page.getByRole("img", { name: "登录授权二维码", exact: true }).waitFor();
  await page.getByText("请在控制服务器上批准这台设备，或者改用预授权密钥。", { exact: true }).waitFor();

  // Auth key login sends key in params (never fields) and transitions to running.
  const loginPosts = [];
  page.on("request", (r) => {
    if (r.method() === "POST" && r.url().endsWith("/_api/")) {
      const b = JSON.parse(r.postData() || "{}");
      if (b.params?.[0] === "login") loginPosts.push(b);
    }
  });
  const authInput = page.getByLabel("预授权密钥", { exact: true });
  await authInput.fill("bifrost_test_authkey_001");
  await page.getByRole("button", { name: "使用预授权密钥登录", exact: true }).click();
  await page.getByRole("heading", { name: "运行中" }).waitFor();
  assert.equal(loginPosts.length, 1);
  assert.deepEqual(loginPosts[0].fields, {});
  assert.deepEqual(loginPosts[0].params, ["login", "https://hs.example.org", "bifrost_test_authkey_001"]);
  // Custom server is displayed in Overview and locks no_logs in Settings.
  await page.getByText("https://hs.example.org", { exact: true }).waitFor();
  await clickTab(page, "设置");
  assert.equal(await page.getByRole("switch", { name: "不向 Tailscale 上传日志" }).isDisabled(), true);

  // Expiry flow.
  const expiredCtx = await openPreview(t, {
    initialState: "needs_login",
    loginExpires: true,
    fastJobPoll: true,
    jobStepMs: 20,
  });
  await expiredCtx.page.goto(expiredCtx.url);
  await ready(expiredCtx.page);
  await expiredCtx.page.getByRole("button", { name: "获取登录链接", exact: true }).click();
  await expiredCtx.page.getByText("登录链接已过期，请点击下方按钮重新获取。", { exact: true }).waitFor();
  assert.equal(await expiredCtx.page.getByRole("alert").count(), 1);
  assert.equal(await expiredCtx.page.getByText(/登录链接已过期|登录授权已过期/).count(), 1);

  // Unsafe auth_url (javascript:) is blocked: no link, no QR, shows error banner.
  const unsafeCtx = await openPreview(t, {
    initialState: "needs_login",
    mutateStatus: (s) => {
      s.auth_url = "javascript:alert(1)";
    },
  });
  await unsafeCtx.page.goto(unsafeCtx.url);
  await ready(unsafeCtx.page);
  await unsafeCtx.page.getByRole("alert").getByText(/仅允许 http:\/\/ 或 https:\/\//).waitFor();
  assert.equal(await unsafeCtx.page.getByRole("img", { name: "登录授权二维码" }).count(), 0);
  const badLinks = await unsafeCtx.page.evaluate(() => {
    const shadow = document.getElementById("bifrost-app")?.shadowRoot;
    return Array.from(shadow?.querySelectorAll("a[href]") ?? []).filter((a) =>
      a.getAttribute("href")?.toLowerCase().startsWith("javascript:"),
    ).length;
  });
  assert.equal(badLinks, 0);
});

test("an oversized authorization URL keeps a usable link across reloads", async (t) => {
  const longUrl = "https://auth.example.org/" + "a".repeat(3072);
  const { page, url } = await openPreview(t, {
    initialState: "needs_login",
    mutateStatus: (s) => { s.auth_url = longUrl; },
  });
  await page.goto(url);
  for (let i = 0; i < 2; i++) {
    if (i) await page.reload();
    await ready(page);
    await page.getByText("无法生成二维码，请打开授权链接继续。", { exact: true }).waitFor();
    assert.equal(await page.getByRole("img", { name: "登录授权二维码" }).count(), 0);
    const link = page.getByRole("link", { name: "打开授权链接" });
    assert.equal(await link.getAttribute("href"), longUrl);
    assert.equal(await link.isVisible(), true);
    await clickTab(page, "设置");
    assert.equal(await page.locator("#setting-port").isEnabled(), true);
  }
});

test("login waiting does not block actions; disabling during login cleanly cancels without stale error", async (t) => {
  const { page, url } = await openPreview(t, {
    initialState: "needs_login",
    loginStayWaiting: true,
    fastJobPoll: true,
    jobStepMs: 20,
  });
  await page.goto(url);
  await ready(page);

  await page.getByRole("button", { name: "获取登录链接", exact: true }).click();
  await page.getByRole("img", { name: "登录授权二维码", exact: true }).waitFor();

  // A waiting login blocks other login attempts, while settings and disable stay available.
  const disableBtn = page.getByRole("button", { name: "停用", exact: true });
  const retryBtn = page.getByRole("button", { name: "重新获取链接", exact: true });
  assert.equal(await disableBtn.isEnabled(), true);
  assert.equal(await retryBtn.isDisabled(), true);
  await page.getByText(/正在等待登录完成，10 分钟后过期/).waitFor();
  await page.getByRole("button", { name: /高级选项/ }).click();
  assert.equal(await page.getByLabel("控制服务器地址", { exact: true }).isDisabled(), true);
  assert.equal(await page.getByLabel("预授权密钥", { exact: true }).isDisabled(), true);

  await clickTab(page, "设置");
  assert.equal(await page.locator("#setting-port").isEnabled(), true);
  await clickTab(page, "概览");
  // Clicking disable while login is waiting confirms, stops daemon, cancels login, and shows no stale error.
  await disableBtn.click();
  await page.getByRole("alertdialog").getByRole("button", { name: "确认", exact: true }).click();
  await page.getByRole("heading", { name: "未启用" }).waitFor();
  const finished = await (await page.request.get(new URL("/_temp/bifrost_login.json", url).href)).json();
  assert.equal(finished.running, false);
  assert.equal(finished.ok, false);
  assert.equal(await page.getByText("Tailscale 命令执行失败，请查看诊断日志。", { exact: true }).count(), 0);
  assert.equal(await page.getByRole("alert").count(), 0);
});

test("a failed disable leaves the waiting login watched and reports its eventual failure", async (t) => {
  const login = {
    schema: 1, job: "login", phase: "waiting", running: true, progress: null,
    ok: null, code: null, started: SAMPLE_NOW, finished: null, pid: 4300, data: { action: "relogin" },
  };
  const { page, url } = await openPreview(t, {
    initialState: "running", initialJobs: { login }, fastJobPoll: true,
  });
  await page.goto(url);
  await ready(page);
  const relogin = page.getByRole("button", { name: "重新登录", exact: true });
  assert.equal(await relogin.isDisabled(), true);
  await page.route("**/_api/", (route) => JSON.parse(route.request().postData()).params[0] === "disable"
    ? route.fulfill({ json: { result: { ok: true, job: "daemon" } } })
    : route.continue());
  await page.route("**/_temp/bifrost_daemon.json", (route) => route.fulfill({ json: {
    ...login, job: "daemon", phase: "done", running: false, ok: false, code: "internal", data: {},
  } }));
  await page.getByRole("button", { name: "停用", exact: true }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "确认", exact: true }).click();
  await page.getByRole("main").getByRole("alert").waitFor();
  assert.equal(await relogin.isDisabled(), true);
  await page.route("**/_temp/bifrost_login.json", (route) => route.fulfill({ json: {
    ...login, phase: "done", running: false, ok: false, code: "cli_failed", finished: SAMPLE_NOW + 2,
  } }));
  await page.getByText("Tailscale 命令执行失败，请查看诊断日志。", { exact: true }).waitFor();
  assert.equal(await relogin.isEnabled(), true);
});

test("pollJob error recovery: transient errors recover, persistent errors retain active progress until the job file recovers", async (t) => {
  // 1. Transient 503 x2 during core-check recovers and finishes cleanly.
  const transient = await openPreview(t, {
    initialState: "running",
    fastJobPoll: true,
    jobStepMs: 20,
  });
  await transient.page.goto(transient.url);
  await ready(transient.page);
  await clickTab(transient.page, "核心");
  let transientFails = 0;
  const firstFailed = Promise.withResolvers();
  const retry = Promise.withResolvers();
  await transient.page.route("**/_temp/bifrost_update.json", async (route) => {
    if (transientFails < 2) {
      transientFails++;
      if (transientFails === 2) {
        firstFailed.resolve();
        await retry.promise;
      }
      await route.fulfill({ status: 503, contentType: "text/plain", body: "unavailable" });
      return;
    }
    await route.continue();
  });
  await transient.page.getByRole("button", { name: "检查更新", exact: true }).click();
  try {
    await firstFailed.promise;
    assert.equal(await transient.page.getByRole("button", { name: "检查更新", exact: true }).isDisabled(), true);
  } finally {
    retry.resolve();
  }
  await transient.page.getByText(/发现新核心：1\.106\.0/).waitFor();
  assert.equal(transientFails, 2);

  // 2. A persistent 503 keeps the last running state and recovers once reads succeed.
  const persistent = await openPreview(t, {
    initialState: "running",
    fastJobPoll: true,
    jobStepMs: 20,
  });
  let interruptAfterProgress = false;
  let updateReads = 0;
  const allowFailure = Promise.withResolvers();
  await persistent.page.route("**/_temp/bifrost_update.json", async (route) => {
    if (interruptAfterProgress && ++updateReads > 1) {
      await allowFailure.promise;
      await route.fulfill({ status: 503, contentType: "text/plain", body: "unavailable" });
      return;
    }
    await route.continue();
  });
  await persistent.page.goto(persistent.url);
  await ready(persistent.page);
  await clickTab(persistent.page, "核心");
  interruptAfterProgress = true;
  const checkBtn = persistent.page.getByRole("button", { name: "检查更新", exact: true });
  await checkBtn.click();
  try {
    await persistent.page.getByRole("meter").waitFor();
    assert.equal(await persistent.page.getByRole("button", { name: "更新核心", exact: true }).isDisabled(), true);
  } finally {
    allowFailure.resolve();
  }
  await persistent.page.getByText(/请求失败（HTTP 503）/).waitFor();
  assert.equal(await persistent.page.getByRole("button", { name: "更新核心", exact: true }).isDisabled(), true);
  interruptAfterProgress = false;
  await persistent.page.getByText(/发现新核心：1\.106\.0/).waitFor();
});

test("initialization reads existing job files: resumes running update and restores saved netcheck/update results", async (t) => {
  const update = {
    schema: 1, job: "update", running: true, phase: "verify_manifest", progress: 45,
    ok: null, code: null, started: SAMPLE_NOW, finished: null, pid: 4321,
    data: { action: "check", latest: null, up_to_date: false, kept_prev: true },
  };
  const { page, url } = await openPreview(t, {
    initialState: "running",
    fastJobPoll: true,
    initialJobs: {
      update: {
        ...update, running: false, phase: "done", progress: 100, ok: true,
        finished: SAMPLE_NOW + 5, data: { ...update.data, up_to_date: true },
      },
      netcheck: {
        schema: 1,
        job: "netcheck",
        running: false,
        phase: "done",
        progress: 100,
        ok: true,
        code: null,
        started: SAMPLE_NOW - 120,
        finished: SAMPLE_NOW - 115,
        pid: 4310,
        data: { report: SAMPLE_NETCHECK_REPORT },
      },
    },
  });

  const updatePath = "**/_temp/bifrost_update.json";
  await page.route(updatePath, (route) => route.fulfill({ json: update }));
  await page.goto(url);
  await ready(page);
  await page.reload();
  await ready(page);

  // Saved netcheck report is immediately shown on Overview without re-running netcheck.
  await page.getByText("UPnP", { exact: true }).waitFor();
  await page.getByText("tok (28 ms)", { exact: true }).waitFor();

  // Switch to Core tab: resumed in-flight update job shows progress & disables buttons, then settles to up_to_date.
  await clickTab(page, "核心");
  assert.equal(await page.getByRole("button", { name: "更新核心", exact: true }).isDisabled(), true);
  await page.getByRole("meter").waitFor();
  await page.unroute(updatePath);
  await page.getByText("当前已是最新稳定版核心。", { exact: true }).waitFor();
  assert.equal(await page.getByRole("button", { name: "检查更新", exact: true }).isEnabled(), true);

  // Overview now reflects confirmed up_to_date from the resumed check job.
  await clickTab(page, "概览");
  await page.getByText("当前已是最新核心", { exact: true }).waitFor();

  // A second visit now discovers only the completed update check and the saved report.
  await page.reload();
  await ready(page);
  await page.getByText("当前已是最新核心", { exact: true }).waitFor();
  await clickTab(page, "诊断");
  await page.getByText("28 ms", { exact: true }).waitFor();
});

test("a fresh page omits finished daemon, migration and update mutation results", async (t) => {
  const finished = {
    schema: 1, running: false, phase: "done", progress: 100, ok: true, code: null,
    started: SAMPLE_NOW - 5, finished: SAMPLE_NOW, pid: 4300, data: {},
  };
  const { page, url } = await openPreview(t, {
    initialState: "running",
    initialJobs: {
      daemon: { ...finished, job: "daemon", ok: false, code: "cli_failed" },
      migrate: { ...finished, job: "migrate" },
      update: { ...finished, job: "update", data: { action: "update", kept_prev: false } },
    },
  });
  await page.goto(url);
  await ready(page);
  assert.equal(await page.getByRole("alert").count(), 0);
  assert.equal(await page.getByRole("heading", { name: "从原版插件迁移" }).count(), 0);
  await clickTab(page, "核心");
  assert.equal(await page.getByText("操作已完成", { exact: true }).count(), 0);
  assert.equal(await page.getByText(/剩余空间不足，未保留上一版/).count(), 0);
});

test("reloading during migration keeps its progress and actions locked until completion", async (t) => {
  const migration = {
    schema: 1, job: "migrate", running: true, phase: "copy", progress: 55,
    ok: null, code: null, started: SAMPLE_NOW, finished: null, pid: 4311,
    data: { manual_stop: false, rolled_back: false },
  };
  const { page, url } = await openPreview(t, {
    initialState: "running",
    fastJobPoll: true,
    initialJobs: {
      migrate: { ...migration, running: false, phase: "done", progress: 100, ok: true, finished: SAMPLE_NOW + 1 },
    },
  });
  await page.goto(url);
  await ready(page);
  const jobPath = "**/_temp/bifrost_migrate.json";
  await page.route(jobPath, (route) => route.fulfill({ json: migration }));
  let failedReads = 0;
  await page.route(jobPath, (route) => { failedReads++; return route.fulfill({ status: 503 }); }, { times: 1 });
  await page.reload();
  await ready(page);
  await page.getByRole("meter", { name: "复制状态文件" }).waitFor();
  assert.equal(failedReads, 1);
  const disable = page.getByRole("button", { name: "停用", exact: true });
  assert.equal(await disable.isDisabled(), true);
  await page.unroute(jobPath);
  await page.getByText(/迁移成功，Bifrost/).waitFor();
  assert.equal(await disable.isEnabled(), true);
});

test("migration flow: success and automatic rollback", async (t) => {
  const { page, url } = await openPreview(t, {
    initialState: "conflict",
    fastJobPoll: true,
    jobStepMs: 25,
  });
  await page.goto(url);
  await ready(page);
  await page.getByRole("button", { name: "迁移并切换", exact: true }).first().click();
  const dialog = page.getByRole("alertdialog");
  await dialog.waitFor();
  await dialog.getByRole("button", { name: "确认", exact: true }).click();
  await page.getByRole("heading", { name: "运行中" }).waitFor();
  await page.getByRole("main").getByText(/迁移成功/).waitFor();

  const rb = await openPreview(t, {
    initialState: "conflict",
    migrateMode: "rollback",
    fastJobPoll: true,
    jobStepMs: 25,
  });
  await rb.page.goto(rb.url);
  await ready(rb.page);
  await rb.page.getByRole("button", { name: "迁移并切换", exact: true }).first().click();
  await rb.page.getByRole("alertdialog").getByRole("button", { name: "确认", exact: true }).click();
  await rb.page.getByText(/已自动回滚到原版状态/).waitFor();
  assert.equal(await rb.page.getByText(/已自动回滚/).count(), 1);
  assert.equal(await rb.page.getByRole("alert").count(), 1);
});

test("devices page: preserves backend peer order, filters, caps at 200 rows, and pings per row", async (t) => {
  // Verify exact contract §6.1 server ordering is preserved (never re-sorted on client).
  const ordered = await openPreview(t, {
    initialState: "running",
    mutateStatus: (s) => {
      s.peers = [
        { ...s.peers[3], name: "offline-first", ip: "100.64.0.99", ips: ["100.64.0.99"], online: false },
        { ...s.peers[0], name: "z-node", ip: "100.64.0.98", ips: ["100.64.0.98"], online: true },
        { ...s.peers[1], name: "a-node", ip: "100.64.0.97", ips: ["100.64.0.97"], online: true },
      ];
    },
  });
  await ordered.page.goto(ordered.url);
  await ready(ordered.page);
  await clickTab(ordered.page, "设备");
  const renderedOrder = await ordered.page.evaluate(() => {
    const shadow = document.getElementById("bifrost-app")?.shadowRoot;
    return Array.from(shadow?.querySelectorAll("main tbody tr td:first-child span:first-child") ?? []).map(
      (el) => el.textContent?.trim(),
    );
  });
  assert.deepEqual(renderedOrder, ["offline-first", "z-node", "a-node"]);

  const { page, url } = await openPreview(t, {
    initialState: "running",
    mutateStatus: (s) => {
      for (let i = 10; i < 215; i++) {
        s.peers.push({
          name: `device-${String(i).padStart(3, "0")}`,
          dns_name: `device-${i}.example.ts.net`,
          ip: `100.64.1.${i % 250}`,
          ips: [`100.64.1.${i % 250}`],
          os: "linux",
          online: i < 20,
          path: "direct",
          relay: "",
          last_handshake: s.time - 30,
          rx: 1024,
          tx: 2048,
          exit_node_option: false,
          routes: [],
        });
      }
    },
  });
  await page.goto(url);
  await ready(page);
  await clickTab(page, "设备");

  await page.getByText(/当前仅展示前 200 台设备/).waitFor();
  assert.equal(await page.locator("main tbody tr").count(), 200);

  await page.getByPlaceholder("按设备名或地址筛选…").fill("office-gw");
  assert.equal(await page.locator("main tbody tr").count(), 1);
  await page.getByRole("button", { name: "Ping office-gw", exact: true }).click();
  await page.getByText(/38 ms · DERP（tok）/).waitFor();
});

test("settings page: saves send requests and display server read-back values, validation, warnings, and prefs-null disabling", async (t) => {
  const sentSets = [];
  const { page, url } = await openPreview(t, {
    viewport: { width: 420, height: 900 },
    initialState: "running",
    fastJobPoll: true,
    jobStepMs: 25,
    mutateStatus: (s) => {
      s.peers[1].routes = ["192.168.1.0/24"];
      s.self.ips.push("127.0.0.1");
    },
    onSetReadBack: (key, val) => {
      if (key === "hostname") return `${val}-rb`;
      if (key === "mirror") return `${val}rb/`;
      if (key === "port") return val + 1;
      if (key === "advertise_routes") return [...val, "198.51.100.128/25"];
      return val;
    },
  });
  page.on("request", (r) => {
    if (r.method() === "POST" && r.url().endsWith("/_api/")) {
      const b = JSON.parse(r.postData() || "{}");
      if (b.params?.[0] === "set") sentSets.push(b);
    }
  });

  await page.goto(url);
  await ready(page);
  await clickTab(page, "设置");

  // 1. Advertise routes: reject invalid CIDR, add valid CIDR, verify POST and server read-back.
  const routeInput = page.locator("#setting-advertise-routes-input");
  await routeInput.fill("0.0.0.0/0");
  await page.getByRole("button", { name: "添加", exact: true }).click();
  await page.getByRole("alert").getByText(/不允许 0\.0\.0\.0\/0/).waitFor();

  await routeInput.fill("198.51.100.0/24");
  await page.getByRole("button", { name: "添加", exact: true }).click();
  await withStatusReadHeld(page, async () => {
    await page.getByRole("button", { name: "保存", exact: true }).first().click();
    await page.getByText(/当前读回值：.*198\.51\.100\.128\/25/).waitFor();
  });
  assert.deepEqual(sentSets.at(-1).fields, {});
  assert.deepEqual(sentSets.at(-1).params, [
    "set",
    "advertise_routes",
    "192.168.1.0/24,192.0.2.0/24,198.51.100.0/24",
  ]);

  // 2. Accept routes overlap confirmation dialog.
  await page.getByRole("switch", { name: "接受其他设备宣告的路由" }).click();
  const overlapDialog = page.getByRole("alertdialog");
  await overlapDialog.waitFor();
  await overlapDialog.getByText(/检测到网段重叠/).waitFor();
  await overlapDialog.getByRole("button", { name: "确认", exact: true }).click();
  await page.waitForFunction(() => {
    const sw = document.getElementById("bifrost-app").shadowRoot.querySelector('[aria-label="接受其他设备宣告的路由"]');
    return sw?.getAttribute("aria-checked") === "true";
  });

  // 3. Local access off triggers tailnet-origin warning confirmation dialog.
  await page.getByRole("switch", { name: "允许 tailnet 访问路由器本机" }).click();
  const localDialog = page.getByRole("alertdialog");
  await localDialog.waitFor();
  await localDialog.getByText(/正通过 tailnet 访问/).waitFor();
  await localDialog.getByRole("button", { name: "确认", exact: true }).click();
  await page.waitForFunction(() => {
    const sw = document.getElementById("bifrost-app").shadowRoot.querySelector('[aria-label="允许 tailnet 访问路由器本机"]');
    return sw?.getAttribute("aria-checked") === "false";
  });

  // 4. SNAT select (modal=false) saves cleanly.
  await choose(page, "进局域网时转换源地址", "开启（始终转换）");
  await page.getByText(/当前生效：已开启/).waitFor();

  // 5. Device name validation + save -> input updates to server read-back value ("edge-router-rb").
  const hostInput = page.locator("#setting-hostname");
  await hostInput.fill("-bad-host");
  await page.getByRole("button", { name: "保存 设备名", exact: true }).click();
  await page.getByRole("alert").getByText(/不能以连字符开头或结尾/).waitFor();
  // Hold status read-back until the form has displayed the sync action's own value.
  await withStatusReadHeld(page, async () => {
    await hostInput.fill("edge-router");
    await page.getByRole("button", { name: "保存 设备名", exact: true }).click();
    await page.waitForFunction(() =>
      document.getElementById("bifrost-app").shadowRoot.querySelector("#setting-hostname")?.value === "edge-router-rb",
    );
  });
  assert.deepEqual(sentSets.at(-1).fields, {});
  assert.deepEqual(sentSets.at(-1).params, ["set", "hostname", "edge-router"]);

  // 6. Port save shows restart disruption dialog, sends request, and reads back 41643 (41642+1).
  const portInput = page.locator("#setting-port");
  await portInput.fill("80");
  await page.getByRole("button", { name: "保存 监听端口", exact: true }).click();
  await page.getByRole("alert").getByText(/1024–65535/).waitFor();
  await portInput.fill("41642");
  await page.getByRole("button", { name: "保存 监听端口", exact: true }).click();
  const portDialog = page.getByRole("alertdialog");
  await portDialog.waitFor();
  await portDialog.getByText(/连接短暂中断/).waitFor();
  await portDialog.getByRole("button", { name: "确认", exact: true }).click();
  await page.waitForFunction(() =>
    document.getElementById("bifrost-app").shadowRoot.querySelector("#setting-port")?.value === "41643",
  );
  assert.deepEqual(sentSets.at(-1).params, ["set", "port", "41642"]);

  // 7. Mirror validation + save -> reads back server-normalized value.
  const mirrorInput = page.locator("#setting-mirror");
  await mirrorInput.fill("http://insecure.example.org/");
  await page.getByRole("button", { name: "保存 下载镜像", exact: true }).click();
  await page.getByRole("alert").getByText(/以 https:\/\/ 开头/).waitFor();
  await withStatusReadHeld(page, async () => {
    await mirrorInput.fill("https://mirror.example.org/");
    await page.getByRole("button", { name: "保存 下载镜像", exact: true }).click();
    await page.waitForFunction(() =>
      document.getElementById("bifrost-app").shadowRoot.querySelector("#setting-mirror")?.value === "https://mirror.example.org/rb/",
    );
  });
  assert.deepEqual(sentSets.at(-1).params, ["set", "mirror", "https://mirror.example.org/"]);

  // 8. Disabled daemon disables tailscaled prefs and missing conf_dir disables magicdns.
  const off = await openPreview(t, {
    initialState: "disabled",
    onSetReadBack: (key, value) => key === "port" ? value + 1 : value,
    mutateStatus: (s) => { s.dns.conf_dir = false; },
  });
  await off.page.goto(off.url);
  await ready(off.page);
  await clickTab(off.page, "设置");
  await off.page.getByText(/启动后可以修改/).waitFor();
  assert.equal(await off.page.locator("#setting-hostname").isDisabled(), true);
  assert.equal(await off.page.getByRole("switch", { name: "局域网解析 tailnet 主机名" }).isDisabled(), true);

  // A stopped daemon returns port synchronously. No status-file read may supply the value.
  await withStatusReadHeld(off.page, async () => {
    await off.page.locator("#setting-port").fill("41642");
    await off.page.getByRole("button", { name: "保存 监听端口", exact: true }).click();
    const response = off.page.waitForResponse((r) => r.request().postData()?.includes('"port","41642"'));
    await off.page.getByRole("alertdialog").getByRole("button", { name: "确认", exact: true }).click();
    assert.deepEqual(JSON.parse((await (await response).json()).result), { ok: true, value: 41643 });
    await off.page.waitForFunction(() => document.getElementById("bifrost-app").shadowRoot
      .querySelector("#setting-port").value === "41643");
  });

  // 9. Running daemon with prefs === null (e.g. starting) disables all 4 prefs controls and explains why.
  const starting = await openPreview(t, { initialState: "starting" });
  await starting.page.goto(starting.url);
  await ready(starting.page);
  await clickTab(starting.page, "设置");
  await starting.page.getByText(/后台服务正在启动或暂未响应/).waitFor();
  assert.equal(await starting.page.locator("#setting-advertise-routes-input").isDisabled(), true);
  assert.equal(await starting.page.getByRole("switch", { name: "作为出口节点" }).count(), 0);
  assert.equal(await starting.page.getByRole("switch", { name: "接受其他设备宣告的路由" }).count(), 0);
  assert.equal(await starting.page.getByText("未知", { exact: true }).count(), 2);
  assert.equal(await starting.page.locator("#setting-hostname").isDisabled(), true);
  // Daemon-independent settings remain enabled.
  assert.equal(await starting.page.locator("#setting-port").isEnabled(), true);
  assert.equal(await starting.page.locator("#setting-mirror").isEnabled(), true);
});

test("core page: core.build display, null build fallback, update flow, up_to_date ok, old_serial error, and overview not-checked state", async (t) => {
  const { page, url } = await openPreview(t, {
    viewport: { width: 420, height: 900 },
    initialState: "running",
    fastJobPoll: true,
    jobStepMs: 25,
  });
  await page.goto(url);
  await ready(page);

  // Before any check, Overview must NOT claim core is up to date.
  await page.getByText("尚未检查核心更新，可前往核心页检查。", { exact: true }).waitFor();

  await clickTab(page, "核心");
  // core.build is rendered dynamically from status.core.build.
  await page.getByText("1.27.4", { exact: true }).waitFor();
  await page.getByText("cbc74fe48ef1", { exact: true }).waitFor();
  await page.getByText("aws", { exact: true }).waitFor();

  await page.getByRole("button", { name: "检查更新", exact: true }).click();
  await page.getByText(/发现新核心：1\.106\.0/).waitFor();

  await withStatusReadHeld(page, async () => {
    await page.getByRole("button", { name: "更新核心", exact: true }).click();
    await page.getByRole("alertdialog").getByRole("button", { name: "确认", exact: true }).click();
    // Result banner and onDone toast must both precede the delayed status read.
    await page.getByRole("main").getByText("操作已完成", { exact: true }).waitFor();
    await page.getByText("操作已完成", { exact: true }).nth(1).waitFor();
    assert.equal(await page.getByRole("button", { name: "检查更新", exact: true }).isEnabled(), true);
    assert.equal(await page.getByText("1.104.7", { exact: true }).isVisible(), true);
  });
  await page.getByText("1.106.0", { exact: true }).waitFor();

  // Check again -> ok: true + data.up_to_date: true renders neutral notice with zero alerts.
  await page.getByRole("button", { name: "检查更新", exact: true }).click();
  await page.getByText("当前已是最新稳定版核心。", { exact: true }).waitFor();
  assert.equal(await page.getByRole("alert").count(), 0);

  // Overview now confirms core is up to date because check succeeded with up_to_date: true.
  await clickTab(page, "概览");
  await page.getByText("当前已是最新核心", { exact: true }).waitFor();
  await clickTab(page, "核心");

  // Switch to arm64 on aarch64 kernel.
  await page.getByRole("button", { name: "切换到 arm64 核心", exact: true }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "确认", exact: true }).click();
  await page.getByText("arm64", { exact: true }).waitFor();

  // Roll back to previous -> disables rollback button afterward when prev=false.
  await page.getByRole("button", { name: "回退到上一版", exact: true }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "确认", exact: true }).click();
  await page.getByText("1.104.7", { exact: true }).waitFor();
  assert.equal(await page.getByRole("button", { name: "回退到上一版", exact: true }).isDisabled(), true);

  // core-check old_serial failure shows error alert (contract §6.2).
  const oldSerial = await openPreview(t, {
    initialState: "running",
    mutateStatus: (s) => { s.core.serial = 100; },
    fastJobPoll: true,
    jobStepMs: 20,
  });
  await oldSerial.page.goto(oldSerial.url);
  await ready(oldSerial.page);
  await clickTab(oldSerial.page, "核心");
  await oldSerial.page.getByRole("button", { name: "检查更新", exact: true }).click();
  await oldSerial.page.getByRole("alert").getByText(/远端核心版本号低于当前版本/).waitFor();
  await clickTab(oldSerial.page, "概览");
  await oldSerial.page.getByText(/远端核心版本号低于当前版本/).first().waitFor();
  assert.equal(await oldSerial.page.getByText("当前已是最新核心", { exact: true }).count(), 0);

  // core.build === null renders "未知" rather than hardcoded build recipe.
  const noBuild = await openPreview(t, {
    initialState: "running",
    mutateStatus: (s) => {
      s.core.build = null;
    },
  });
  await noBuild.page.goto(noBuild.url);
  await ready(noBuild.page);
  await clickTab(noBuild.page, "核心");
  assert.equal(await noBuild.page.getByText("未知", { exact: true }).count(), 3);
  assert.equal(await noBuild.page.getByText("aws", { exact: true }).count(), 0);

  for (const omit of [undefined, "aws"]) {
    const partial = await openPreview(t, {
      initialState: "running",
      mutateStatus: (s) => { s.core.build.omit = omit; },
    });
    await partial.page.goto(partial.url);
    await ready(partial.page);
    await clickTab(partial.page, "核心");
    await partial.page.getByText("1.27.4", { exact: true }).waitFor();
    assert.equal(await partial.page.getByText("未知", { exact: true }).count(), 1);
  }
});

test("HTTP clipboard fallback (navigator.clipboard undefined) copies real text across all copy surfaces", async (t) => {
  const { page, url } = await openPreview(t, {
    initialState: "running",
    fastJobPoll: true,
    jobStepMs: 25,
    viewport: { width: 420, height: 900 },
    insecureHttp: true,
  });
  await page.goto(url);
  assert.deepEqual(await page.evaluate(() => [isSecureContext, typeof navigator.clipboard]), [false, "undefined"]);
  await ready(page);

  // 420px viewport has zero horizontal document overflow.
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);

  const readRealClipboardViaPaste = async () => {
    await page.evaluate(() => {
      let ta = document.getElementById("bifrost-paste-probe");
      if (!ta) {
        ta = document.createElement("textarea");
        ta.id = "bifrost-paste-probe";
        document.body.appendChild(ta);
      }
      ta.value = "";
      ta.focus();
    });
    await page.keyboard.press(PASTE_SHORTCUT);
    return page.evaluate(() => document.getElementById("bifrost-paste-probe")?.value ?? "");
  };

  // 1. CopyInline on Overview (tailnet IP).
  await page.getByRole("button", { name: "复制到剪贴板" }).first().click();
  assert.equal(await readRealClipboardViaPaste(), "100.64.0.1");

  // 2. CopyField on Core (verify command).
  await clickTab(page, "核心");
  await page.getByRole("button", { name: "复制到剪贴板", exact: true }).click();
  assert.equal(await readRealClipboardViaPaste(), "openssl dgst -sha256 /koolshare/bifrost/bin/bifrostd");

  // 3. Diagnostics logs copy + netcheck + purge.
  await clickTab(page, "诊断");
  await page.getByRole("log").getByText(/== bifrost\.log ==/).waitFor();
  await page.getByRole("button", { name: "复制诊断信息", exact: true }).click();
  const pastedLogs = await readRealClipboardViaPaste();
  assert.equal(pastedLogs, SAMPLE_LOGS_TEXT);

  await page.getByRole("button", { name: "运行网络检测", exact: true }).click();
  await page.getByText("UPnP", { exact: true }).waitFor();
  await page.getByText("28 ms", { exact: true }).waitFor();

  // Purge confirmation popover.
  await page.getByRole("button", { name: "清除登录状态", exact: true }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "清除登录状态", exact: true }).click();
  await clickTab(page, "概览");
  await page.getByRole("heading", { name: "未启用" }).waitFor();
});

test("visibility-aware status polling serializes requests and never spawns duplicate loops", { timeout: 15000 }, async (t) => {
  const { page, url } = await openPreview(t, { initialState: "running" });
  await page.addInitScript(() => {
    let vis = "visible";
    Object.defineProperty(document, "visibilityState", {
      get: () => vis,
      configurable: true,
    });
    window.__setVis = (next) => {
      vis = next;
      document.dispatchEvent(new Event("visibilitychange"));
    };
    const timers = new Map();
    const nativeSet = window.setTimeout;
    const nativeClear = window.clearTimeout;
    let scheduled = 0;
    window.setTimeout = (fn, delay, ...args) => {
      if (delay !== 3000) return nativeSet(fn, delay, ...args);
      const id = -(++scheduled);
      timers.set(id, () => fn(...args));
      return id;
    };
    window.clearTimeout = (id) => {
      if (!timers.delete(id)) nativeClear(id);
    };
    window.__pollClock = {
      get size() { return timers.size; },
      get scheduled() { return scheduled; },
      tick() {
        if (timers.size !== 1) throw new Error(`Expected one status timer, found ${timers.size}`);
        const [id, fn] = timers.entries().next().value;
        timers.delete(id);
        fn();
      },
    };
  });

  await page.goto(url);
  await ready(page);
  await page.waitForFunction(() => window.__pollClock.size === 1);

  let requests = 0;
  const started = Promise.withResolvers();
  const release = Promise.withResolvers();
  await page.route("**/_api/", async (route) => {
    if (JSON.parse(route.request().postData()).method === "bifrost_status.sh") {
      requests++;
      started.resolve();
      await release.promise;
    }
    await route.continue();
  });
  try {
    await page.evaluate(() => window.__pollClock.tick());
    await started.promise;
    await page.evaluate(() => {
      for (let i = 0; i < 4; i++) {
        window.__setVis("hidden");
        window.__setVis("visible");
      }
    });
    assert.equal(requests, 1);
    assert.equal(await page.evaluate(() => window.__pollClock.size), 0);
  } finally {
    release.resolve();
  }

  // All visibility handlers shared the same request. Only the latest may
  // schedule its successor, even if an extra timer would later be cleared.
  await page.waitForFunction(() => window.__pollClock.size > 0);
  assert.equal(await page.evaluate(() => window.__pollClock.scheduled), 2);
  await page.evaluate(() => window.__pollClock.tick());
  await page.waitForFunction(() => window.__pollClock.size > 0);
  assert.equal(await page.evaluate(() => window.__pollClock.scheduled), 3);
  assert.equal(requests, 2);
  await page.evaluate(() => window.__setVis("hidden"));
  assert.equal(await page.evaluate(() => window.__pollClock.size), 0);
  await page.evaluate(() => window.__setVis("visible"));
  await page.waitForFunction(() => window.__pollClock.size === 1);
  assert.equal(requests, 3);
});

test("a setting saved during a status read is followed by a fresh status snapshot", { timeout: 15000 }, async (t) => {
  const { page, url } = await openPreview(t, { initialState: "running" });
  await page.goto(url);
  await ready(page);
  await clickTab(page, "设置");

  // Pause the old GET after the preview server has already generated its body.
  const oldRead = Promise.withResolvers();
  const release = Promise.withResolvers();
  await page.route("**/_temp/bifrost_status.json", async (route) => {
    const response = await route.fetch();
    oldRead.resolve();
    await release.promise;
    await route.fulfill({ response });
  }, { times: 1 });

  const nextReads = [];
  page.on("request", (req) => {
    if (req.method() === "POST" && JSON.parse(req.postData()).method === "bifrost_status.sh") {
      nextReads.push(req);
    }
  });
  await page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));
  await oldRead.promise;
  const setting = page.getByRole("switch", { name: "局域网设备访问 tailnet" });
  const saved = page.waitForResponse((r) =>
    r.request().method() === "POST" && r.request().postData()?.includes('"lan_masq"'),
  );
  try {
    await setting.click();
    await saved;
    assert.equal(nextReads.length, 1);
  } finally {
    release.resolve();
  }
  await page.getByText("已保存", { exact: true }).waitFor();
  assert.equal(await setting.isChecked(), false);
  assert.equal(nextReads.length, 2);
});
