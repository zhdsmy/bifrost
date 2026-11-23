// Client-side validation mirroring plugin/bifrost/lib/validate.sh for immediate UI feedback.
// Authoritative validation always runs in the router scripts.

import type { PeerInfo, SelfInfo } from "./types";

export function validUint(value: string): boolean {
  return /^(0|[1-9][0-9]{0,9})$/.test(value);
}

export function validUintRange(value: string, min: number, max: number): boolean {
  if (!validUint(value)) return false;
  const n = Number(value);
  return n >= min && n <= max;
}

export function validPort(value: string): boolean {
  return validUintRange(value, 1024, 65535);
}

export function validBool01(value: string): boolean {
  return value === "0" || value === "1";
}

export function validSnat(value: string): boolean {
  return value === "auto" || value === "on" || value === "off";
}

export function validLang(value: string): boolean {
  return value === "zh-CN" || value === "en";
}

export function validMode(value: string): boolean {
  return value === "dark" || value === "light" || value === "system";
}

export function validArch(value: string): boolean {
  return value === "arm" || value === "arm64";
}

export function validParam(value: string): boolean {
  return value.length >= 1 && value.length <= 512 && /^[A-Za-z0-9._:/,~=@-]+$/.test(value);
}

export function validIpv4(value: string): boolean {
  if (!/^[0-9.]+$/.test(value)) return false;
  const parts = value.split(".");
  if (parts.length !== 4) return false;
  return parts.every((part) => validUintRange(part, 0, 255));
}

export function validCidr4(value: string): boolean {
  const slash = value.indexOf("/");
  if (slash <= 0 || value.indexOf("/", slash + 1) !== -1) return false;
  const ip = value.slice(0, slash);
  const lenStr = value.slice(slash + 1);
  if (!validIpv4(ip) || !validUintRange(lenStr, 1, 32)) return false;
  const len = Number(lenStr);
  const octets = ip.split(".").map(Number);
  for (let i = 0; i < 4; i++) {
    const bits = Math.max(0, Math.min(8, len - i * 8));
    const hostMask = (1 << (8 - bits)) - 1;
    if ((octets[i] & hostMask) !== 0) return false;
  }
  return true;
}

export function validCidr4List(value: string): boolean {
  if (!value || value.startsWith(",") || value.endsWith(",") || value.includes(",,")) {
    return false;
  }
  const items = value.split(",");
  if (items.length > 16) return false;
  const seen = new Set<string>();
  for (const item of items) {
    if (!validCidr4(item) || seen.has(item)) return false;
    seen.add(item);
  }
  return true;
}

export function validHostname(value: string): boolean {
  return value.length >= 1 && value.length <= 63 && /^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/.test(value);
}

export function validLoginServer(value: string): boolean {
  if (!(value.startsWith("http://") || value.startsWith("https://"))) return false;
  if (value.length > 255) return false;
  const rest = value.slice(value.indexOf("://") + 3);
  if (!rest || !/^[A-Za-z0-9.:/_~-]+$/.test(rest)) return false;
  const slash = rest.indexOf("/");
  const hostport = slash === -1 ? rest : rest.slice(0, slash);
  const firstColon = hostport.indexOf(":");
  if (firstColon !== -1 && hostport.indexOf(":", firstColon + 1) !== -1) return false;
  const host = firstColon === -1 ? hostport : hostport.slice(0, firstColon);
  if (firstColon !== -1) {
    const port = hostport.slice(firstColon + 1);
    if (!validUintRange(port, 1, 65535)) return false;
  }
  if (!host || host.startsWith(".") || host.endsWith(".") || host.startsWith("-") || host.includes("..")) {
    return false;
  }
  return /^[A-Za-z0-9.-]+$/.test(host);
}

export function isHttpLoginServer(value: string): boolean {
  return value.startsWith("http://");
}

export function validAuthKey(value: string): boolean {
  return /^[A-Za-z0-9_-]{16,128}$/.test(value);
}

export function validMirror(value: string): boolean {
  if (!value.startsWith("https://") || !value.endsWith("/")) return false;
  if (value.length > 200) return false;
  const rest = value.slice("https://".length);
  if (rest.length < 2) return false;
  return /^[A-Za-z0-9./_-]+$/.test(rest);
}

export function validTailnetIp(value: string): boolean {
  if (value.startsWith("100.")) {
    if (!validIpv4(value)) return false;
    const second = Number(value.split(".")[1]);
    return second >= 64 && second <= 127;
  }
  if (value.toLowerCase().startsWith("fd7a:115c:a1e0:")) {
    return value.length <= 39 && /^[0-9A-Fa-f:]+$/.test(value);
  }
  return false;
}

function ipv4ToNumber(ip: string): number {
  const [a, b, c, d] = ip.split(".").map(Number);
  return ((a * 256 + b) * 256 + c) * 256 + d;
}

export function cidr4Range(cidr: string): [number, number] | null {
  if (!validCidr4(cidr)) return null;
  const [ip, lenStr] = cidr.split("/");
  const start = ipv4ToNumber(ip);
  const size = 2 ** (32 - Number(lenStr));
  return [start, start + size - 1];
}

export function cidr4Overlaps(a: string, b: string): boolean {
  const rangeA = cidr4Range(a);
  const rangeB = cidr4Range(b);
  if (!rangeA || !rangeB) return false;
  return rangeA[0] <= rangeB[1] && rangeB[0] <= rangeA[1];
}

export function findOverlappingPeerRoutes(
  lanCidr: string,
  peers: readonly PeerInfo[],
): Array<{ peer: string; cidr: string }> {
  if (!validCidr4(lanCidr)) return [];
  const matches: Array<{ peer: string; cidr: string }> = [];
  for (const peer of peers) {
    for (const cidr of peer.routes) {
      if (cidr4Overlaps(lanCidr, cidr)) {
        matches.push({ peer: peer.name, cidr });
      }
    }
  }
  return matches;
}

export function isAccessingFromTailnet(hostname: string, self: SelfInfo | null): boolean {
  const clean = hostname.replace(/^\[|\]$/g, "").toLowerCase();
  if (!clean) return false;
  if (validTailnetIp(clean)) return true;
  if (!self) return false;
  if (self.ips.some((ip) => ip.toLowerCase() === clean)) return true;
  const dns = self.dns_name.replace(/\.$/, "").toLowerCase();
  if (dns && clean === dns) return true;
  const suffix = self.magicdns_suffix.replace(/^\.|\.$/g, "").toLowerCase();
  if (suffix && (clean === suffix || clean.endsWith("." + suffix))) return true;
  return false;
}
