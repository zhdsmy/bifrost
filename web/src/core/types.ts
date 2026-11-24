export type UiLang = "zh-CN" | "en";
export type UiMode = "dark" | "light" | "system";

export interface UiConfig {
  lang: UiLang;
  mode: UiMode;
}

export type PageState =
  | "disabled"
  | "conflict"
  | "core_missing"
  | "starting"
  | "needs_login"
  | "needs_approval"
  | "stopped"
  | "running"
  | "error";

export type SnatMode = "auto" | "on" | "off";
export type CoreArch = "arm" | "arm64";
export type PeerPath = "direct" | "peer-relay" | "derp";

export type SettingKey =
  | "advertise_routes"
  | "advertise_exit_node"
  | "accept_routes"
  | "hostname"
  | "port"
  | "local_access"
  | "lan_masq"
  | "snat"
  | "magicdns"
  | "no_logs"
  | "mirror";

export interface CoreLatest {
  tailscale: string;
  revision: number;
  serial: number;
  tag: string;
  variant?: CoreVariant;
}

export type CoreVariant = "normal" | "upx";

export interface PluginUpdate {
  version: string;
  tag: string;
  url: string;
}

export interface CoreBuildInfo {
  go: string;
  commit: string;
  omit: string[];
}

export interface CoreInfo {
  tailscale: string;
  revision: number;
  serial: number;
  arch: string;
  variant?: CoreVariant;
  kernel_arch: string;
  size: number;
  installed: number;
  prev: boolean;
  update: CoreLatest | null;
  check?: {
    checked: number;
    status: string;
    error: string | null;
  };
  build: CoreBuildInfo | null;
}

export interface SelfInfo {
  hostname: string;
  dns_name: string;
  ips: string[];
  tailnet: string;
  magicdns_suffix: string;
  control: string;
  official: boolean;
  key_expiry: string;
  relay: string;
  online: boolean;
}

export interface PrefsInfo {
  advertise_routes: string[];
  advertise_exit_node: boolean;
  accept_routes: boolean;
  hostname: string;
}

export interface RouteStatus {
  cidr: string;
  approved: boolean;
}

export interface SettingsInfo {
  port: number;
  local_access: boolean;
  lan_masq: boolean;
  snat: SnatMode;
  snat_effective: boolean;
  magicdns: boolean;
  no_logs: boolean;
  no_logs_forced: boolean;
  mirror: string;
}

export interface PeerInfo {
  name: string;
  dns_name: string;
  ip: string;
  ips: string[];
  os: string;
  online: boolean;
  path: PeerPath;
  relay: string;
  last_handshake: number;
  rx: number;
  tx: number;
  exit_node_option: boolean;
  routes: string[];
}

export interface StatusData {
  schema: number;
  time: number;
  state: PageState;
  error: string | null;
  plugin: {
    version: string;
    enabled: boolean;
    update?: PluginUpdate | null;
  };
  core: CoreInfo;
  daemon: {
    running: boolean;
    pid: number | null;
    restarts: number;
  };
  conflict: {
    original_installed: boolean;
    original_running: boolean;
  };
  self: SelfInfo | null;
  prefs: PrefsInfo | null;
  routes: RouteStatus[];
  exit_node: {
    advertised: boolean;
    approved: boolean;
  };
  settings: SettingsInfo;
  lan: {
    ip: string;
    cidr: string;
    sw_mode: number;
  };
  dns: {
    conf_dir: boolean;
    active: boolean;
  };
  auth_url: string;
  health: string[];
  checks: string[];
  peers: PeerInfo[];
}

export type JobName = "daemon" | "login" | "migrate" | "update" | "netcheck";

export interface JobState<TData = unknown> {
  schema: number;
  job: JobName;
  running: boolean;
  phase: string;
  progress: number | null;
  ok: boolean | null;
  code: string | null;
  started: number;
  finished: number | null;
  pid: number;
  data: TData;
}

export type JobProgressState<TData = unknown> = Pick<JobState<TData>,
  "running" | "phase" | "progress" | "ok" | "code" | "data">;

export interface LoginJobData {
  action?: "login" | "relogin";
  official?: boolean;
}

export interface MigrateJobData {
  manual_stop?: boolean;
  rolled_back?: boolean;
  cleanup_error?: string;
  backup_cleanup_pending?: boolean;
}

export interface UpdateJobData {
  action?: "check" | "update" | "rollback" | "arch" | "type";
  latest?: CoreLatest | null;
  plugin_update?: PluginUpdate | null;
  variant?: CoreVariant;
  up_to_date?: boolean;
  kept_prev?: boolean;
}

export interface NetcheckDerp {
  code: string;
  latency_ms: number;
}

export interface NetcheckReport {
  udp: boolean;
  ipv4: boolean;
  ipv6: boolean;
  mapping_varies: boolean | null;
  portmap: string;
  preferred_derp: string;
  derp: NetcheckDerp[];
}

export interface NetcheckJobData {
  report?: NetcheckReport;
}

export interface DiagData {
  schema: number;
  time: number;
  tun: boolean;
  fw_complete: boolean | null;
  conflict: boolean;
  wan_cgnat: boolean | null;
  jffs_free_kb: number | null;
  time_synced: boolean | null;
  dnsmasq_conf_dir: boolean;
}

export interface PingResult {
  latency_ms: number;
  path: PeerPath;
  relay: string;
}

export type SetValue = string | boolean | number | string[];

export interface SetResult {
  value?: SetValue;
  job?: JobName;
}

export interface JobStartResult {
  job: JobName;
}
