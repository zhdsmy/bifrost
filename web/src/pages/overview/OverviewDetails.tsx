import { ArrowSquareOutIcon } from "@phosphor-icons/react/dist/csr/ArrowSquareOut";
import { Badge } from "@cloudflare/kumo/components/badge";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { useApp } from "../../app/context";
import { CopyInline } from "../../components/CopyInline";
import { DetailItem, DetailList, SectionCard } from "../../components/SectionCard";
import { analyzeKeyExpiry, formatIsoDate, isCoreUpToDate } from "../../core/format";
import type {
  JobProgressState,
  NetcheckJobData,
  StatusData,
  UpdateJobData,
} from "../../core/types";
import { HealthCard } from "./HealthCard";

const OFFICIAL_CONSOLE_URL = "https://login.tailscale.com/admin/machines";

export function OverviewDetails({ status }: { status: StatusData }) {
  const { jobs, setTab, t, tErrorCode } = useApp();
  const self = status.self;
  const netcheckJob = jobs.netcheck as JobProgressState<NetcheckJobData> | undefined;
  const updateJob = jobs.update as JobProgressState<UpdateJobData> | undefined;
  const netcheckReport = netcheckJob?.data?.report ?? null;

  const keyExpiry = self ? analyzeKeyExpiry(self.key_expiry, status.time * 1000) : null;
  const preferredDerpLatency =
    netcheckReport && self?.relay
      ? netcheckReport.derp.find((d) => d.code === self.relay)?.latency_ms
      : undefined;
  const anyRoutePending =
    status.routes.some((r) => !r.approved) ||
    (status.exit_node.advertised && !status.exit_node.approved);
  return (
    <>
      {self && (
        <SectionCard title={t("overview.section.self")}>
          {keyExpiry?.expired && (
            <Banner variant="error" role="alert" title={t("overview.keyExpired")} />
          )}
          {keyExpiry?.expiringSoon && (
            <Banner
              variant="alert"
              title={t("overview.keyExpiringSoon", { days: keyExpiry.daysLeft })}
            />
          )}
          <DetailList>
            <DetailItem label={t("overview.field.hostname")}>
              <span data-raw-value="true" className="font-medium text-kumo-strong">
                {self.hostname || "—"}
              </span>
            </DetailItem>
            <DetailItem label={t("overview.field.tailnet")}>
              <span data-raw-value="true">{self.tailnet || "—"}</span>
            </DetailItem>
            <DetailItem label={t("overview.field.tailnetIps")}>
              <div className="flex flex-wrap gap-2">
                {self.ips.length > 0 ? (
                  self.ips.map((ip) => <CopyInline key={ip} value={ip} />)
                ) : (
                  <span>—</span>
                )}
              </div>
            </DetailItem>
            <DetailItem label={t("overview.field.magicdns")}>
              {self.dns_name ? <CopyInline value={self.dns_name} /> : <span>—</span>}
            </DetailItem>
            {!self.official && self.control && (
              <DetailItem label={t("overview.field.control")}>
                <span data-raw-value="true" className="font-mono text-xs">
                  {self.control}
                </span>
              </DetailItem>
            )}
            <DetailItem label={t("overview.field.keyExpiry")}>
              {formatIsoDate(self.key_expiry)}
            </DetailItem>
          </DetailList>
        </SectionCard>
      )}

      <div className="grid gap-4 @xl:grid-cols-2">
        <SectionCard
          title={t("overview.section.connection")}
          action={
            !netcheckReport && (
              <Button size="sm" variant="ghost" onClick={() => setTab("diagnostics")}>
                {t("overview.connection.runNetcheck")}
              </Button>
            )
          }
        >
          <DetailList>
            <DetailItem label={t("overview.field.online")}>
              <Badge appearance="dot" variant={self?.online ? "success" : "secondary"}>
                {self?.online ? t("overview.connection.online") : t("overview.connection.offline")}
              </Badge>
            </DetailItem>
            <DetailItem label={t("overview.field.preferredDerp")}>
              {self?.relay ? (
                <span data-raw-value="true" className="font-mono">
                  {self.relay}
                  {preferredDerpLatency !== undefined ? ` (${t("common.latency", { ms: preferredDerpLatency })})` : ""}
                </span>
              ) : (
                "—"
              )}
            </DetailItem>
            <DetailItem label={t("overview.field.udp")}>
              {netcheckReport ? (
                <Badge variant={netcheckReport.udp ? "success" : "warning"}>
                  {netcheckReport.udp ? t("common.yes") : t("common.no")}
                </Badge>
              ) : (
                <span className="text-kumo-subtle">—</span>
              )}
            </DetailItem>
            <DetailItem label={t("overview.field.portmap")}>
              {netcheckReport ? (
                <span data-raw-value="true">{netcheckReport.portmap || t("common.none")}</span>
              ) : (
                <span className="text-kumo-subtle">—</span>
              )}
            </DetailItem>
          </DetailList>
        </SectionCard>

        <SectionCard title={t("overview.section.routes")}>
          <div className="grid gap-3">
            <div className="grid gap-1.5">
              <span className="text-xs font-medium text-kumo-subtle">
                {t("overview.field.advertisedRoutes")}
              </span>
              {status.routes.length > 0 ? (
                <ul className="flex flex-wrap gap-2">
                  {status.routes.map((route) => (
                    <li
                      key={route.cidr}
                      className="inline-flex items-center gap-1.5 rounded-md border border-kumo-line bg-kumo-recessed px-2 py-1 text-xs"
                    >
                      <span className="font-mono">{route.cidr}</span>
                      <Badge variant={route.approved ? "success" : "warning"}>
                        {route.approved ? t("overview.route.approved") : t("overview.route.pending")}
                      </Badge>
                    </li>
                  ))}
                </ul>
              ) : (
                <span className="text-sm text-kumo-subtle">{t("common.none")}</span>
              )}
            </div>

            <DetailList>
              <DetailItem label={t("overview.field.exitNode")}>
                {!status.exit_node.advertised ? (
                  <span className="text-kumo-subtle">{t("overview.exitNode.off")}</span>
                ) : (
                  <Badge variant={status.exit_node.approved ? "success" : "warning"}>
                    {status.exit_node.approved
                      ? t("overview.exitNode.approved")
                      : t("overview.exitNode.pending")}
                  </Badge>
                )}
              </DetailItem>
              <DetailItem label={t("overview.field.acceptRoutes")}>
                <Badge variant={status.prefs?.accept_routes ? "info" : "secondary"}>
                  {status.prefs?.accept_routes ? t("common.enabled") : t("common.disabled")}
                </Badge>
              </DetailItem>
            </DetailList>

            {anyRoutePending && (
              <div className="text-xs text-kumo-subtle">
                {self?.official !== false ? (
                  <a
                    href={OFFICIAL_CONSOLE_URL}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center gap-1 font-medium text-kumo-link underline"
                  >
                    {t("overview.route.approveOfficial")}
                    <ArrowSquareOutIcon size={12} aria-hidden />
                  </a>
                ) : (
                  <span>{t("overview.route.approveCustom")}</span>
                )}
              </div>
            )}
          </div>
        </SectionCard>
      </div>

      <div className="grid gap-4 @xl:grid-cols-2">
        <SectionCard title={t("overview.section.version")}>
          <DetailList>
            <DetailItem label={t("overview.field.pluginVersion")}>
              {status.plugin.version}
            </DetailItem>
            <DetailItem label={t("overview.field.coreVersion")}>
              <span data-raw-value="true">
                {status.core.tailscale} (r{status.core.revision} · {status.core.arch})
              </span>
            </DetailItem>
          </DetailList>
          {status.core.update ? (
            <Banner
              variant="default"
              size="sm"
              title={t("overview.coreUpdateAvailable", {
                version: status.core.update.tailscale,
                revision: status.core.update.revision,
              })}
              action={
                <Button size="sm" variant="secondary" onClick={() => setTab("core")}>
                  {t("overview.action.gotoCore")}
                </Button>
              }
            />
          ) : isCoreUpToDate(status, updateJob) ? (
            <p className="text-xs text-kumo-subtle">{t("overview.coreUpToDate")}</p>
          ) : updateJob?.data.action === "check" && updateJob.ok === false ? (
            <Banner variant="error" size="sm" title={tErrorCode(updateJob.code ?? "internal")} />
          ) : (
            <p className="text-xs text-kumo-subtle">{t("overview.coreNotChecked")}</p>
          )}
        </SectionCard>

        <HealthCard checks={status.checks} health={status.health} />
      </div>
    </>
  );
}
