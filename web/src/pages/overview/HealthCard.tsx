import { Banner } from "@cloudflare/kumo/components/banner";
import { useApp } from "../../app/context";
import { SectionCard } from "../../components/SectionCard";

export function HealthCard({
  checks,
  health,
}: {
  checks: readonly string[];
  health: readonly string[];
}) {
  const { t, tCheck } = useApp();
  const clean = checks.length === 0 && health.length === 0;

  return (
    <SectionCard title={t("overview.section.health")}>
      {clean ? (
        <p className="text-sm text-kumo-success">{t("overview.health.clean")}</p>
      ) : (
        <div className="grid gap-2">
          {checks.length > 0 && (
            <div className="grid gap-1.5">
              <span className="text-xs font-medium text-kumo-subtle">
                {t("overview.health.checksHeading")}
              </span>
              {checks.map((code) => (
                <Banner
                  key={code}
                  variant={code === "watchdog_gave_up" ? "error" : "alert"}
                  size="sm"
                  description={tCheck(code)}
                />
              ))}
            </div>
          )}
          {health.length > 0 && (
            <div className="grid gap-1.5">
              <span className="text-xs font-medium text-kumo-subtle">
                {t("overview.health.daemonHeading")}
              </span>
              <ul
                data-raw-value="true"
                className="grid gap-1 rounded-lg border border-kumo-line bg-kumo-recessed p-2.5 font-mono text-xs text-kumo-default"
              >
                {health.map((line, i) => (
                  <li key={i} className="[overflow-wrap:anywhere]">
                    {line}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      )}
    </SectionCard>
  );
}
