import { useMemo } from "react";
import { encode } from "uqr";

export function QrCode({ value, alt, size = 184 }: { value: string; alt: string; size?: number }) {
  const { modules, path } = useMemo(() => {
    const result = encode(value, { ecc: "M", border: 2 });
    const parts: string[] = [];
    for (let y = 0; y < result.size; y++) {
      const row = result.data[y];
      for (let x = 0; x < result.size; x++) {
        if (row[x]) parts.push(`M${x} ${y}h1v1h-1z`);
      }
    }
    return { modules: result.size, path: parts.join("") };
  }, [value]);

  return (
    <div className="inline-flex rounded-lg border border-kumo-line bg-white p-2 text-black shadow-xs">
      <svg
        role="img"
        aria-label={alt}
        width={size}
        height={size}
        viewBox={`0 0 ${modules} ${modules}`}
        shapeRendering="crispEdges"
      >
        <path d={path} fill="currentColor" />
      </svg>
    </div>
  );
}
