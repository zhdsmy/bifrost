import { useState } from "react";
import { ArrowSquareOutIcon } from "@phosphor-icons/react/dist/csr/ArrowSquareOut";
import { Badge } from "@cloudflare/kumo/components/badge";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { ClipboardText } from "@cloudflare/kumo/components/clipboard-text";
import { useApp } from "../app/context";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { JobProgress } from "../components/JobProgress";
import { DetailItem, DetailList, SectionCard } from "../components/SectionCard";
import { api } from "../core/api";
import { CORE_RECIPE_SUMMARY, formatBytes, formatDateTime } from "../core/format";
import type { CoreArch, JobState, UpdateJobData } from "../core/types";

type CoreConfirmKind = "update" | "rollback" | { arch: CoreArch };

interface CoreConfirmState {
  kind: CoreConfirmKind;
  anchor: HTMLElement;
}

export function CorePage() {
  const { status, lang, busy, jobs, runJob, notify, t } = useApp();
  const [confirmState, setConfirmState] = useState<CoreConfirmState | null>(null);

  if (!status) return null;

  const core = status.core;
  const updateJob = jobs.update as JobState<UpdateJobData> | undefined;
  const latest = core.update ?? updateJob?.data?.latest ?? null;
  const canSwitchArch = core.kernel_arch === "aarch64";
  const targetArch: CoreArch = core.arch === "arm64" ? "arm" : "arm64";
  const upToDate = updateJob && !updateJob.running && updateJob.code === "up_to_date";
  const lostPrev =
    updateJob &&
    !updateJob.running &&
    updateJob.ok === true &&
    updateJob.data?.action === "update" &&
    updateJob.data?.kept_prev === false;

  async function executeConfirm(kind: CoreConfirmKind) {
    setConfirmState(null);
    if (kind === "update") {
      await runJob<UpdateJobData>("update", () => api.coreUpdate(), {
        onDone: (final) => {
          if (final.ok) notify({ title: t("common.actionSuccess"), variant: "success" });
        },
      });
    } else if (kind === "rollback") {
      await runJob<UpdateJobData>("update", () => api.coreRollback(), {
        onDone: (final) => {
          if (final.ok) notify({ title: t("common.actionSuccess"), variant: "success" });
        },
      });
    } else {
      await runJob<UpdateJobData>("update", () => api.coreArch(kind.arch), {
        onDone: (final) => {
          if (final.ok) notify({ title: t("common.actionSuccess"), variant: "success" });
        },
      });
    }
  }

  return (
    <div className="grid gap-4">
      <SectionCard title={t("core.section.current")}>
        <DetailList>
          <DetailItem label={t("core.field.version")}>
            {core.tailscale || "—"}
          </DetailItem>
          <DetailItem label={t("core.field.revision")}>
            {core.revision ? `r${core.revision} (#${core.serial})` : "—"}
          </DetailItem>
          <DetailItem label={t("core.field.arch")}>
            <Badge variant="outline">{core.arch || "—"}</Badge>
          </DetailItem>
          <DetailItem label={t("core.field.kernelArch")}>
            <Badge variant="secondary">{core.kernel_arch || "—"}</Badge>
          </DetailItem>
          <DetailItem label={t("core.field.size")}>
            {core.size > 0 ? formatBytes(core.size) : "—"}
          </DetailItem>
          <DetailItem label={t("core.field.installed")}>
            {formatDateTime(core.installed, lang)}
          </DetailItem>
          <DetailItem label={t("core.field.prev")}>
            <Badge variant={core.prev ? "success" : "secondary"}>
              {core.prev ? t("core.prev.available") : t("core.prev.missing")}
            </Badge>
          </DetailItem>
        </DetailList>
      </SectionCard>

      <SectionCard title={t("core.section.actions")}>
        {latest && (
          <Banner
            variant="default"
            title={t("core.latestBanner", {
              version: latest.tailscale,
              revision: latest.revision,
              serial: latest.serial,
            })}
            action={
              <a
                href={`https://github.com/zhdsmy/bifrost/releases/tag/${encodeURIComponent(latest.tag)}`}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1 text-sm font-medium text-kumo-link underline"
              >
                {t("core.releaseNotesLink")}
                <ArrowSquareOutIcon size={14} aria-hidden />
              </a>
            }
          />
        )}

        {upToDate && (
          <Banner variant="secondary" size="sm" title={t("core.upToDateNotice")} />
        )}

        {lostPrev && (
          <Banner variant="alert" size="sm" title={t("core.noPrevAfterUpdate")} />
        )}

        <JobProgress job={updateJob} label={t("core.progressLabel")} hideSuccess={Boolean(upToDate)} />

        <div className="flex flex-wrap gap-2">
          <Button
            variant="secondary"
            disabled={busy}
            loading={updateJob?.running && updateJob.data?.action === "check"}
            onClick={() => {
              void runJob<UpdateJobData>("update", () => api.coreCheck());
            }}
          >
            {t("core.action.check")}
          </Button>
          <Button
            variant="primary"
            disabled={busy}
            loading={updateJob?.running && updateJob.data?.action === "update"}
            onClick={(e) => setConfirmState({ kind: "update", anchor: e.currentTarget })}
          >
            {t("core.action.update")}
          </Button>
          <Button
            variant="secondary"
            disabled={busy || !core.prev}
            loading={updateJob?.running && updateJob.data?.action === "rollback"}
            onClick={(e) => setConfirmState({ kind: "rollback", anchor: e.currentTarget })}
          >
            {t("core.action.rollback")}
          </Button>
          {canSwitchArch && (
            <Button
              variant="secondary"
              disabled={busy}
              loading={updateJob?.running && updateJob.data?.action === "arch"}
              onClick={(e) => setConfirmState({ kind: { arch: targetArch }, anchor: e.currentTarget })}
            >
              {targetArch === "arm64" ? t("core.action.switchArm64") : t("core.action.switchArm")}
            </Button>
          )}
        </div>

        {!core.prev && (
          <p className="text-xs text-kumo-subtle">{t("core.noPrevHint")}</p>
        )}
      </SectionCard>

      <SectionCard title={t("core.section.recipe")} description={t("core.recipe.desc")}>
        <DetailList>
          <DetailItem label={t("core.recipe.go")}>{CORE_RECIPE_SUMMARY.goVersion}</DetailItem>
          <DetailItem label={t("core.recipe.flags")}>
            <code className="font-mono text-xs">{CORE_RECIPE_SUMMARY.flags}</code>
          </DetailItem>
        </DetailList>

        <div className="grid gap-2">
          <span className="text-xs font-medium text-kumo-subtle">
            {t("core.recipe.omit", { count: CORE_RECIPE_SUMMARY.omitCount })}
          </span>
          <div className="flex flex-wrap gap-1.5">
            {CORE_RECIPE_SUMMARY.omit.map((tag) => (
              <Badge key={tag} variant="outline">
                {tag}
              </Badge>
            ))}
          </div>
        </div>

        <div className="grid gap-1.5">
          <span className="text-xs font-medium text-kumo-subtle">{t("core.recipe.verify")}</span>
          <ClipboardText
            size="sm"
            text={CORE_RECIPE_SUMMARY.verifyCommand}
            tooltip={{ text: t("common.copy"), copiedText: t("common.copied") }}
            labels={{
              copyAction: t("common.copyAction"),
              revealAction: t("common.reveal"),
              hideAction: t("common.hide"),
            }}
          />
        </div>
      </SectionCard>

      {confirmState && (
        <ConfirmDialog
          open={true}
          anchor={confirmState.anchor}
          onOpenChange={(open) => {
            if (!open) setConfirmState(null);
          }}
          title={
            confirmState.kind === "update"
              ? t("core.confirm.updateTitle")
              : confirmState.kind === "rollback"
                ? t("core.confirm.rollbackTitle")
                : t("core.confirm.archTitle", { arch: confirmState.kind.arch })
          }
          description={
            confirmState.kind === "update"
              ? t("core.confirm.updateDesc")
              : confirmState.kind === "rollback"
                ? t("core.confirm.rollbackDesc")
                : t("core.confirm.archDesc", { arch: confirmState.kind.arch })
          }
          disruptive={true}
          onConfirm={() => executeConfirm(confirmState.kind)}
        />
      )}
    </div>
  );
}
