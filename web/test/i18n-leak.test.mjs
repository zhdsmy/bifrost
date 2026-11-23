import assert from "node:assert/strict";
import { test } from "node:test";
import { choose, clickTab, openPreview, ready } from "./fixture.mjs";
import { zhCN } from "../src/i18n/zh-CN.ts";
import { getKumoTranslations } from "../src/i18n/index.ts";

// Strictly proper nouns, protocol/product names, architectures, and units intentionally
// kept in English in the Chinese UI (PLAN 13.9). No ordinary English words allowed here.
const ALLOWED_TOKENS = new Set([
  "bifrost",
  "tailscale",
  "tailscaled",
  "tailnet",
  "magicdns",
  "derp",
  "wireguard",
  "headscale",
  "ipv4",
  "ipv6",
  "cidr",
  "udp",
  "tcp",
  "nat",
  "wan",
  "lan",
  "jffs",
  "usb2jffs",
  "ssh",
  "upx",
  "ping",
  "english",
  "macos",
  "linux",
  "ios",
  "windows",
  "arm",
  "arm64",
  "aarch64",
  "armv7l",
  "dnsmasq",
  "dns",
  "http",
  "https",
  "upnp",
  "pcp",
  "pmp",
  "openssl",
  "sha256",
  "koolshare",
  "bifrostd",
]);

// Exact names: the Go language, AP (access point) mode, and the Linux tun module.
const EXACT_NAMES = new Set(["Go", "AP", "tun"]);

function findUntranslatedEnglish(texts) {
  return texts.flatMap((raw) => {
    const text = raw
      .replace(/https?:\/\/[A-Za-z0-9./:_-]*/gi, " ")
      .replace(/\/dev\/net\/tun|\bconf-dir\b/g, " ")
      .replace(/\br(?:\d+|\{revision\})/g, " ")
      .replace(/(?:\d+(?:\.\d+)?|\{[a-z]+\})\s*(?:ms|[KMGT]?B)\b/gi, " ")
      .replace(/\{[A-Za-z0-9_]+\}/g, " ");
    const unknown = (text.match(/[A-Za-z][A-Za-z0-9]*/g) ?? [])
      .filter((word) => !EXACT_NAMES.has(word) && !ALLOWED_TOKENS.has(word.toLowerCase()));
    return unknown.length ? [{ raw, unknown }] : [];
  });
}

test("the Chinese leak check rejects untranslated words even inside Chinese labels", () => {
  for (const word of ["a", "s", "w", "enabled", "auth", "session", "relay", "home", "router", "go", "ap", "TUN"]) {
    assert.ok(findUntranslatedEnglish([`设置 ${word} 状态`]).length);
  }
});

async function collectShadowTexts(page) {
  return page.evaluate(() => {
    const shadow = document.getElementById("bifrost-app")?.shadowRoot;
    if (!shadow) return [];
    const results = [];
    const walker = document.createTreeWalker(shadow, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      const el = node.parentElement;
      if (!el) continue;
      // Skip raw dynamic data values, raw logs, and command/code literals (PLAN 13.9).
      if (el.closest('pre[role="log"], code, [data-raw-value]')) continue;
      const style = getComputedStyle(el);
      if (style.display === "none" || style.visibility === "hidden") continue;
      const text = node.textContent?.trim();
      if (text) results.push(text);
    }
    for (const el of shadow.querySelectorAll("[aria-label], [placeholder], [title]")) {
      for (const attr of ["aria-label", "placeholder", "title"]) {
        const label = el.getAttribute(attr)?.trim();
        if (label) results.push(label);
      }
    }
    return results;
  });
}

function assertClean(texts, contextLabel) {
  const leaks = findUntranslatedEnglish(texts);
  assert.deepEqual(leaks, [], `Untranslated English found in ${contextLabel}: ${JSON.stringify(leaks)}`);
}

test("i18n leak check: static zh-CN dictionary and Kumo translations have no untranslated English", () => {
  assertClean(Object.values(zhCN), "zhCN dictionary");
  const kumoStrings = [];
  const collect = (obj) => {
    for (const v of Object.values(obj)) {
      if (typeof v === "string") kumoStrings.push(v);
      else if (v && typeof v === "object") collect(v);
    }
  };
  collect(getKumoTranslations("zh-CN"));
  assertClean(kumoStrings, "getKumoTranslations('zh-CN')");
});

test("i18n leak check: tabs, states, tooltips, confirmation popovers, validation and job errors have no untranslated English", async (t) => {
  // 1. All 5 tabs + tooltips + confirmation popovers + validation banners in running state.
  const { page, url } = await openPreview(t, {
    initialState: "running",
    lang: "zh-CN",
    mode: "dark",
    fastJobPoll: true,
    jobStepMs: 20,
    mutateStatus: (s) => {
      s.peers.forEach((peer, i) => { peer.name = `测试设备${i + 1}`; });
      s.peers[1].routes = ["192.168.1.0/24"];
      s.self.ips.push("127.0.0.1");
    },
  });
  await page.goto(url);
  await ready(page);

  for (const tabName of ["概览", "设备", "设置", "核心", "诊断"]) {
    await clickTab(page, tabName);
    assertClean(await collectShadowTexts(page), `tab "${tabName}"`);
  }

  // Tooltip on Overview.
  await clickTab(page, "概览");
  await page.getByRole("button", { name: "更多说明", exact: true }).hover();
  await page.getByText(/加密虚拟局域网/).waitFor();
  assertClean(await collectShadowTexts(page), "overview tooltip");

  // Overview confirmation popovers (disable + logout + relogin).
  for (const btnName of ["停用", "退出登录", "重新登录"]) {
    await page.getByRole("button", { name: btnName, exact: true }).click();
    await page.getByRole("alertdialog").waitFor();
    assertClean(await collectShadowTexts(page), `overview popover "${btnName}"`);
    await page.keyboard.press("Escape");
    await page.getByRole("alertdialog").waitFor({ state: "hidden" });
  }

  // Settings validation errors + overlap/tailnet/port confirmation popovers.
  await clickTab(page, "设置");
  await page.locator("#setting-advertise-routes-input").fill("0.0.0.0/0");
  await page.getByRole("button", { name: "添加", exact: true }).click();
  await page.locator("#setting-hostname").fill("-bad");
  await page.getByRole("button", { name: "保存 设备名", exact: true }).click();
  await page.locator("#setting-port").fill("80");
  await page.getByRole("button", { name: "保存 监听端口", exact: true }).click();
  await page.locator("#setting-mirror").fill("http://bad.example.org/");
  await page.getByRole("button", { name: "保存 下载镜像", exact: true }).click();
  assertClean(await collectShadowTexts(page), "settings validation banners");

  await page.getByRole("switch", { name: "接受其他设备宣告的路由" }).click();
  await page.getByRole("alertdialog").waitFor();
  assertClean(await collectShadowTexts(page), "settings overlap popover");
  await page.keyboard.press("Escape");

  await page.getByRole("switch", { name: "允许 tailnet 访问路由器本机" }).click();
  await page.getByRole("alertdialog").waitFor();
  assertClean(await collectShadowTexts(page), "settings local_access tailnet popover");
  await page.keyboard.press("Escape");

  // Core confirmation popover.
  await clickTab(page, "核心");
  await page.getByRole("button", { name: "更新核心", exact: true }).click();
  await page.getByRole("alertdialog").waitFor();
  assertClean(await collectShadowTexts(page), "core update popover");
  await page.keyboard.press("Escape");

  // Diagnostics purge confirmation popover.
  await clickTab(page, "诊断");
  await page.getByRole("button", { name: "清除登录状态", exact: true }).click();
  await page.getByRole("alertdialog").waitFor();
  assertClean(await collectShadowTexts(page), "diagnostics purge popover");
  await page.keyboard.press("Escape");

  // Render both top-level error banners against a usable cached snapshot.
  await page.route("**/_api/", (route) => JSON.parse(route.request().postData()).method === "bifrost_status.sh"
    ? route.fulfill({ status: 503 })
    : route.fulfill({ json: { result: { ok: false, code: "busy" } } }));
  await page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));
  await page.getByRole("alert").getByText("请求失败（HTTP 503）。", { exact: true }).waitFor();
  await choose(page, "外观", "浅色");
  await page.getByRole("alert").getByText("另一个操作正在进行中，请稍候再试。", { exact: true }).waitFor();
  assertClean(await collectShadowTexts(page), "statusLoadError and uiError banners");

  // 2. All other 8 states.
  for (const state of [
    "disabled",
    "conflict",
    "core_missing",
    "starting",
    "needs_login_qr",
    "needs_approval",
    "stopped",
    "error",
  ]) {
    const ctx = await openPreview(t, { initialState: state, lang: "zh-CN", mode: "dark" });
    await ctx.page.goto(ctx.url);
    await ready(ctx.page);
    if (state === "needs_login_qr") {
      await ctx.page.getByRole("button", { name: /高级选项/ }).click();
      await ctx.page.getByLabel("控制服务器地址", { exact: true }).fill("http://192.0.2.10:8080");
      const key = ctx.page.getByLabel("预授权密钥", { exact: true });
      await key.fill("example-only");
      assert.equal(await key.getAttribute("type"), "password");
      // The collapsible panel contains only the server and password inputs.
      const panelId = await ctx.page.getByRole("button", { name: /高级选项/ }).getAttribute("aria-controls");
      assert.ok(panelId);
      assert.equal(await ctx.page.locator(`[id="${panelId}"]`).getByRole("button").count(), 0);
    }
    assertClean(await collectShadowTexts(ctx.page), `state "${state}"`);
    await ctx.page.close();
  }

  // 3. Login error states (expired + unsafe URL) and job error states (migrate rollback + core old_serial).
  const loginErr = await openPreview(t, {
    initialState: "needs_login",
    loginExpires: true,
    fastJobPoll: true,
    jobStepMs: 20,
    lang: "zh-CN",
    mode: "dark",
  });
  await loginErr.page.goto(loginErr.url);
  await ready(loginErr.page);
  await loginErr.page.getByRole("button", { name: "获取登录链接", exact: true }).click();
  await loginErr.page.getByText(/登录链接已过期/).waitFor();
  assertClean(await collectShadowTexts(loginErr.page), "login expired error state");

  const unsafeLogin = await openPreview(t, {
    initialState: "needs_login",
    lang: "zh-CN",
    mode: "dark",
    mutateStatus: (s) => {
      s.auth_url = "javascript:alert(1)";
    },
  });
  await unsafeLogin.page.goto(unsafeLogin.url);
  await ready(unsafeLogin.page);
  await unsafeLogin.page.getByRole("alert").waitFor();
  assertClean(await collectShadowTexts(unsafeLogin.page), "login unsafe auth_url banner");

  const migrateErr = await openPreview(t, {
    initialState: "conflict",
    migrateMode: "rollback",
    fastJobPoll: true,
    jobStepMs: 20,
    lang: "zh-CN",
    mode: "dark",
  });
  await migrateErr.page.goto(migrateErr.url);
  await ready(migrateErr.page);
  await migrateErr.page.getByRole("button", { name: "迁移并切换", exact: true }).first().click();
  await migrateErr.page.getByRole("alertdialog").getByRole("button", { name: "确认", exact: true }).click();
  await migrateErr.page.getByText(/已自动回滚到原版状态/).waitFor();
  assertClean(await collectShadowTexts(migrateErr.page), "migrate rollback error state");

  const coreErr = await openPreview(t, {
    initialState: "running",
    mutateStatus: (s) => { s.core.serial = 100; },
    fastJobPoll: true,
    jobStepMs: 20,
    lang: "zh-CN",
    mode: "dark",
  });
  await coreErr.page.goto(coreErr.url);
  await ready(coreErr.page);
  await clickTab(coreErr.page, "核心");
  await coreErr.page.getByRole("button", { name: "检查更新", exact: true }).click();
  await coreErr.page.getByRole("alert").waitFor();
  const notifications = coreErr.page.getByRole("region", { name: "通知" });
  await notifications.locator('button[aria-label="关闭"]').waitFor({ state: "attached" });
  assertClean(await collectShadowTexts(coreErr.page), "core old_serial error state");
  await choose(coreErr.page, "语言", "English");
  await coreErr.page.getByRole("region", { name: "Notifications" })
    .locator('button[aria-label="Close"]').waitFor({ state: "attached" });
});
