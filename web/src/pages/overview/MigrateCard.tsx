import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { useApp } from "../../app/context";
import { JobProgress } from "../../components/JobProgress";
import { SectionCard } from "../../components/SectionCard";
import type { JobState, MigrateJobData } from "../../core/types";

export function MigrateCard({
  showAction,
  disabled,
  onRequestMigrate,
}: {
  showAction: boolean;
  disabled: boolean;
  onRequestMigrate: (anchor: HTMLElement) => void;
}) {
  const { jobs, t } = useApp();
  const migrateJob = jobs.migrate as JobState<MigrateJobData> | undefined;

  return (
    <SectionCard
      title={t("migrate.title")}
      description={t("migrate.desc")}
      action={
        showAction && (
          <Button
            variant="primary"
            size="sm"
            disabled={disabled}
            loading={migrateJob?.running}
            onClick={(e) => onRequestMigrate(e.currentTarget)}
          >
            {t("migrate.button")}
          </Button>
        )
      }
    >
      <p className="text-xs text-kumo-subtle">{t("migrate.note")}</p>
      {migrateJob?.running && migrateJob.data?.manual_stop && (
        <Banner variant="alert" title={t("migrate.manualStopNotice")} />
      )}
      {migrateJob && !migrateJob.running && migrateJob.ok === true && (
        <Banner variant="default" title={t("migrate.doneSuccess")} />
      )}
      {migrateJob &&
        !migrateJob.running &&
        migrateJob.ok === false &&
        migrateJob.data?.rolled_back && (
          <Banner variant="alert" role="alert" title={t("migrate.doneRolledBack")} />
        )}
      <JobProgress job={migrateJob} hideSuccess />
    </SectionCard>
  );
}
