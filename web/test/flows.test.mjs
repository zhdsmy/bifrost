import assert from "node:assert/strict";
import { test } from "node:test";
import { choose, clickTab, openPreview, ready } from "./fixture.mjs";

test("all nine PLAN 7.1 page states render expected status and primary actions", async (t) => {
  const cases = [
    ["disabled", "未启用", "启用"],
    ["conflict", "有冲突", "迁移并切换"],
    ["core_missing", "核心缺失", "前往核心页"],
    ["starting", "启动中", "停用"],
    ["needs_login", "需要登录", "获取登录链接"],
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

test("login flow: interactive QR, custom server notice, http warning, authkey login, and expiry", async (t) => {
  const { page, url } = await openPreview(t, {
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
});

test("devices page: filtering, 200-row cap, and per-row ping", async (t) => {
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

test("settings page: individual saves, validation, overlap/tailnet warnings, restart confirm, and daemon-off disable", async (t) => {
  const { page, url } = await openPreview(t, {
    initialState: "running",
    fastJobPoll: true,
    jobStepMs: 25,
    mutateStatus: (s) => {
      // Trigger both accept_routes overlap (peer advertises 192.168.1.0/24) and tailnet-origin check (127.0.0.1 in self.ips).
      s.peers[1].routes = ["192.168.1.0/24"];
      s.self.ips.push("127.0.0.1");
    },
  });
  await page.goto(url);
  await ready(page);
  await clickTab(page, "设置");

  // 1. Advertise routes: reject invalid CIDR, add valid CIDR, save and confirm read-back.
  const routeInput = page.locator("#setting-advertise-routes-input");
  await routeInput.fill("0.0.0.0/0");
  await page.getByRole("button", { name: "添加", exact: true }).click();
  await page.getByRole("alert").getByText(/不允许 0\.0\.0\.0\/0/).waitFor();

  await routeInput.fill("198.51.100.0/24");
  await page.getByRole("button", { name: "添加", exact: true }).click();
  await page.getByRole("button", { name: "保存", exact: true }).first().click();
  await page.getByText(/当前读回值：.*198\.51\.100\.0\/24/).waitFor();

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

  // 5. Device name validation + save.
  const hostInput = page.locator("#setting-hostname");
  await hostInput.fill("-bad-host");
  await page.getByRole("button", { name: "保存 设备名", exact: true }).click();
  await page.getByRole("alert").getByText(/不能以连字符开头或结尾/).waitFor();
  await hostInput.fill("edge-router");
  await page.getByRole("button", { name: "保存 设备名", exact: true }).click();
  assert.equal(await hostInput.inputValue(), "edge-router");

  // 6. Port save shows restart disruption dialog and polls daemon job.
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
    document.getElementById("bifrost-app").shadowRoot.querySelector("#setting-port")?.value === "41642",
  );

  // 7. Mirror validation + save.
  const mirrorInput = page.locator("#setting-mirror");
  await mirrorInput.fill("http://insecure.example.org/");
  await page.getByRole("button", { name: "保存 下载镜像", exact: true }).click();
  await page.getByRole("alert").getByText(/以 https:\/\/ 开头/).waitFor();
  await mirrorInput.fill("https://mirror.example.org/");
  await page.getByRole("button", { name: "保存 下载镜像", exact: true }).click();
  assert.equal(await mirrorInput.inputValue(), "https://mirror.example.org/");

  // 8. Disabled daemon disables tailscaled prefs and missing conf_dir disables magicdns.
  const off = await openPreview(t, {
    initialState: "disabled",
    mutateStatus: (s) => { s.dns.conf_dir = false; },
  });
  await off.page.goto(off.url);
  await ready(off.page);
  await clickTab(off.page, "设置");
  await off.page.getByText(/启动后可以修改/).waitFor();
  assert.equal(await off.page.locator("#setting-hostname").isDisabled(), true);
  assert.equal(await off.page.getByRole("switch", { name: "局域网解析 tailnet 主机名" }).isDisabled(), true);
});

test("core page: check update, update with progress, arch switch, rollback, and up-to-date non-error", async (t) => {
  const { page, url } = await openPreview(t, {
    initialState: "running",
    fastJobPoll: true,
    jobStepMs: 25,
  });
  await page.goto(url);
  await ready(page);
  await clickTab(page, "核心");

  await page.getByRole("button", { name: "检查更新", exact: true }).click();
  await page.getByText(/发现新核心：1\.106\.0/).waitFor();

  await page.getByRole("button", { name: "更新核心", exact: true }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "确认", exact: true }).click();
  await page.getByText("1.106.0", { exact: true }).waitFor();

  // Check again -> up_to_date is shown as neutral notice, not error alert.
  await page.getByRole("button", { name: "检查更新", exact: true }).click();
  await page.getByText("当前已是最新稳定版核心。", { exact: true }).waitFor();
  assert.equal(await page.getByRole("alert").count(), 0);

  // Switch to arm64 on aarch64 kernel.
  await page.getByRole("button", { name: "切换到 arm64 核心", exact: true }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "确认", exact: true }).click();
  await page.getByText("arm64", { exact: true }).waitFor();

  // Roll back to previous -> disables rollback button afterward when prev=false.
  await page.getByRole("button", { name: "回退到上一版", exact: true }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "确认", exact: true }).click();
  await page.getByText("1.104.7", { exact: true }).waitFor();
  assert.equal(await page.getByRole("button", { name: "回退到上一版", exact: true }).isDisabled(), true);
});

test("diagnostics page: netcheck, env checks, raw logs copy, purge, and narrow 420px layout", async (t) => {
  const { page, url } = await openPreview(t, {
    initialState: "running",
    fastJobPoll: true,
    jobStepMs: 25,
    viewport: { width: 420, height: 900 },
  });
  await page.addInitScript(() => {
    window.__copied = "";
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText: async (text) => { window.__copied = text; } },
      configurable: true,
    });
  });

  await page.goto(url);
  await ready(page);

  // 420px viewport has zero horizontal document overflow.
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);

  await clickTab(page, "诊断");
  await page.getByRole("log").getByText(/== bifrost\.log ==/).waitFor();
  await page.getByRole("button", { name: "复制诊断信息", exact: true }).click();
  const copied = await page.evaluate(() => window.__copied);
  assert.match(copied, /== summary ==/);
  assert.match(copied, /== bifrostd\.log ==/);

  await page.getByRole("button", { name: "运行网络检测", exact: true }).click();
  await page.getByText("UPnP", { exact: true }).waitFor();
  await page.getByText("28 ms", { exact: true }).waitFor();

  // Purge confirmation popover.
  await page.getByRole("button", { name: "清除登录状态", exact: true }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "清除登录状态", exact: true }).click();
  await clickTab(page, "概览");
  await page.getByRole("heading", { name: "未启用" }).waitFor();
});

test("visibility-aware status polling pauses when hidden and resumes when visible", async (t) => {
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
    const nativeSetTimeout = window.setTimeout;
    window.setTimeout = (fn, delay, ...args) => {
      if (delay === 3000) delay = 80;
      return nativeSetTimeout(fn, delay, ...args);
    };
  });

  let statusPolls = 0;
  page.on("request", (r) => {
    if (r.method() === "POST" && r.url().endsWith("/_api/")) {
      const b = JSON.parse(r.postData() || "{}");
      if (b.method === "bifrost_status.sh") statusPolls++;
    }
  });

  await page.goto(url);
  await ready(page);
  await page.waitForTimeout(260);
  const pollsWhileVisible = statusPolls;
  assert.ok(pollsWhileVisible >= 2, `expected visible polling, got ${pollsWhileVisible}`);

  await page.evaluate(() => window.__setVis("hidden"));
  await page.waitForTimeout(100);
  const countAfterHide = statusPolls;
  await page.waitForTimeout(260);
  assert.equal(statusPolls, countAfterHide, "polling must stop while document is hidden");

  await page.evaluate(() => window.__setVis("visible"));
  await page.waitForTimeout(180);
  assert.ok(statusPolls > countAfterHide, "polling must resume when document becomes visible again");
});
