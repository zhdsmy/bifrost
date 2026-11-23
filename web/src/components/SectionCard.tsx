import type { ReactNode } from "react";
import { LayerCard } from "@cloudflare/kumo/components/layer-card";

export function SectionCard({
  title,
  description,
  action,
  children,
}: {
  title: ReactNode;
  description?: ReactNode;
  action?: ReactNode;
  children: ReactNode;
}) {
  return (
    <LayerCard className="flex flex-col gap-4 rounded-xl border border-kumo-line bg-kumo-base p-4 @md:p-5">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="grid min-w-0 gap-0.5">
          <h2 className="text-base font-semibold text-kumo-strong">{title}</h2>
          {description && <p className="text-sm text-kumo-subtle">{description}</p>}
        </div>
        {action && <div className="flex shrink-0 flex-wrap items-center gap-2">{action}</div>}
      </div>
      {children}
    </LayerCard>
  );
}

export function DetailList({ children }: { children: ReactNode }) {
  return <dl className="grid gap-x-6 gap-y-3 @lg:grid-cols-2">{children}</dl>;
}

export function DetailItem({ label, children }: { label: ReactNode; children: ReactNode }) {
  return (
    <div className="grid min-w-0 gap-0.5">
      <dt className="text-xs font-medium text-kumo-subtle">{label}</dt>
      <dd className="min-w-0 text-sm text-kumo-default [overflow-wrap:anywhere]">{children}</dd>
    </div>
  );
}
