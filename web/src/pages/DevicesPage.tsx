import { useMemo, useRef, useState } from "react";
import { Badge } from "@cloudflare/kumo/components/badge";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { Empty } from "@cloudflare/kumo/components/empty";
import { Input } from "@cloudflare/kumo/components/input";
import { Table } from "@cloudflare/kumo/components/table";
import { useApp } from "../app/context";
import { CopyInline } from "../components/CopyInline";
import { SectionCard } from "../components/SectionCard";
import { api } from "../core/api";
import { formatBytes, formatHandshakeAge } from "../core/format";
import type { PeerInfo, PingResult, UiLang } from "../core/types";

const MAX_RENDERED_PEERS = 200;

// Column widths in px, cell padding included. The routes column also takes the
// space left over, so its width is a minimum. The action column is fixed and
// widens while a ping result or error is shown.
const COLUMN_LABELS = {
  name: "devices.col.name",
  ip: "devices.col.ip",
  os: "devices.col.os",
  status: "devices.col.status",
  path: "devices.col.path",
  handshake: "devices.col.handshake",
  traffic: "devices.col.traffic",
  routes: "devices.col.routes",
} as const;
type ColumnId = keyof typeof COLUMN_LABELS;
const COLUMNS = Object.keys(COLUMN_LABELS) as ColumnId[];
type ColumnWidths = Record<ColumnId, number>;
const DEFAULT_WIDTHS: Record<UiLang, ColumnWidths> = {
  "zh-CN": { name: 124, ip: 144, os: 60, status: 72, path: 116, handshake: 68, traffic: 80, routes: 136 },
  en: { name: 116, ip: 144, os: 60, status: 84, path: 106, handshake: 84, traffic: 78, routes: 136 },
};
const ACTION_WIDTH = 72;
const ACTION_WIDTH_WITH_RESULT = 136;
const MIN_WIDTH = 48;
const MAX_WIDTH = 480;
const KEY_STEP = 16;
// Kept per browser, not in dbus: the right widths depend on the screen.
const WIDTHS_KEY = "bifrost.devices.columnWidths.v1";

function clampWidth(width: number) {
  return Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, Math.round(width)));
}

function loadCustomWidths(): Partial<ColumnWidths> {
  const widths: Partial<ColumnWidths> = {};
  try {
    const saved: unknown = JSON.parse(localStorage.getItem(WIDTHS_KEY) ?? "{}");
    if (saved && typeof saved === "object") {
      for (const id of COLUMNS) {
        const width = (saved as Record<string, unknown>)[id];
        if (typeof width === "number" && Number.isFinite(width)) widths[id] = clampWidth(width);
      }
    }
  } catch {
    // Unreadable storage or bad JSON: use the defaults.
  }
  return widths;
}

function saveCustomWidths(widths: Partial<ColumnWidths>) {
  try {
    if (Object.keys(widths).length > 0) localStorage.setItem(WIDTHS_KEY, JSON.stringify(widths));
    else localStorage.removeItem(WIDTHS_KEY);
  } catch {
    // Storage is off: the widths last until the page reloads.
  }
}

// Drag the column edge, or focus it and use the arrow keys. Double-click resets.
function ColumnResizeHandle({
  label,
  width,
  onResize,
  onReset,
}: {
  label: string;
  width: number;
  onResize: (width: number) => void;
  onReset: () => void;
}) {
  const drag = useRef<{ x: number; width: number } | null>(null);
  return (
    <div
      role="separator"
      aria-orientation="vertical"
      aria-label={label}
      aria-valuenow={width}
      aria-valuemin={MIN_WIDTH}
      aria-valuemax={MAX_WIDTH}
      tabIndex={0}
      className="group/resize absolute inset-y-0 -right-1.5 z-1 flex w-3 cursor-col-resize touch-none items-center justify-center outline-none select-none"
      onPointerDown={(e) => {
        if (e.button !== 0) return;
        e.currentTarget.setPointerCapture(e.pointerId);
        // Start from the drawn width: the routes column can be wider than its setting.
        const cell = e.currentTarget.parentElement;
        drag.current = { x: e.clientX, width: cell ? cell.getBoundingClientRect().width : width };
      }}
      onPointerMove={(e) => {
        if (drag.current) onResize(drag.current.width + e.clientX - drag.current.x);
      }}
      onPointerUp={() => {
        drag.current = null;
      }}
      onPointerCancel={() => {
        drag.current = null;
      }}
      onDoubleClick={onReset}
      onKeyDown={(e) => {
        const step = e.key === "ArrowRight" ? KEY_STEP : e.key === "ArrowLeft" ? -KEY_STEP : 0;
        if (!step) return;
        e.preventDefault();
        onResize(width + step);
      }}
    >
      <span className="h-4 w-px rounded-full bg-kumo-line group-hover/resize:w-0.5 group-hover/resize:bg-kumo-brand group-focus-visible/resize:w-0.5 group-focus-visible/resize:bg-kumo-brand" />
    </div>
  );
}

interface RowPingState {
  loading: boolean;
  result?: PingResult;
  error?: string;
}

export function DevicesPage() {
  const { status, t, tError, initializing, lang } = useApp();
  const [filter, setFilter] = useState("");
  const [pings, setPings] = useState<Record<string, RowPingState>>({});
  const [customWidths, setCustomWidths] = useState(loadCustomWidths);
  const widths: ColumnWidths = { ...DEFAULT_WIDTHS[lang], ...customWidths };
  const actionWidth = Object.values(pings).some((p) => p.result || p.error)
    ? ACTION_WIDTH_WITH_RESULT
    : ACTION_WIDTH;
  const tableWidth = COLUMNS.reduce((sum, id) => sum + widths[id], actionWidth);

  const peers = status?.peers ?? [];
  const onlineCount = useMemo(() => peers.filter((p) => p.online).length, [peers]);

  // Preserve the contract §6.1 peer ordering (online first, then by name) without re-sorting.
  const filtered = useMemo(() => {
    const q = filter.trim().toLowerCase();
    if (!q) return peers;
    return peers.filter(
      (p) =>
        p.name.toLowerCase().includes(q) ||
        p.dns_name.toLowerCase().includes(q) ||
        p.ip.toLowerCase().includes(q) ||
        p.ips.some((ip) => ip.toLowerCase().includes(q)),
    );
  }, [peers, filter]);

  const visible = filtered.slice(0, MAX_RENDERED_PEERS);
  const truncated = filtered.length > MAX_RENDERED_PEERS;
  const nowSec = status?.time ?? Math.floor(Date.now() / 1000);

  function renderPath(path: PeerInfo["path"], relay: string) {
    if (path === "direct") return t("devices.path.direct");
    if (path === "peer-relay") return t("devices.path.peerRelay");
    if (relay) {
      const [prefix, suffix = ""] = t("devices.path.derpRegion", { relay: "\0" }).split("\0");
      return (
        <span>
          {prefix}
          <span data-raw-value="true">{relay}</span>
          {suffix}
        </span>
      );
    }
    return t("devices.path.derp");
  }

  function updateCustomWidths(next: Partial<ColumnWidths>) {
    setCustomWidths(next);
    saveCustomWidths(next);
  }

  function resetColumn(id: ColumnId) {
    const next = { ...customWidths };
    delete next[id];
    updateCustomWidths(next);
  }

  async function handlePing(ip: string) {
    setPings((prev) => ({ ...prev, [ip]: { loading: true } }));
    try {
      const result = await api.ping(ip);
      setPings((prev) => ({ ...prev, [ip]: { loading: false, result } }));
    } catch (err) {
      setPings((prev) => ({ ...prev, [ip]: { loading: false, error: tError(err) } }));
    }
  }

  return (
    <div className="grid gap-4">
      <SectionCard
        title={t("devices.title")}
        description={t("devices.count", { total: peers.length, online: onlineCount })}
      >
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="min-w-0 max-w-sm flex-1">
            <Input
              id="devices-filter"
              aria-label={t("devices.filterPlaceholder")}
              placeholder={t("devices.filterPlaceholder")}
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
              autoComplete="off"
              spellCheck={false}
            />
          </div>
          {Object.keys(customWidths).length > 0 && (
            <Button size="sm" variant="ghost" onClick={() => updateCustomWidths({})}>
              {t("devices.resetColumns")}
            </Button>
          )}
        </div>

        {truncated && (
          <Banner
            variant="secondary"
            size="sm"
            description={t("devices.limitNotice", {
              shown: MAX_RENDERED_PEERS,
              total: filtered.length,
            })}
          />
        )}

        {peers.length === 0 ? (
          <Empty title={t("devices.emptyTitle")} description={t("devices.emptyDesc")} />
        ) : visible.length === 0 ? (
          <Empty title={t("devices.emptyFilterTitle")} description={t("devices.emptyFilterDesc")} />
        ) : (
          <div className="overflow-x-auto rounded-lg border border-kumo-line">
            <Table
              layout="fixed"
              className="text-xs [&_td]:p-2 [&_th]:p-2 [&_th]:text-xs"
              style={{ width: `max(100%, ${tableWidth}px)` }}
            >
              <colgroup>
                {COLUMNS.map((id) => (
                  <col key={id} style={id === "routes" ? undefined : { width: widths[id] }} />
                ))}
                <col style={{ width: actionWidth }} />
              </colgroup>
              <Table.Header>
                <Table.Row>
                  {COLUMNS.map((id) => {
                    const label = t(COLUMN_LABELS[id]);
                    return (
                      <Table.Head key={id} className="whitespace-nowrap">
                        <span className="block truncate" title={label}>
                          {label}
                        </span>
                        <ColumnResizeHandle
                          label={t("devices.resizeColumn", { column: label })}
                          width={widths[id]}
                          onResize={(width) => updateCustomWidths({ ...customWidths, [id]: clampWidth(width) })}
                          onReset={() => resetColumn(id)}
                        />
                      </Table.Head>
                    );
                  })}
                  <Table.Head className="whitespace-nowrap" sticky="right">
                    {t("devices.col.action")}
                  </Table.Head>
                </Table.Row>
              </Table.Header>
              <Table.Body>
                {visible.map((peer) => {
                  const ping = pings[peer.ip];
                  return (
                    <Table.Row key={peer.ip} className="group">
                      <Table.Cell className="overflow-hidden">
                        <div className="grid min-w-0 gap-0.5">
                          <span
                            data-raw-value="true"
                            className="truncate font-medium text-kumo-strong"
                            title={peer.name}
                          >
                            {peer.name}
                          </span>
                          {peer.dns_name && (
                            <span
                              data-raw-value="true"
                              className="truncate text-xs text-kumo-subtle"
                              title={peer.dns_name}
                            >
                              {peer.dns_name}
                            </span>
                          )}
                        </div>
                      </Table.Cell>
                      <Table.Cell className="overflow-hidden whitespace-nowrap">
                        <CopyInline value={peer.ip} small />
                      </Table.Cell>
                      <Table.Cell className="overflow-hidden whitespace-nowrap">
                        <span data-raw-value="true" className="block truncate">
                          {peer.os || "—"}
                        </span>
                      </Table.Cell>
                      <Table.Cell className="overflow-hidden whitespace-nowrap">
                        <Badge appearance="dot" variant={peer.online ? "success" : "secondary"}>
                          {peer.online ? t("devices.status.online") : t("devices.status.offline")}
                        </Badge>
                      </Table.Cell>
                      <Table.Cell className="overflow-hidden whitespace-nowrap">
                        <Badge variant={peer.path === "direct" ? "info" : "outline"} className="border-kumo-line">
                          {renderPath(peer.path, peer.relay)}
                        </Badge>
                      </Table.Cell>
                      <Table.Cell className="overflow-hidden whitespace-nowrap tabular-nums">
                        {formatHandshakeAge(peer.last_handshake, nowSec, t)}
                      </Table.Cell>
                      <Table.Cell className="overflow-hidden whitespace-nowrap tabular-nums">
                        <div className="grid leading-tight">
                          <span>↓ {formatBytes(peer.rx)}</span>
                          <span className="text-kumo-subtle">↑ {formatBytes(peer.tx)}</span>
                        </div>
                      </Table.Cell>
                      <Table.Cell className="overflow-hidden">
                        <div className="flex flex-wrap gap-1">
                          {peer.exit_node_option && (
                            <Badge variant="info">{t("devices.exitNodeBadge")}</Badge>
                          )}
                          {peer.routes.map((cidr) => (
                            <Badge key={cidr} variant="outline" className="border-kumo-line">
                              {cidr}
                            </Badge>
                          ))}
                          {!peer.exit_node_option && peer.routes.length === 0 && (
                            <span className="text-kumo-subtle">—</span>
                          )}
                        </div>
                      </Table.Cell>
                      <Table.Cell sticky="right">
                        <div className="grid gap-1">
                          <Button
                            size="sm"
                            variant="secondary"
                            loading={ping?.loading}
                            disabled={initializing || ping?.loading}
                            aria-label={`${t("devices.ping")} ${peer.name}`}
                            onClick={() => {
                              void handlePing(peer.ip);
                            }}
                          >
                            {ping?.loading ? t("devices.pinging") : t("devices.ping")}
                          </Button>
                          {ping?.result && (
                            <span className="text-xs text-kumo-success tabular-nums">
                              {t("common.latency", { ms: ping.result.latency_ms })} · {renderPath(ping.result.path, ping.result.relay)}
                            </span>
                          )}
                          {ping?.error && (
                            <span className="text-xs text-kumo-danger" role="alert">
                              {ping.error}
                            </span>
                          )}
                        </div>
                      </Table.Cell>
                    </Table.Row>
                  );
                })}
              </Table.Body>
            </Table>
          </div>
        )}
      </SectionCard>
    </div>
  );
}
