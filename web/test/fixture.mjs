// Adapted from po0fw asus-merlin (MIT), commit 0d9532d.
import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { chromium } from "playwright-core";
import { createPreviewServer } from "../preview/server.mjs";

export async function openPreview(t, options = {}) {
  const {
    viewport = { width: 1280, height: 900 },
    colorScheme = "light",
    fastJobPoll = false,
    insecureHttp = false,
    ...serverOptions
  } = options;

  const server = createPreviewServer(serverOptions);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const host = insecureHttp ? "bifrost.test" : "127.0.0.1";
  const origin = `http://${host}:${server.address().port}`;
  // Hooks run in registration order and are not covered by the test timeout.
  // Bound each one, and do not let server.close wait for the browser's sockets.
  t.after(() => new Promise((resolve) => {
    server.close(() => resolve());
    server.closeAllConnections();
  }), { timeout: 10000 });

  const browser = await chromium.launch();
  t.after(() => browser.close(), { timeout: 10000 });

  const context = await browser.newContext({
    viewport,
    colorScheme,
    reducedMotion: "reduce",
  });
  if (insecureHttp) {
    // Keep a non-trustworthy HTTP origin in the browser, with all I/O on loopback.
    await context.route(`${origin}/**`, async (route) => {
      const localUrl = new URL(route.request().url());
      localUrl.hostname = "127.0.0.1";
      await route.fulfill({ response: await route.fetch({ url: localUrl.href }) });
    });
  }
  const page = await context.newPage();
  page.setDefaultTimeout(8000);

  if (fastJobPoll) {
    await page.addInitScript(() => {
      const nativeSetTimeout = window.setTimeout;
      window.setTimeout = (fn, delay, ...args) => {
        if (delay === 2000) delay = 25;
        return nativeSetTimeout(fn, delay, ...args);
      };
    });
  }

  const errors = [];
  const external = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("request", (r) => {
    const parsed = new URL(r.url());
    if (parsed.protocol.startsWith("http") && parsed.origin !== origin) {
      external.push(r.url());
    }
  });
  t.after(() => {
    assert.deepEqual(errors, [], `unexpected page errors: ${errors.join("; ")}`);
    assert.deepEqual(external, [], `unexpected external requests: ${external.join(", ")}`);
  });

  return { browser, context, page, server, origin, url: `${origin}/Module_bifrost.asp` };
}

export async function ready(page) {
  await page.locator("#bifrost-ui-lang:not([disabled])").waitFor();
}

export async function choose(page, label, option) {
  await page.getByRole("combobox", { name: label, exact: true }).click();
  await page.getByRole("option", { name: option, exact: true }).click();
}

export async function clickTab(page, name) {
  await page.getByRole("tab", { name, exact: true }).click();
}

export async function shot(page, dir, name, options = {}) {
  await mkdir(dir, { recursive: true });
  await page.screenshot({
    path: join(dir, name + ".png"),
    animations: "disabled",
    ...options,
  });
}
