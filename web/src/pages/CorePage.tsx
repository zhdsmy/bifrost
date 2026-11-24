import { useState } from "react";
import { ArrowSquareOutIcon } from "@phosphor-icons/react/dist/csr/ArrowSquareOut";
import { Badge } from "@cloudflare/kumo/components/badge";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { useApp } from "../app/context";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { CopyField } from "../components/CopyInline";
import { JobProgress } from "../components/JobProgress";
import { DetailItem, DetailList, SectionCard } from "../components/SectionCard";
import { api } from "../core/api";
import { CORE_VERIFY_COMMAND, formatBytes, formatDateTime, isCoreUpToDate } from "../core/format";
import type { CoreArch, CoreVariant, JobProgressState, UpdateJobData } from "../core/types";

type CoreConfirmKind = "update" | "rollback" | { arch: CoreArch } | { variant: CoreVariant };

interface CoreConfirmState {
  kind: CoreConfirmKind;
  anchor: HTMLElement;
}

export function CorePage() {
  const { status, busy, jobs, runJob, notify, t } = useApp();
  const [confirmState, setConfirmState] = useState<CoreConfirmState | null>(null);

  if (!status) return null;

  const core = status.core;
  const build = core.build;
  const omit = Array.isArray(build?.omit) ? build.omit : null;
  const updateJob = jobs.update as JobProgressState<UpdateJobData> | undefined;
  const checkedLatest = updateJob?.ok && updateJob.data.action === "check" ? updateJob.data.latest : null;
  const latest = core.update ?? (checkedLatest && checkedLatest.serial > core.serial ? checkedLatest : null);
  const canSwitchArch = core.kernel_arch === "aarch64";
  const targetArch: CoreArch = core.arch === "arm64" ? "arm" : "arm64";
  const currentVariant: CoreVariant = core.variant ?? "normal";
  const targetVariant: CoreVariant = currentVariant === "upx" ? "normal" : "upx";
  const variantLabel = (v: CoreVariant) => t(v === "upx" ? "core.variant.upx" : "core.variant.normal");
  const upToDate = isCoreUpToDate(status, updateJob);
  const lostPrev = Boolean(
    updateJob &&
      !updateJob.running &&
      updateJob.ok === true &&
      updateJob.data?.action === "update" &&
      updateJob.data?.kept_prev === false,
  );

  async function runCoreMutation(trigger: () => Promise<unknown>) {
    await runJob<UpdateJobData>("update", trigger, {
      onDone: (final) => {
        if (final.ok) notify({ title: t("common.actionSuccess"), variant: "success" });
      },
    });
  }

  async function executeConfirm(kind: CoreConfirmKind) {
    setConfirmState(null);
    if (kind === "update") {
      await runCoreMutation(() => api.coreUpdate());
    } else if (kind === "rollback") {
      await runCoreMutation(() => api.coreRollback());
    } else {
      await runCoreMutation(() => "arch" in kind ? api.coreArch(kind.arch) : api.coreType(kind.variant));
    }
  }

  return (
    <div className="grid gap-4">
      <SectionCard title={t("core.section.current")}>
        <DetailList>
          <DetailItem label={t("core.field.version")}>{core.tailscale || "—"}</DetailItem>
          <DetailItem label={t("core.field.revision")}>
            {core.revision ? `r${core.revision} (#${core.serial})` : "—"}
          </DetailItem>
          <DetailItem label={t("core.field.arch")}>
            <Badge variant="outline">{core.arch || "—"}</Badge>
          </DetailItem>
          <DetailItem label={t("core.field.variant")}>
            <Badge variant="outline">{variantLabel(currentVariant)}</Badge>
          </DetailItem>
          <DetailItem label={t("core.field.kernelArch")}>
            <Badge variant="secondary">{core.kernel_arch || "—"}</Badge>
          </DetailItem>
          <DetailItem label={t("core.field.size")}>
            {core.size > 0 ? formatBytes(core.size) : "—"}
          </DetailItem>
          <DetailItem label={t("core.field.installed")}>
            {formatDateTime(core.installed)}
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

        {status.plugin.update && (
          <Banner
            variant="default"
            title={t("core.pluginUpdateBanner", { version: status.plugin.update.version })}
            action={
              <a
                href={status.plugin.update.url}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1 text-sm font-medium text-kumo-link underline"
              >
                {t("core.pluginReleaseLink")}
                <ArrowSquareOutIcon size={14} aria-hidden />
              </a>
            }
          />
        )}

        {upToDate && <Banner variant="secondary" size="sm" title={t("core.upToDateNotice")} />}

        {lostPrev && <Banner variant="alert" size="sm" title={t("core.noPrevAfterUpdate")} />}

        <JobProgress
          job={updateJob}
          label={t("core.progressLabel")}
          hideSuccess={upToDate || updateJob?.data?.action === "check"}
        />

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
              onClick={(e) =>
                setConfirmState({ kind: { arch: targetArch }, anchor: e.currentTarget })
              }
            >
              {targetArch === "arm64" ? t("core.action.switchArm64") : t("core.action.switchArm")}
            </Button>
          )}
          {core.variant && (
            <Button
              variant="secondary"
              disabled={busy}
              loading={updateJob?.running && updateJob.data?.action === "type"}
              onClick={(e) => setConfirmState({ kind: { variant: targetVariant }, anchor: e.currentTarget })}
            >
              {targetVariant === "upx" ? t("core.action.switchUpx") : t("core.action.switchNormal")}
            </Button>
          )}
        </div>

        <p className="text-xs text-kumo-subtle">{t("core.variant.cost")}</p>

        {!core.prev && <p className="text-xs text-kumo-subtle">{t("core.noPrevHint")}</p>}
      </SectionCard>

      <SectionCard title={t("core.section.recipe")} description={t("core.recipe.desc")}>
        <DetailList>
          <DetailItem label={t("core.recipe.go")}>
            {build?.go ? <span data-raw-value="true">{build.go}</span> : t("common.unknown")}
          </DetailItem>
          <DetailItem label={t("core.recipe.commit")}>
            {build?.commit ? (
              <code data-raw-value="true" className="font-mono text-xs">
                {build.commit.slice(0, 12)}
              </code>
            ) : (
              t("common.unknown")
            )}
          </DetailItem>
        </DetailList>

        <div className="grid gap-2">
          <span className="text-xs font-medium text-kumo-subtle">
            {omit
              ? t("core.recipe.omit", { count: omit.length })
              : t("core.recipe.omitLabel")}
          </span>
          {!omit ? (
            <span className="text-sm text-kumo-subtle">{t("common.unknown")}</span>
          ) : omit.length > 0 ? (
            <div data-raw-value="true" className="flex flex-wrap gap-1.5">
              {omit.map((tag) => (
                <Badge key={tag} variant="outline">
                  {tag}
                </Badge>
              ))}
            </div>
          ) : (
            <span className="text-sm text-kumo-subtle">{t("common.none")}</span>
          )}
        </div>

        <div className="grid gap-1.5">
          <span className="text-xs font-medium text-kumo-subtle">{t("core.recipe.verify")}</span>
          <CopyField text={CORE_VERIFY_COMMAND} />
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
                : "arch" in confirmState.kind
                  ? t("core.confirm.archTitle", { arch: confirmState.kind.arch })
                  : t("core.confirm.typeTitle", { type: variantLabel(confirmState.kind.variant) })
          }
          description={
            confirmState.kind === "update"
              ? t("core.confirm.updateDesc")
              : confirmState.kind === "rollback"
                ? t("core.confirm.rollbackDesc")
                : "arch" in confirmState.kind
                  ? t("core.confirm.archDesc", { arch: confirmState.kind.arch })
                  : t("core.confirm.typeDesc", { type: variantLabel(confirmState.kind.variant) })
          }
          disruptive={true}
          onConfirm={() => executeConfirm(confirmState.kind)}
        />
      )}
    </div>
  );
}
