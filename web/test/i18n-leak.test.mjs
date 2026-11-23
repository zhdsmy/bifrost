import assert from "node:assert/strict";
import { test } from "node:test";
import { clickTab, openPreview, ready } from "./fixture.mjs";

// Proper nouns and technical identifiers intentionally kept in English in Chinese UI (PLAN 13.9).
const ALLOWED_TOKENS = new Set([
  "bifrost", "tailscale", "tailscaled", "tailnet", "magicdns", "derp",
  "wireguard", "headscale", "ipv4", "ipv6", "cidr", "udp", "tcp", "nat",
  "wan", "lan", "jffs", "usb2jffs", "ssh", "go", "upx", "ap", "ping",
  "english", "macos", "linux", "ios", "windows", "arm", "arm64", "aarch64",
  "armv7l", "dnsmasq", "conf", "dir", "dns", "http", "https", "upnp",
  "openssl", "dgst", "sha256", "koolshare", "bin", "bifrostd", "dev", "net",
  "tun", "extra", "small", "cgo", "enabled", "trimpath", "ldflags",
  "aws", "bird", "tap", "kube", "completion", "scripts", "systray", "tpm",
  "debugeventbus", "syspolicy", "capture", "taildrop", "clientupdate",
  "webclient", "drive", "desktop", "sessions", "webbrowser", "networkmanager",
  "resolved", "dbus", "synology", "sdnotify", "flashappliance", "cloud",
  "ms", "b", "kb", "mb", "gb", "tb", "r1", "r2", "s", "w",
  // Fixture data tokens (hostnames, DERP region codes, example domains)
  "home", "router", "example", "ts", "workstation", "office", "gw", "relay",
  "box", "tablet", "tok", "hkg", "sin", "org", "a", "demo", "auth", "session",
  "rx", "tx",
]);

function findUntranslatedEnglish(texts) {
  const leaks = [];
  for (const raw of texts) {
    // Strip URLs, file paths, flags, and numbers before checking word runs.
    const cleaned = raw
      .replace(/https?:\/\/\S+/g, " ")
      .replace(/\/[A-Za-z0-9._/-]+/g, " ")
      .replace(/--?[A-Za-z0-9_-]+/g, " ");
    // Look for runs of 2+ Latin words (e.g. "Click to reveal", "Copy to clipboard").
    const phrases = cleaned.match(/[A-Za-z]{2,}(?:\s+[A-Za-z]{2,})+/g) || [];
    for (const phrase of phrases) {
      const words = phrase.toLowerCase().split(/\s+/);
      const unknown = words.filter((w) => !ALLOWED_TOKENS.has(w));
      if (unknown.length > 0) {
        leaks.push({ phrase, raw: raw.slice(0, 120) });
      }
    }
  }
  return leaks;
}

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
      // Skip raw untranslated log output and raw daemon health strings (PLAN 13.9).
      if (el.closest('pre[role="log"], code, [data-raw-health]')) continue;
      const style = getComputedStyle(el);
      if (style.display === "none" || style.visibility === "hidden") continue;
      const text = node.textContent?.trim();
      if (text) results.push(text);
    }
    return results;
  });
}

test("i18n leak check: Chinese UI has no untranslated English sentences across all tabs and states", async (t) => {
  const { page, url } = await openPreview(t, { initialState: "running", lang: "zh-CN", mode: "dark" });
  await page.goto(url);
  await ready(page);

  for (const tabName of ["概览", "设备", "设置", "核心", "诊断"]) {
    await clickTab(page, tabName);
    const texts = await collectShadowTexts(page);
    const leaks = findUntranslatedEnglish(texts);
    assert.deepEqual(leaks, [], `Untranslated English found on tab "${tabName}": ${JSON.stringify(leaks)}`);
  }

  for (const state of ["disabled", "conflict", "core_missing", "starting", "needs_login_qr", "needs_approval", "stopped", "error"]) {
    const ctx = await openPreview(t, { initialState: state, lang: "zh-CN", mode: "dark" });
    await ctx.page.goto(ctx.url);
    await ready(ctx.page);
    if (state === "needs_login_qr") {
      await ctx.page.getByRole("button", { name: /高级选项/ }).click();
    }
    const texts = await collectShadowTexts(ctx.page);
    const leaks = findUntranslatedEnglish(texts);
    assert.deepEqual(leaks, [], `Untranslated English found in state "${state}": ${JSON.stringify(leaks)}`);
    await ctx.page.close();
  }
});
