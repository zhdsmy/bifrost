// Adapted from po0fw asus-merlin (MIT), commit 0d9532d.
import assert from "node:assert/strict";
import { test } from "node:test";
import { openPreview, ready } from "./fixture.mjs";

test("mount: shadow DOM, asset budgets, select popup, and dialog backdrop/focus/Esc", async (t) => {
  const { page, url } = await openPreview(t, { initialState: "running", lang: "zh-CN", mode: "dark" });
  await page.goto(url);
  await ready(page);

  // Asset budgets and /res query-string rejection.
  const sizes = await page.evaluate(() => {
    const plugin = { js: 0, css: 0 };
    for (const entry of performance.getEntriesByType("resource")) {
      const path = new URL(entry.name).pathname;
      if (!path.startsWith("/res/bifrost-app.")) continue;
      if (path.endsWith(".js")) plugin.js += entry.decodedBodySize;
      if (path.endsWith(".css")) plugin.css += entry.decodedBodySize;
    }
    return plugin;
  });
  assert.ok(sizes.js > 0 && sizes.js <= 800_000, `JS size out of budget: ${JSON.stringify(sizes)}`);
  assert.ok(sizes.css > 0 && sizes.css <= 160_000, `CSS size out of budget: ${JSON.stringify(sizes)}`);
  t.diagnostic(`loaded asset sizes: ${JSON.stringify(sizes)}`);

  const scriptSrc = await page.locator('script[src^="/res/bifrost-app."]').getAttribute("src");
  assert.match(scriptSrc, /^\/res\/bifrost-app\.[0-9a-f]{20}\.js$/);
  for (const path of ["/res/icon-bifrost.png", scriptSrc, scriptSrc.replace(/\.js$/, ".css")]) {
    assert.equal((await page.request.get(new URL(path, url).href)).status(), 200);
    assert.equal((await page.request.get(new URL(path + "?v=1", url).href)).status(), 404);
  }

  // App lives inside #bifrost-app shadowRoot and keeps ASUS chrome untouched.
  const mountInfo = await page.evaluate(() => {
    const host = document.getElementById("bifrost-app");
    const shadow = host?.shadowRoot;
    const main = shadow?.querySelector("main");
    const theme = shadow?.querySelector("[data-mode]");
    return {
      hasShadow: Boolean(shadow),
      hasMain: Boolean(main),
      mode: theme?.getAttribute("data-mode"),
      colorScheme: theme ? getComputedStyle(theme).colorScheme : "",
      bannerText: document.getElementById("TopBanner")?.textContent?.trim(),
      skinAttr: document.body.getAttribute("skin"),
      bodyId: document.body.id,
    };
  });
  assert.equal(mountInfo.hasShadow, true);
  assert.equal(mountInfo.hasMain, true);
  assert.equal(mountInfo.mode, "dark");
  assert.equal(mountInfo.colorScheme, "dark");
  assert.equal(mountInfo.bannerText, "ASUSASUSWRT-Merlin");
  assert.equal(mountInfo.bodyId, "app");
  assert.equal(mountInfo.skinAttr, "ASUSWRT");

  // The firmware moves the page content after load (preview shell.js does the
  // same), which fires the stylesheet's load event again. Mount only once.
  // A moved <link> drops its sheet and loads again; wait for that load, then
  // give a second render time to appear.
  await page.waitForFunction(() => {
    const host = document.getElementById("bifrost-app");
    return host.closest(".preview-moved") && host.shadowRoot.querySelector("link").sheet;
  });
  await page.waitForTimeout(500);
  const mounts = await page.evaluate(() => {
    const host = document.getElementById("bifrost-app");
    return { moved: Boolean(host.closest(".preview-moved")), mains: host.shadowRoot.querySelectorAll("main").length };
  });
  assert.deepEqual(mounts, { moved: true, mains: 1 });

  // Select popup stays in shadow root with dark styling regardless of browser light media.
  const modePicker = page.getByRole("combobox", { name: "外观", exact: true });
  await modePicker.click();
  const list = page.getByRole("listbox");
  await list.getByRole("option").first().waitFor();
  assert.deepEqual(await list.getByRole("option").allTextContents(), ["深色", "浅色", "跟随系统"]);
  const popupStyle = () =>
    list.evaluate((el) => {
      const style = getComputedStyle(el.parentElement);
      return {
        inShadow: el.getRootNode() === document.getElementById("bifrost-app").shadowRoot,
        mode: style.colorScheme,
        surface: style.backgroundColor,
      };
    });
  const lightSystem = await popupStyle();
  assert.equal(lightSystem.inShadow, true);
  assert.equal(lightSystem.mode, "dark");
  assert.notEqual(lightSystem.surface, "rgba(0, 0, 0, 0)");
  await page.emulateMedia({ colorScheme: "dark" });
  assert.deepEqual(await popupStyle(), lightSystem);

  // Quick reopen + Escape leaves no stale overlay.
  await page.keyboard.press("Escape");
  await list.waitFor({ state: "hidden" });
  await modePicker.click();
  await page.keyboard.press("Escape");
  await list.waitFor({ state: "hidden" });

  // PLAN 13.2 confirmation popover (non-modal fallback): stays in shadow root, anchored near trigger,
  // no modal backdrop blocking shell chrome, closes cleanly on Escape even after quick reopen.
  const logoutBtn = page.getByRole("button", { name: "退出登录", exact: true });
  await logoutBtn.click();
  const confirm = page.getByRole("alertdialog");
  await confirm.waitFor();

  const popoverCheck = await confirm.evaluate((el) => {
    const shadow = document.getElementById("bifrost-app").shadowRoot;
    const trigger = Array.from(shadow.querySelectorAll("button")).find((b) => b.textContent?.trim() === "退出登录");
    const popupRect = el.getBoundingClientRect();
    const triggerRect = trigger.getBoundingClientRect();
    const bannerRect = document.getElementById("TopBanner").getBoundingClientRect();
    const style = getComputedStyle(el.parentElement);
    return {
      inShadow: el.getRootNode() === shadow,
      hasFixedBackdrop: shadow.querySelectorAll(".fixed.inset-0").length > 0,
      shellNotBlocked: document.getElementById("TopBanner").contains(
        document.elementFromPoint(bannerRect.left + 10, bannerRect.top + 10),
      ),
      nearTrigger: Math.abs(popupRect.top - triggerRect.bottom) < 80,
      withinViewport: popupRect.left >= 0 && popupRect.right <= window.innerWidth,
      mode: style.colorScheme,
    };
  });
  assert.equal(popoverCheck.inShadow, true);
  assert.equal(popoverCheck.hasFixedBackdrop, false);
  assert.equal(popoverCheck.shellNotBlocked, true);
  assert.equal(popoverCheck.nearTrigger, true);
  assert.equal(popoverCheck.withinViewport, true);
  assert.equal(popoverCheck.mode, "dark");

  await page.keyboard.press("Escape");
  await confirm.waitFor({ state: "hidden" });

  // Quick reopen + Escape leaves no stale overlay; shell button remains clickable.
  await logoutBtn.click();
  await confirm.waitFor();
  await page.keyboard.press("Escape");
  await confirm.waitFor({ state: "hidden" });

  await page.getByRole("button", { name: "返回软件中心", exact: true }).click();
  assert.equal(new URL(page.url()).pathname, "/Module_Softcenter.asp");
});

test("first paint waits for UI settings and initial status; actions stay disabled until init finishes", async (t) => {
  const { page, url } = await openPreview(t, { initialState: "running", lang: "en", mode: "light" });
  const uiGate = Promise.withResolvers();
  const snapGate = Promise.withResolvers();
  const refreshGate = Promise.withResolvers();

  await page.route("**/_api/bifrost", async (route) => {
    await uiGate.promise;
    await route.continue();
  });
  await page.route("**/_temp/bifrost_status.json", async (route) => {
    await snapGate.promise;
    await route.continue();
  });
  await page.route("**/_api/", async (route) => {
    const body = JSON.parse(route.request().postData() || "{}");
    if (body.method === "bifrost_status.sh") {
      await refreshGate.promise;
    }
    await route.continue();
  });

  const uiReq = page.waitForRequest("**/_api/bifrost");
  await page.goto(url);
  await uiReq;
  assert.equal(await page.locator("main").count(), 0);

  uiGate.resolve();
  await page.waitForTimeout(50);
  // Still waiting for initial status snapshot.
  assert.equal(await page.locator("main").count(), 0);

  snapGate.resolve();
  await page.locator("main").waitFor();
  // Rendered with the persisted English + light mode, while action buttons remain disabled until bifrost_status.sh finishes.
  assert.equal(await page.getByRole("combobox", { name: "Language", exact: true }).isDisabled(), true);
  assert.equal(await page.getByRole("button", { name: "Disable", exact: true }).isDisabled(), true);
  const mode = await page.evaluate(() =>
    document.getElementById("bifrost-app").shadowRoot.querySelector("[data-mode]").getAttribute("data-mode"),
  );
  assert.equal(mode, "light");

  refreshGate.resolve();
  await ready(page);
  assert.equal(await page.getByRole("button", { name: "Disable", exact: true }).isEnabled(), true);
});

test("unsupported browser shows bilingual warning without mounting shadow DOM", async (t) => {
  const { page, url } = await openPreview(t);
  await page.addInitScript(() => {
    const orig = CSS.supports.bind(CSS);
    CSS.supports = (prop, val) => {
      if (val && String(val).includes("light-dark")) return false;
      return orig(prop, val);
    };
  });
  await page.goto(url);
  await page.locator("#bifrost-app").getByText("当前浏览器版本过低").waitFor();
  await page.locator("#bifrost-app").getByText("Unsupported browser version").waitFor();
  const hasShadow = await page.evaluate(() => Boolean(document.getElementById("bifrost-app").shadowRoot));
  assert.equal(hasShadow, false);
});

test("stylesheet failure shows bilingual fallback message", async (t) => {
  const { page, url } = await openPreview(t);
  await page.route("**/res/bifrost-app.*.css", (route) => route.abort());
  await page.goto(url);
  await page.getByText("样式加载失败，请刷新。 / Failed to load styles, please refresh.", { exact: true }).waitFor();
});
