import type { JobState, PageState, StatusData, UpdateJobData } from "./types";
import type { MessageKey } from "../i18n/zh-CN";

export type StateBadgeVariant = "success" | "warning" | "error" | "info" | "secondary";
export type PrimaryActionKind = "enable" | "disable" | "connect" | "goto_core" | "migrate";

export interface StatePresentation {
  badgeVariant: StateBadgeVariant;
  primaryAction: PrimaryActionKind;
  secondaryAction?: "disable";
  showAuthActions: boolean;
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
        showAuthActions: true,
        showLoginView: false,
        showMigrateCard: false,
        showOverviewDetails: true,
      };
    case "disabled":
      return {
        badgeVariant: "secondary",
        primaryAction: "enable",
        showAuthActions: false,
        showLoginView: false,
        showMigrateCard: origPresent,
        showOverviewDetails: false,
      };
    case "conflict":
      return {
        badgeVariant: "warning",
        primaryAction: "migrate",
        showAuthActions: false,
        showLoginView: false,
        showMigrateCard: true,
        showOverviewDetails: false,
      };
    case "core_missing":
      return {
        badgeVariant: "error",
        primaryAction: "goto_core",
        showAuthActions: false,
        showLoginView: false,
        showMigrateCard: false,
        showOverviewDetails: false,
      };
    case "starting":
      return {
        badgeVariant: "info",
        primaryAction: "disable",
        showAuthActions: false,
        showLoginView: false,
        showMigrateCard: false,
        showOverviewDetails: false,
      };
    case "needs_login":
      return {
        badgeVariant: "warning",
        primaryAction: "disable",
        showAuthActions: false,
        showLoginView: true,
        showMigrateCard: origPresent,
        showOverviewDetails: false,
      };
    case "needs_approval":
      return {
        badgeVariant: "warning",
        primaryAction: "disable",
        showAuthActions: false,
        showLoginView: false,
        showMigrateCard: false,
        showOverviewDetails: true,
      };
    case "stopped":
      return {
        badgeVariant: "secondary",
        primaryAction: "connect",
        secondaryAction: "disable",
        showAuthActions: false,
        showLoginView: false,
        showMigrateCard: false,
        showOverviewDetails: true,
      };
    case "error":
      return {
        badgeVariant: "error",
        primaryAction: "enable",
        showAuthActions: false,
        showLoginView: false,
        showMigrateCard: origPresent,
        showOverviewDetails: false,
      };
  }
}

export function isCoreUpToDate(status: StatusData, check?: JobState<UpdateJobData>): boolean {
  return !status.core.update && check?.ok === true && !check.running &&
    check.data.action === "check" && check.data.up_to_date === true;
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

export function formatDateTime(unixSec: number): string {
  if (!unixSec || unixSec <= 0) return "—";
  const d = new Date(unixSec * 1000);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

export function formatIsoDate(iso: string): string {
  if (!iso) return "—";
  const ts = Date.parse(iso);
  if (Number.isNaN(ts)) return iso;
  const d = new Date(ts);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export function formatHandshakeAge(
  unixSec: number,
  nowSec: number,
  t: (key: MessageKey, vars?: Record<string, string | number>) => string,
): string {
  if (!unixSec || unixSec <= 0) return t("time.never");
  const diff = Math.max(0, Math.floor(nowSec - unixSec));
  if (diff < 60) return t("time.secondsAgo", { n: diff });
  if (diff < 3600) return t("time.minutesAgo", { n: Math.floor(diff / 60) });
  if (diff < 86400) return t("time.hoursAgo", { n: Math.floor(diff / 3600) });
  return t("time.daysAgo", { n: Math.floor(diff / 86400) });
}

export const CORE_VERIFY_COMMAND = "openssl dgst -sha256 /koolshare/bifrost/bin/bifrostd";
