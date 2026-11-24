// Fictional example fixtures covering every PLAN 7.1 state and section 6 file.
// Uses only example.ts.net, 100.64.0.0/10, 192.168.1.0/24, and RFC 5737 doc ranges.

export const SAMPLE_NOW = 1795430000;

export const SAMPLE_BUILD = {
  go: "1.27.4",
  commit: "cbc74fe48ef1b1649f69a4d9a602319427e25102",
  omit: [
    "aws", "bird", "tap", "kube", "completion", "completion_scripts",
    "systray", "tpm", "debugeventbus", "syspolicy", "capture", "ssh",
    "taildrop", "clientupdate", "webclient", "drive", "desktop_sessions",
    "webbrowser", "networkmanager", "resolved", "dbus", "synology",
    "sdnotify", "flashappliance", "cloud",
  ],
};

// Sorted online first, then by name (contract section 6.1).
export const SAMPLE_PEERS = [
  {
    name: "office-gw",
    dns_name: "office-gw.example.ts.net",
    ip: "100.64.0.3",
    ips: ["100.64.0.3"],
    os: "linux",
    online: true,
    path: "derp",
    relay: "tok",
    last_handshake: SAMPLE_NOW - 140,
    rx: 4_194_304,
    tx: 2_097_152,
    exit_node_option: true,
    routes: ["192.0.2.0/24"],
  },
  {
    name: "relay-box",
    dns_name: "relay-box.example.ts.net",
    ip: "100.64.0.4",
    ips: ["100.64.0.4"],
    os: "linux",
    online: true,
    path: "peer-relay",
    relay: "",
    last_handshake: SAMPLE_NOW - 45,
    rx: 1_048_576,
    tx: 524_288,
    exit_node_option: false,
    routes: ["192.0.2.0/24"],
  },
  {
    name: "workstation",
    dns_name: "workstation.example.ts.net",
    ip: "100.64.0.2",
    ips: ["100.64.0.2", "fd7a:115c:a1e0::2"],
    os: "macOS",
    online: true,
    path: "direct",
    relay: "",
    last_handshake: SAMPLE_NOW - 18,
    rx: 15_728_640,
    tx: 42_991_616,
    exit_node_option: false,
    routes: [],
  },
  {
    name: "tablet",
    dns_name: "tablet.example.ts.net",
    ip: "100.64.0.5",
    ips: ["100.64.0.5"],
    os: "iOS",
    online: false,
    path: "derp",
    relay: "hkg",
    last_handshake: SAMPLE_NOW - 7200,
    rx: 327_680,
    tx: 131_072,
    exit_node_option: false,
    routes: [],
  },
];

function baseRunningStatus() {
  return {
    schema: 1,
    time: SAMPLE_NOW,
    state: "running",
    error: null,
    plugin: { version: "0.1.0", enabled: true },
    core: {
      tailscale: "1.104.7",
      revision: 1,
      serial: 7,
      arch: "arm",
      kernel_arch: "aarch64",
      size: 25_100_448,
      installed: 1795000000,
      prev: true,
      update: null,
      build: structuredClone(SAMPLE_BUILD),
    },
    daemon: { running: true, pid: 1234, restarts: 0 },
    conflict: { original_installed: false, original_running: false },
    self: {
      hostname: "home-router",
      dns_name: "home-router.example.ts.net",
      ips: ["100.64.0.1", "fd7a:115c:a1e0::1"],
      tailnet: "example.ts.net",
      magicdns_suffix: "example.ts.net",
      control: "",
      official: true,
      key_expiry: "2027-05-01T00:00:00Z",
      relay: "tok",
      online: true,
    },
    prefs: {
      advertise_routes: ["192.168.1.0/24", "192.0.2.0/24"],
      advertise_exit_node: false,
      accept_routes: false,
      hostname: "home-router",
    },
    routes: [
      { cidr: "192.168.1.0/24", approved: true },
      { cidr: "192.0.2.0/24", approved: false },
    ],
    exit_node: { advertised: false, approved: false },
    settings: {
      port: 41641,
      local_access: true,
      lan_masq: true,
      snat: "auto",
      snat_effective: false,
      magicdns: false,
      no_logs: true,
      no_logs_forced: false,
      mirror: "",
    },
    lan: { ip: "192.168.1.1", cidr: "192.168.1.0/24", sw_mode: 1 },
    dns: { conf_dir: true, active: false },
    auth_url: "",
    health: [],
    checks: [],
    peers: structuredClone(SAMPLE_PEERS),
  };
}

export function createStatusFixture(name = "running") {
  const s = baseRunningStatus();
  switch (name) {
    case "running":
      return s;
    case "disabled":
      return {
        ...s,
        state: "disabled",
        plugin: { version: "0.1.0", enabled: false },
        daemon: { running: false, pid: null, restarts: 0 },
        conflict: { original_installed: true, original_running: false },
        self: null,
        prefs: null,
        routes: [],
        peers: [],
      };
    case "conflict":
      return {
        ...s,
        state: "conflict",
        plugin: { version: "0.1.0", enabled: true },
        daemon: { running: false, pid: null, restarts: 0 },
        conflict: { original_installed: true, original_running: true },
        self: null,
        prefs: null,
        routes: [],
        peers: [],
      };
    case "core_missing":
      return {
        ...s,
        state: "core_missing",
        core: {
          ...s.core,
          tailscale: "",
          revision: 0,
          serial: 0,
          size: 0,
          installed: 0,
          prev: false,
          build: null,
        },
        daemon: { running: false, pid: null, restarts: 0 },
        self: null,
        prefs: null,
        routes: [],
        peers: [],
      };
    case "starting":
      return {
        ...s,
        state: "starting",
        self: null,
        prefs: null,
        routes: [],
        peers: [],
      };
    case "needs_login":
      return {
        ...s,
        state: "needs_login",
        self: { ...s.self, ips: [], dns_name: "", tailnet: "", magicdns_suffix: "", online: false, relay: "" },
        routes: [],
        peers: [],
        auth_url: "",
      };
    case "needs_login_qr":
      return {
        ...s,
        state: "needs_login",
        self: { ...s.self, ips: [], dns_name: "", tailnet: "", magicdns_suffix: "", online: false, relay: "" },
        routes: [],
        peers: [],
        auth_url: "https://example.org/a/demo-auth-session-001",
      };
    case "needs_approval":
      return {
        ...s,
        state: "needs_approval",
        self: { ...s.self, online: false },
        peers: [],
      };
    case "stopped":
      return {
        ...s,
        state: "stopped",
        self: { ...s.self, online: false },
      };
    case "error":
      return {
        ...s,
        state: "error",
        error: "watchdog_gave_up",
        daemon: { running: false, pid: null, restarts: 3 },
        self: null,
        prefs: null,
        routes: [],
        checks: ["watchdog_gave_up", "fw_incomplete"],
        health: ["not in map poll"],
        peers: [],
      };
    default:
      return s;
  }
}

export const SAMPLE_NETCHECK_REPORT = {
  udp: true,
  ipv4: true,
  ipv6: true,
  mapping_varies: false,
  portmap: "UPnP",
  preferred_derp: "tok",
  derp: [
    { code: "tok", latency_ms: 28 },
    { code: "hkg", latency_ms: 41 },
    { code: "sin", latency_ms: 68 },
  ],
};

export const SAMPLE_DIAG = {
  schema: 1,
  time: SAMPLE_NOW,
  tun: true,
  fw_complete: true,
  conflict: false,
  wan_cgnat: false,
  jffs_free_kb: 18432,
  time_synced: true,
  dnsmasq_conf_dir: true,
};

export const SAMPLE_LOGS_TEXT = [
  "Redacted: public IPv4 (<ipv4>), IPv6 (<ipv6>), email (<email>), tailnet (<tailnet>), auth URL (<auth-url>), keys (<key>), MAC (<mac>).",
  "== summary ==",
  "plugin_version: 0.1.0",
  "core_version: 1.104.7-1 (arm)",
  "state: running",
  "backend_state: Running",
  "port: 41641",
  "local_access: 1",
  "lan_masq: 1",
  "snat: auto (effective=0)",
  "magicdns: 0",
  "no_logs: 1",
  "tun: ok",
  "fw_complete: ok",
  "== bifrost.log ==",
  "2026-11-23 20:00:01 [daemon] started bifrostd pid=1234",
  "2026-11-23 20:00:02 [fw] applied BIFROST_INPUT BIFROST_FORWARD BIFROST_POSTROUTING BIFROST_PREROUTING",
  "2026-11-23 20:02:00 [watchdog] ok",
  "== bifrostd.log ==",
  "2026/11/23 20:00:01 controlclient: connected to <tailnet> via derp-tok",
  "2026/11/23 20:00:02 magicsock: endpoints changed: <ipv4>:41641",
].join("\n") + "\n";

export const SAMPLE_LATEST_CORE = {
  tailscale: "1.106.0",
  revision: 1,
  serial: 8,
  tag: "core-1.106.0-1",
};
