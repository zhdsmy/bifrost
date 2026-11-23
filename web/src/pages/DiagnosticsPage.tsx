import { useCallback, useEffect, useState } from "react";
import { ArrowsClockwiseIcon } from "@phosphor-icons/react/dist/csr/ArrowsClockwise";
import { CopyIcon } from "@phosphor-icons/react/dist/csr/Copy";
import { CheckIcon } from "@phosphor-icons/react/dist/csr/Check";
import { Badge } from "@cloudflare/kumo/components/badge";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { Empty } from "@cloudflare/kumo/components/empty";
import { Table } from "@cloudflare/kumo/components/table";
import { useApp } from "../app/context";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { JobProgress } from "../components/JobProgress";
import { DetailItem, DetailList, SectionCard } from "../components/SectionCard";
import { api } from "../core/api";
import { useCopy } from "../components/CopyInline";
import { formatKb } from "../core/format";
import type { DiagData, JobProgressState, NetcheckJobData } from "../core/types";

export function DiagnosticsPage() {
  const { busy, jobs, runJob, notify, t, tError } = useApp();
  const [diag, setDiag] = useState<DiagData | null>(null);
  const [logsText, setLogsText] = useState<string>("");
  const [logsLoading, setLogsLoading] = useState(false);
  const [logsError, setLogsError] = useState<string | null>(null);
  const { copied, handleCopy } = useCopy(logsText);
  const [purgeAnchor, setPurgeAnchor] = useState<HTMLElement | null>(null);

  const netcheckJob = jobs.netcheck as JobProgressState<NetcheckJobData> | undefined;
  const report = netcheckJob?.data?.report ?? null;

  const fetchLogsAndDiag = useCallback(async () => {
    setLogsLoading(true);
    setLogsError(null);
    try {
      await api.logs();
      const [nextDiag, nextLogs] = await Promise.all([
        api.readDiag().catch(() => null),
        api.readLogsText().catch(() => ""),
      ]);
      setDiag(nextDiag);
      setLogsText(nextLogs);
    } catch (err) {
      setLogsError(tError(err));
    } finally {
      setLogsLoading(false);
    }
  }, [tError]);

  useEffect(() => {
    void fetchLogsAndDiag();
  }, [fetchLogsAndDiag]);

  function renderTriBool(val: boolean | null | undefined, invertWarn = false) {
    if (val === null || val === undefined) {
      return <Badge variant="secondary">{t("diag.env.unchecked")}</Badge>;
    }
    if (invertWarn) {
      return (
        <Badge variant={val ? "warning" : "success"}>
          {val ? t("common.yes") : t("common.no")}
        </Badge>
      );
    }
    return (
      <Badge variant={val ? "success" : "error"}>
        {val ? t("diag.env.ok") : t("diag.env.fail")}
      </Badge>
    );
  }

  return (
    <div className="grid gap-4">
      <SectionCard
        title={t("diag.section.netcheck")}
        description={t("diag.netcheck.desc")}
        action={
          <Button
            variant="secondary"
            disabled={busy || netcheckJob?.running}
            loading={netcheckJob?.running}
            onClick={() => {
              void runJob<NetcheckJobData>("netcheck", () => api.netcheck());
            }}
          >
            {t("diag.netcheck.run")}
          </Button>
        }
      >
        <JobProgress job={netcheckJob} hideSuccess />
        {report ? (
          <div className="grid gap-4">
            <DetailList>
              <DetailItem label={t("diag.netcheck.udp")}>
                <Badge variant={report.udp ? "success" : "warning"}>
                  {report.udp ? t("common.yes") : t("common.no")}
                </Badge>
              </DetailItem>
              <DetailItem label={t("diag.netcheck.ipv4")}>
                <Badge variant={report.ipv4 ? "success" : "secondary"}>
                  {report.ipv4 ? t("common.yes") : t("common.no")}
                </Badge>
              </DetailItem>
              <DetailItem label={t("diag.netcheck.ipv6")}>
                <Badge variant={report.ipv6 ? "success" : "secondary"}>
                  {report.ipv6 ? t("common.yes") : t("common.no")}
                </Badge>
              </DetailItem>
              <DetailItem label={t("diag.netcheck.mappingVaries")}>
                {report.mapping_varies === null
                  ? t("common.unknown")
                  : report.mapping_varies
                    ? t("common.yes")
                    : t("common.no")}
              </DetailItem>
              <DetailItem label={t("diag.netcheck.portmap")}>
                <span data-raw-value="true">{report.portmap || t("common.none")}</span>
              </DetailItem>
              <DetailItem label={t("diag.netcheck.preferred")}>
                <Badge variant="info">
                  <span data-raw-value="true">{report.preferred_derp || "—"}</span>
                </Badge>
              </DetailItem>
            </DetailList>

            {report.derp.length > 0 && (
              <div className="grid gap-2">
                <h3 className="text-xs font-medium text-kumo-subtle">
                  {t("diag.netcheck.derpTable")}
                </h3>
                <div className="overflow-x-auto rounded-lg border border-kumo-line">
                  <Table>
                    <Table.Header>
                      <Table.Row>
                        <Table.Head>{t("diag.netcheck.derpCode")}</Table.Head>
                        <Table.Head>{t("diag.netcheck.derpLatency")}</Table.Head>
                      </Table.Row>
                    </Table.Header>
                    <Table.Body>
                      {report.derp.map((d) => (
                        <Table.Row key={d.code}>
                          <Table.Cell className="font-mono">
                            <span data-raw-value="true">{d.code}</span>
                          </Table.Cell>
                          <Table.Cell className="tabular-nums">{t("common.latency", { ms: d.latency_ms })}</Table.Cell>
                        </Table.Row>
                      ))}
                    </Table.Body>
                  </Table>
                </div>
              </div>
            )}
          </div>
        ) : (
          <Empty title={t("diag.section.netcheck")} description={t("diag.netcheck.empty")} size="sm" />
        )}
      </SectionCard>

      <SectionCard title={t("diag.section.env")}>
        <DetailList>
          <DetailItem label={t("diag.env.tun")}>{renderTriBool(diag?.tun)}</DetailItem>
          <DetailItem label={t("diag.env.fw")}>{renderTriBool(diag?.fw_complete)}</DetailItem>
          <DetailItem label={t("diag.env.conflict")}>
            {diag ? (
              <Badge variant={diag.conflict ? "error" : "success"}>
                {diag.conflict ? t("diag.env.hasConflict") : t("diag.env.noConflict")}
              </Badge>
            ) : (
              <Badge variant="secondary">{t("diag.env.unchecked")}</Badge>
            )}
          </DetailItem>
          <DetailItem label={t("diag.env.cgnat")}>
            {renderTriBool(diag?.wan_cgnat, true)}
          </DetailItem>
          <DetailItem label={t("diag.env.jffs")}>
            {diag?.jffs_free_kb != null ? (
              <span className="tabular-nums">{formatKb(diag.jffs_free_kb)}</span>
            ) : (
              <Badge variant="secondary">{t("diag.env.unchecked")}</Badge>
            )}
          </DetailItem>
          <DetailItem label={t("diag.env.time")}>{renderTriBool(diag?.time_synced)}</DetailItem>
          <DetailItem label={t("diag.env.confDir")}>
            {renderTriBool(diag?.dnsmasq_conf_dir)}
          </DetailItem>
        </DetailList>
      </SectionCard>

      <SectionCard
        title={t("diag.section.logs")}
        description={t("diag.logs.desc")}
        action={
          <>
            <Button
              variant="secondary"
              size="sm"
              loading={logsLoading}
              disabled={logsLoading}
              onClick={() => {
                void fetchLogsAndDiag();
              }}
            >
              <ArrowsClockwiseIcon size={14} aria-hidden />
              {t("diag.logs.load")}
            </Button>
            <Button
              variant="primary"
              size="sm"
              disabled={!logsText}
              onClick={() => {
                void handleCopy();
              }}
            >
              {copied ? <CheckIcon size={14} aria-hidden /> : <CopyIcon size={14} aria-hidden />}
              {copied ? t("common.copied") : t("diag.logs.copyAll")}
            </Button>
          </>
        }
      >
        {logsError && <Banner variant="error" role="alert" size="sm" title={logsError} />}
        <pre
          role="log"
          tabIndex={0}
          className="max-h-72 overflow-auto rounded-lg border border-kumo-line bg-kumo-recessed p-3 font-mono text-xs leading-relaxed whitespace-pre-wrap break-all text-kumo-default"
        >
          {logsText || t("diag.logs.empty")}
        </pre>
      </SectionCard>

      <SectionCard title={t("diag.section.danger")}>
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="grid min-w-0 flex-1 gap-0.5">
            <span className="text-sm font-medium text-kumo-strong">{t("diag.purge.title")}</span>
            <span className="text-xs text-kumo-subtle">{t("diag.purge.desc")}</span>
          </div>
          <Button
            variant="destructive"
            disabled={busy}
            onClick={(e) => setPurgeAnchor(e.currentTarget)}
          >
            {t("diag.purge.button")}
          </Button>
        </div>
        {jobs.daemon?.running && <JobProgress job={jobs.daemon} />}
      </SectionCard>

      <ConfirmDialog
        open={purgeAnchor !== null}
        anchor={purgeAnchor}
        onOpenChange={(open) => {
          if (!open) setPurgeAnchor(null);
        }}
        title={t("diag.purge.confirmTitle")}
        description={t("diag.purge.confirmDesc")}
        confirmLabel={t("diag.purge.button")}
        confirmVariant="destructive"
        disruptive={true}
        onConfirm={async () => {
          setPurgeAnchor(null);
          await runJob("daemon", () => api.purge(), {
            suppressLoginFailure: true,
            onDone: (final) => {
              if (final.ok) notify({ title: t("common.actionSuccess"), variant: "success" });
            },
          });
        }}
      />
    </div>
  );
}
