import { Banner } from "@cloudflare/kumo/components/banner";
import { Loader } from "@cloudflare/kumo/components/loader";
import { Meter } from "@cloudflare/kumo/components/meter";
import type { JobProgressState } from "../core/types";
import { useApp } from "../app/context";

export function JobProgress({
  job,
  label,
  hideSuccess = false,
}: {
  job: JobProgressState<unknown> | undefined;
  label?: string;
  hideSuccess?: boolean;
}) {
  const { tPhase, tErrorCode, t } = useApp();
  if (!job) return null;

  if (job.running) {
    const phaseText = tPhase(job.phase);
    if (typeof job.progress === "number") {
      return (
        <div className="grid gap-1.5 rounded-lg border border-kumo-line bg-kumo-recessed px-3 py-2.5">
          <Meter
            label={label ? `${label} · ${phaseText}` : phaseText}
            value={Math.max(0, Math.min(100, job.progress))}
          />
        </div>
      );
    }
    return (
      <div className="flex items-center gap-2 rounded-lg border border-kumo-line bg-kumo-recessed px-3 py-2 text-sm text-kumo-default">
        <Loader size="sm" aria-label={t("common.loadingAction")} />
        <span>{label ? `${label} · ${phaseText}` : phaseText}</span>
      </div>
    );
  }

  if (job.ok === false && job.code) {
    return <Banner variant="error" role="alert" size="sm" title={tErrorCode(job.code)} />;
  }

  if (job.ok === true && !hideSuccess) {
    return <Banner variant="secondary" size="sm" title={t("common.actionSuccess")} />;
  }

  return null;
}
