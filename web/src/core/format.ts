import type { PageState, StatusData, UiLang } from "./types";

export type StateBadgeVariant = "success" | "warning" | "error" | "info" | "secondary";
export type PrimaryActionKind = "enable" | "disable" | "connect" | "login" | "goto_core" | "migrate" | "none";

export interface StatePresentation {
  badgeVariant: StateBadgeVariant;
  primaryAction: PrimaryActionKind;
  showLoginView: boolean;
  showMigrateCard: boolean;
  showOverviewDetails: boolean;
}

export function describeState(status: StatusData): StatePresentation {
  const s: PageState = status.state;
  const origPresent = status.conflict.original_installed || status.conflict.original_running;
  switch (s) {
    case "running":
      return {
        badgeVariant: "success",
        primaryAction: "disable",
        showLoginView: false,
        showMigrateCard: false,
        showOverviewDetails: true,
      };
    case "disabled":
      return {
        badgeVariant: "secondary",
        primaryAction: "enable",
        showLoginView: false,
        showMigrateCard: origPresent,
        showOverviewDetails: false,
      };
    case "conflict":
      return {
        badgeVariant: "warning",
        primaryAction: "migrate",
        showLoginView: false,
        showMigrateCard: true,
        showOverviewDetails: false,
      };
    case "core_missing":
      return {
        badgeVariant: "error",
        primaryAction: "goto_core",
        showLoginView: false,
        showMigrateCard: false,
        showOverviewDetails: false,
      };
    case "starting":
      return {
        badgeVariant: "info",
        primaryAction: "disable",
        showLoginView: false,
        showMigrateCard: false,
        showOverviewDetails: false,
      };
    case "needs_login":
      return {
        badgeVariant: "warning",
        primaryAction: "login",
        showLoginView: true,
        showMigrateCard: origPresent,
        showOverviewDetails: false,
      };
    case "needs_approval":
      return {
        badgeVariant: "warning",
        primaryAction: "disable",
        showLoginView: false,
        showMigrateCard: false,
        showOverviewDetails: true,
      };
    case "stopped":
      return {
        badgeVariant: "secondary",
        primaryAction: "connect",
        showLoginView: false,
        showMigrateCard: false,
        showOverviewDetails: true,
      };
    case "error":
      return {
        badgeVariant: "error",
        primaryAction: "enable",
        showLoginView: false,
        showMigrateCard: origPresent,
        showOverviewDetails: false,
      };
  }
}

export interface KeyExpiryInfo {
  iso: string;
  daysLeft: number;
  expiringSoon: boolean;
  expired: boolean;
}

export function analyzeKeyExpiry(iso: string, nowMs = Date.now()): KeyExpiryInfo | null {
  if (!iso) return null;
  const ts = Date.parse(iso);
  if (Number.isNaN(ts)) return null;
  const daysLeft = Math.floor((ts - nowMs) / 86_400_000);
  return {
    iso,
    daysLeft,
    expired: ts <= nowMs,
    expiringSoon: ts > nowMs && daysLeft < 14,
  };
}

export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "0 B";
  if (bytes < 1024) return `${Math.round(bytes)} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let idx = 0;
  while (value >= 1024 && idx < units.length - 1) {
    value /= 1024;
    idx++;
  }
  return `${value >= 100 ? value.toFixed(0) : value.toFixed(1)} ${units[idx]}`;
}

export function formatKb(kb: number): string {
  return formatBytes(kb * 1024);
}

export function formatDateTime(unixSec: number, lang: UiLang): string {
  if (!unixSec || unixSec <= 0) return "—";
  const d = new Date(unixSec * 1000);
  const pad = (n: number) => String(n).padStart(2, "0");
  const date = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  const time = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  return lang === "zh-CN" ? `${date} ${time}` : `${date} ${time}`;
}

export function formatIsoDate(iso: string): string {
  if (!iso) return "—";
  const ts = Date.parse(iso);
  if (Number.isNaN(ts)) return iso;
  const d = new Date(ts);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export function formatHandshakeAge(unixSec: number, nowSec: number, lang: UiLang): string {
  if (!unixSec || unixSec <= 0) return lang === "zh-CN" ? "无" : "Never";
  const diff = Math.max(0, Math.floor(nowSec - unixSec));
  if (diff < 60) return lang === "zh-CN" ? `${diff} 秒前` : `${diff}s ago`;
  if (diff < 3600) return lang === "zh-CN" ? `${Math.floor(diff / 60)} 分钟前` : `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return lang === "zh-CN" ? `${Math.floor(diff / 3600)} 小时前` : `${Math.floor(diff / 3600)}h ago`;
  return lang === "zh-CN" ? `${Math.floor(diff / 86400)} 天前` : `${Math.floor(diff / 86400)}d ago`;
}

export const CORE_RECIPE_SUMMARY = {
  goVersion: "1.27.4",
  flags: "CGO_ENABLED=0 -trimpath -ldflags \"-s -w\"",
  omitCount: 25,
  omit: [
    "aws", "bird", "tap", "kube", "completion", "completion_scripts",
    "systray", "tpm", "debugeventbus", "syspolicy", "capture", "ssh",
    "taildrop", "clientupdate", "webclient", "drive", "desktop_sessions",
    "webbrowser", "networkmanager", "resolved", "dbus", "synology",
    "sdnotify", "flashappliance", "cloud",
  ],
  verifyCommand: "openssl dgst -sha256 /koolshare/bifrost/bin/bifrostd",
} as const;
