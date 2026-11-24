import { useMemo, useState } from "react";
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
import type { PeerInfo, PingResult } from "../core/types";

const MAX_RENDERED_PEERS = 200;

interface RowPingState {
  loading: boolean;
  result?: PingResult;
  error?: string;
}

export function DevicesPage() {
  const { lang, status, t, tError, initializing } = useApp();
  const [filter, setFilter] = useState("");
  const [pings, setPings] = useState<Record<string, RowPingState>>({});

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
  const tableCellClass = lang === "en" ? "!px-1.5 !py-1.5" : "px-2.5 py-2";
  const tableHeadClass = `${tableCellClass} whitespace-nowrap${lang === "en" ? " !text-xs" : ""}`;

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
        <div className="max-w-sm">
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
            <Table className="text-xs">
              <Table.Header>
                <Table.Row>
                  <Table.Head className={tableHeadClass}>{t("devices.col.name")}</Table.Head>
                  <Table.Head className={tableHeadClass}>{t("devices.col.ip")}</Table.Head>
                  <Table.Head className={tableHeadClass}>{t("devices.col.os")}</Table.Head>
                  <Table.Head className={tableHeadClass}>{t("devices.col.status")}</Table.Head>
                  <Table.Head className={tableHeadClass}>{t("devices.col.path")}</Table.Head>
                  <Table.Head className={tableHeadClass}>{t("devices.col.handshake")}</Table.Head>
                  <Table.Head className={tableHeadClass}>{t("devices.col.traffic")}</Table.Head>
                  <Table.Head className={tableHeadClass}>{t("devices.col.routes")}</Table.Head>
                  <Table.Head className={tableHeadClass} sticky="right">
                    {t("devices.col.action")}
                  </Table.Head>
                </Table.Row>
              </Table.Header>
              <Table.Body>
                {visible.map((peer) => {
                  const ping = pings[peer.ip];
                  return (
                    <Table.Row key={peer.ip} className="group">
                      <Table.Cell className={tableCellClass}>
                        <div className="grid min-w-0 gap-0.5">
                          <span data-raw-value="true" className="font-medium text-kumo-strong">
                            {peer.name}
                          </span>
                          {peer.dns_name && (
                            <span
                              data-raw-value="true"
                              className="max-w-36 truncate text-xs text-kumo-subtle"
                            >
                              {peer.dns_name}
                            </span>
                          )}
                        </div>
                      </Table.Cell>
                      <Table.Cell className={`${tableCellClass} whitespace-nowrap`}>
                        <CopyInline value={peer.ip} />
                      </Table.Cell>
                      <Table.Cell className={`${tableCellClass} whitespace-nowrap`}>
                        <span data-raw-value="true">{peer.os || "—"}</span>
                      </Table.Cell>
                      <Table.Cell className={`${tableCellClass} whitespace-nowrap`}>
                        <Badge appearance="dot" variant={peer.online ? "success" : "secondary"}>
                          {peer.online ? t("devices.status.online") : t("devices.status.offline")}
                        </Badge>
                      </Table.Cell>
                      <Table.Cell className={`${tableCellClass} whitespace-nowrap`}>
                        <Badge variant={peer.path === "direct" ? "info" : "outline"}>
                          {renderPath(peer.path, peer.relay)}
                        </Badge>
                      </Table.Cell>
                      <Table.Cell className={`${tableCellClass} whitespace-nowrap tabular-nums`}>
                        {formatHandshakeAge(peer.last_handshake, nowSec, t)}
                      </Table.Cell>
                      <Table.Cell className={`${tableCellClass} whitespace-nowrap tabular-nums`}>
                        <div className="grid leading-tight">
                          <span>↓ {formatBytes(peer.rx)}</span>
                          <span className="text-kumo-subtle">↑ {formatBytes(peer.tx)}</span>
                        </div>
                      </Table.Cell>
                      <Table.Cell className={`${tableCellClass}${lang === "en" ? " text-[10px]" : ""}`}>
                        <div className="flex flex-wrap gap-1">
                          {peer.exit_node_option && (
                            <Badge variant="info">{t("devices.exitNodeBadge")}</Badge>
                          )}
                          {peer.routes.map((cidr) => (
                            <Badge key={cidr} variant="outline" className={lang === "en" ? "!px-0 text-[9px]" : undefined}>
                              {cidr}
                            </Badge>
                          ))}
                          {!peer.exit_node_option && peer.routes.length === 0 && (
                            <span className="text-kumo-subtle">—</span>
                          )}
                        </div>
                      </Table.Cell>
                      <Table.Cell className={tableCellClass} sticky="right">
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
                            <span className="whitespace-nowrap text-xs text-kumo-success tabular-nums">
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
