// Adapted from po0fw asus-merlin (MIT), commit 0d9532d.
import assert from "node:assert/strict";
import { test } from "node:test";
import { choose, openPreview, ready } from "./fixture.mjs";

test("language and appearance switches emit a single ui request and persist across browser contexts", async (t) => {
  const { browser, page, url } = await openPreview(t, { initialState: "running", lang: "zh-CN", mode: "dark" });
  await page.goto(url);
  await ready(page);

  // Switch appearance to light -> single POST /_api/ with ui zh-CN light.
  const modeRelease = Promise.withResolvers();
  await page.route("**/_api/", async (route) => {
    await modeRelease.promise;
    await route.continue();
  }, { times: 1 });

  const modeRequests = [];
  const onReq = (r) => { if (r.method() === "POST") modeRequests.push(r); };
  page.on("request", onReq);

  await choose(page, "外观", "浅色");
  const modeAfterClick = await page.evaluate(() =>
    document.getElementById("bifrost-app").shadowRoot.querySelector("[data-mode]").getAttribute("data-mode"),
  );
  assert.equal(modeAfterClick, "light");
  assert.equal(await page.getByRole("combobox", { name: "外观", exact: true }).isDisabled(), true);

  modeRelease.resolve();
  await ready(page);
  page.off("request", onReq);

  assert.equal(modeRequests.length, 1);
  const modePayload = JSON.parse(modeRequests[0].postData());
  assert.equal(modePayload.method, "bifrost_config.sh");
  assert.deepEqual(modePayload.params, ["ui", "zh-CN", "light"]);
  assert.deepEqual(modePayload.fields, {});

  // Switch language to English -> single POST /_api/ with ui en light.
  const langRequests = [];
  const onLangReq = (r) => { if (r.method() === "POST") langRequests.push(r); };
  page.on("request", onLangReq);

  await choose(page, "语言", "English");
  await page.getByRole("tab", { name: "Overview", exact: true }).waitFor();
  await ready(page);
  page.off("request", onLangReq);

  assert.equal(langRequests.length, 1);
  const langPayload = JSON.parse(langRequests[0].postData());
  assert.equal(langPayload.method, "bifrost_config.sh");
  assert.deepEqual(langPayload.params, ["ui", "en", "light"]);
  assert.deepEqual(langPayload.fields, {});

  // New browser context reads persisted en + light from router dbus.
  const freshCtx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  try {
    const freshPage = await freshCtx.newPage();
    await freshPage.goto(url);
    await ready(freshPage);
    await freshPage.getByRole("tab", { name: "Overview", exact: true }).waitFor();
    const freshMode = await freshPage.evaluate(() =>
      document.getElementById("bifrost-app").shadowRoot.querySelector("[data-mode]").getAttribute("data-mode"),
    );
    assert.equal(freshMode, "light");
  } finally {
    await freshCtx.close();
  }
});

test("failed ui save reverts immediately and allows retry", async (t) => {
  const { page, url } = await openPreview(t, { initialState: "running", lang: "zh-CN", mode: "dark" });
  await page.goto(url);
  await ready(page);

  for (const [reply, expectedText] of [
    [{ status: 503, body: "" }, "请求失败（HTTP 503）。"],
    [{ status: 200, body: "not-json" }, "软件中心返回的数据格式无效。"],
    [{ status: 200, json: { id: 1, result: '{"ok":false,"code":"busy"}' } }, "另一个操作正在进行中，请稍候再试。"],
  ]) {
    await page.route("**/_api/", (r) => r.fulfill(reply), { times: 1 });
    await choose(page, "外观", "浅色");
    await page.getByRole("alert").getByText(expectedText, { exact: true }).waitFor();
    const revertedMode = await page.evaluate(() =>
      document.getElementById("bifrost-app").shadowRoot.querySelector("[data-mode]").getAttribute("data-mode"),
    );
    assert.equal(revertedMode, "dark");
    await ready(page);
  }

  // Retry succeeds and clears alert.
  await choose(page, "外观", "浅色");
  await ready(page);
  const finalMode = await page.evaluate(() =>
    document.getElementById("bifrost-app").shadowRoot.querySelector("[data-mode]").getAttribute("data-mode"),
  );
  assert.equal(finalMode, "light");
});

test("system appearance tracks prefers-color-scheme and unknown dbus values fall back without writing", async (t) => {
  const { page, url } = await openPreview(t, {
    initialState: "running",
    lang: "fr-FR",
    mode: "sepia",
    colorScheme: "light",
  });
  const uiWrites = [];
  page.on("request", (r) => {
    if (r.method() === "POST" && r.url().endsWith("/_api/")) {
      const body = JSON.parse(r.postData() || "{}");
      if (body.method === "bifrost_config.sh") uiWrites.push(body);
    }
  });

  await page.goto(url);
  await ready(page);
  await page.getByRole("tab", { name: "概览", exact: true }).waitFor();
  const fallbackMode = await page.evaluate(() =>
    document.getElementById("bifrost-app").shadowRoot.querySelector("[data-mode]").getAttribute("data-mode"),
  );
  assert.equal(fallbackMode, "dark");
  assert.deepEqual(uiWrites, []);

  // Switch to system mode -> follows light then dark media emulation.
  await choose(page, "外观", "跟随系统");
  await ready(page);
  const readMode = () =>
    page.evaluate(() =>
      document.getElementById("bifrost-app").shadowRoot.querySelector("[data-mode]").getAttribute("data-mode"),
    );
  assert.equal(await readMode(), "light");
  await page.emulateMedia({ colorScheme: "dark" });
  await page.waitForTimeout(50);
  assert.equal(await readMode(), "dark");
});
