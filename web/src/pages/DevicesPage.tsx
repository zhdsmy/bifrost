import { useMemo, useState } from "react";
import { Badge } from "@cloudflare/kumo/components/badge";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { Empty } from "@cloudflare/kumo/components/empty";
import { InlineCopyText } from "@cloudflare/kumo/components/inline-copy-text";
import { Input } from "@cloudflare/kumo/components/input";
import { Table } from "@cloudflare/kumo/components/table";
import { useApp } from "../app/context";
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
  const { status, lang, t, tError, initializing } = useApp();
  const [filter, setFilter] = useState("");
  const [pings, setPings] = useState<Record<string, RowPingState>>({});

  const peers = status?.peers ?? [];
  const onlineCount = useMemo(() => peers.filter((p) => p.online).length, [peers]);

  const sorted = useMemo(() => {
    const q = filter.trim().toLowerCase();
    const list = q
      ? peers.filter(
          (p) =>
            p.name.toLowerCase().includes(q) ||
            p.dns_name.toLowerCase().includes(q) ||
            p.ip.toLowerCase().includes(q) ||
            p.ips.some((ip) => ip.toLowerCase().includes(q)),
        )
      : peers;
    return [...list].sort((a, b) => {
      if (a.online !== b.online) return a.online ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
  }, [peers, filter]);

  const visible = sorted.slice(0, MAX_RENDERED_PEERS);
  const truncated = sorted.length > MAX_RENDERED_PEERS;
  const nowSec = status?.time ?? Math.floor(Date.now() / 1000);

  const copyLabels = useMemo(
    () => ({ copyAction: t("common.copyAction"), copied: t("common.copied") }),
    [t],
  );

  function formatPath(path: PeerInfo["path"], relay: string): string {
    if (path === "direct") return t("devices.path.direct");
    if (path === "peer-relay") return t("devices.path.peerRelay");
    return relay ? t("devices.path.derpRegion", { relay }) : t("devices.path.derp");
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
            description={t("devices.limitNotice", { shown: MAX_RENDERED_PEERS, total: sorted.length })}
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
                  <Table.Head className="px-2.5 py-2 whitespace-nowrap">{t("devices.col.name")}</Table.Head>
                  <Table.Head className="px-2.5 py-2 whitespace-nowrap">{t("devices.col.ip")}</Table.Head>
                  <Table.Head className="px-2.5 py-2 whitespace-nowrap">{t("devices.col.os")}</Table.Head>
                  <Table.Head className="px-2.5 py-2 whitespace-nowrap">{t("devices.col.status")}</Table.Head>
                  <Table.Head className="px-2.5 py-2 whitespace-nowrap">{t("devices.col.path")}</Table.Head>
                  <Table.Head className="px-2.5 py-2 whitespace-nowrap">{t("devices.col.handshake")}</Table.Head>
                  <Table.Head className="px-2.5 py-2 whitespace-nowrap">{t("devices.col.traffic")}</Table.Head>
                  <Table.Head className="px-2.5 py-2 whitespace-nowrap">{t("devices.col.routes")}</Table.Head>
                  <Table.Head className="px-2.5 py-2 whitespace-nowrap" sticky="right">
                    {t("devices.col.action")}
                  </Table.Head>
                </Table.Row>
              </Table.Header>
              <Table.Body>
                {visible.map((peer) => {
                  const ping = pings[peer.ip];
                  return (
                    <Table.Row key={peer.ip} className="group">
                      <Table.Cell className="px-2.5 py-2">
                        <div className="grid min-w-0 gap-0.5">
                          <span className="font-medium text-kumo-strong">{peer.name}</span>
                          {peer.dns_name && (
                            <span className="max-w-36 truncate text-xs text-kumo-subtle">
                              {peer.dns_name}
                            </span>
                          )}
                        </div>
                      </Table.Cell>
                      <Table.Cell className="px-2.5 py-2 whitespace-nowrap">
                        <InlineCopyText value={peer.ip} labels={copyLabels}>
                          {peer.ip}
                        </InlineCopyText>
                      </Table.Cell>
                      <Table.Cell className="px-2.5 py-2 whitespace-nowrap">{peer.os || "—"}</Table.Cell>
                      <Table.Cell className="px-2.5 py-2 whitespace-nowrap">
                        <Badge appearance="dot" variant={peer.online ? "success" : "secondary"}>
                          {peer.online ? t("devices.status.online") : t("devices.status.offline")}
                        </Badge>
                      </Table.Cell>
                      <Table.Cell className="px-2.5 py-2 whitespace-nowrap">
                        <Badge variant={peer.path === "direct" ? "info" : "outline"}>
                          {formatPath(peer.path, peer.relay)}
                        </Badge>
                      </Table.Cell>
                      <Table.Cell className="px-2.5 py-2 whitespace-nowrap tabular-nums">
                        {formatHandshakeAge(peer.last_handshake, nowSec, lang)}
                      </Table.Cell>
                      <Table.Cell className="px-2.5 py-2 whitespace-nowrap tabular-nums">
                        <div className="grid leading-tight">
                          <span>↓ {formatBytes(peer.rx)}</span>
                          <span className="text-kumo-subtle">↑ {formatBytes(peer.tx)}</span>
                        </div>
                      </Table.Cell>
                      <Table.Cell className="px-2.5 py-2">
                        <div className="flex flex-wrap gap-1">
                          {peer.exit_node_option && (
                            <Badge variant="info">{t("devices.exitNodeBadge")}</Badge>
                          )}
                          {peer.routes.map((cidr) => (
                            <Badge key={cidr} variant="outline">
                              {cidr}
                            </Badge>
                          ))}
                          {!peer.exit_node_option && peer.routes.length === 0 && (
                            <span className="text-kumo-subtle">—</span>
                          )}
                        </div>
                      </Table.Cell>
                      <Table.Cell className="px-2.5 py-2" sticky="right">
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
                              {t("devices.pingResult", {
                                ms: ping.result.latency_ms,
                                path: formatPath(ping.result.path, ping.result.relay),
                              })}
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
