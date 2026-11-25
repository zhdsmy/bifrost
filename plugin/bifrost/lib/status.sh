# shellcheck shell=sh
# Status file generator ($BIFROST_UPLOAD/bifrost_status.json).
# Contract file: see docs/dev/contract.md, sections 6.1 and 8.
# No "local" in POSIX sh: function variables use a _<abbr>_ prefix.
# BIFROST_WATCHDOG_WINDOW is owned by daemon.sh (sourced before status.sh).

: "${BIFROST_STATUS_MAX_PEERS:=500}"
: "${BIFROST_MIN_EPOCH:=1700000000}"

# Filter shared by the page and the diagnostics fallback (contract section 8).
status_core_arch_jq() {
    printf '%s' 'if .arch == "arm" or .arch == "arm64" then .arch else "" end'
}

# status_time_synced: print "true", "false", or "null" (could not check).
# Shared with diag.sh (single source of truth for clock sync check).
status_time_synced() {
    _sts_now=$(now)
    _sts_ntp=$(nvram get ntp_ready 2>/dev/null)
    if [ "$_sts_now" -lt "$BIFROST_MIN_EPOCH" ] 2>/dev/null; then
        echo false
        return 0
    fi
    case "$_sts_ntp" in
        1) echo true ;;
        0) echo false ;;
        *) echo null ;;
    esac
}

# _status_restarts <now>: count watchdog restarts within $BIFROST_WATCHDOG_WINDOW.
_status_restarts() {
    _srw_file="$BIFROST_RUN/watchdog.restarts"
    [ -r "$_srw_file" ] || {
        echo 0
        return 0
    }
    _srw_cut=$(($1 - BIFROST_WATCHDOG_WINDOW))
    _srw_n=0
    while IFS= read -r _srw_ts; do
        valid_uint "$_srw_ts" || continue
        [ "$_srw_ts" -ge "$_srw_cut" ] && _srw_n=$((_srw_n + 1))
    done <"$_srw_file"
    printf '%s\n' "$_srw_n"
}

# Store only names needed to redact this boot's logs, outside the upload
# directory. Concurrent refreshes can append the same name harmlessly.
_status_remember_names() (
    umask 077
    while IFS= read -r _srn_name; do
        [ -n "$_srn_name" ] || continue
        grep -Fqx -- "$_srn_name" "$BIFROST_RUN/redact_hints" 2>/dev/null ||
            printf '%s\n' "$_srn_name" >>"$BIFROST_RUN/redact_hints" || exit 1
    done
)

# Recover the last known server if prefs are unavailable. P2 records the
# selected server; an empty value is its official-server default.
_status_last_control() {
    if [ -f "$BIFROST_STATE/control_url" ]; then
        daemon_control_server
    elif [ -f "$BIFROST_RUN/status.control" ]; then
        head -n 1 "$BIFROST_RUN/status.control"
    elif [ -s "$BIFROST_UPLOAD/bifrost_status.json" ] &&
        _slc_old=$(jq -er '.self.control | strings' "$BIFROST_UPLOAD/bifrost_status.json" 2>/dev/null); then
        printf '%s\n' "$_slc_old"
    else
        daemon_control_server
    fi
}

# Emit control and route cache updates, redaction terms, then the compact page JSON.
_status_render_jq() {
    # shellcheck disable=SC2016 # dollar-prefixed variables belong to jq.
    _dns_jq -nr \
        --rawfile st_text "$_sr_st_file" \
        --rawfile pr_text "$_sr_pr_file" \
        --rawfile man_text "$_sr_man_file" \
        --rawfile prev_text "$_sr_prev_file" \
        --rawfile previous_routes "$_sr_routes_file" \
        --rawfile lat_text "$_sr_lat_file" \
        --rawfile chk_text "$_sr_chk_file" \
        --argjson now "$_sr_now" \
        --arg fstate "$_sr_fstate" \
        --arg ferr "$_sr_ferr" \
        --arg pver "$_sr_pver" \
        --argjson enabled "$_sr_enabled_j" \
        --arg karch "$_sr_karch" \
        --argjson cinst "$_sr_core_inst" \
        --argjson cprev "$_sr_prev" \
        --argjson cprev_size "$_sr_prev_size" \
        --arg skind "${_CS_KIND:-unknown}" \
        --arg sfs "$_CS_FS" \
        --arg stotal "$_CS_TOTAL_KB" \
        --arg sfree "$_CS_FREE_KB" \
        --argjson drun "$_sr_drun" \
        --argjson dpid "$_sr_dpid_json" \
        --argjson restarts "$_sr_restarts" \
        --argjson oinst "$_sr_orig_inst" \
        --argjson orun "$_sr_orig_run" \
        --argjson port "$_sr_port" \
        --argjson la "$_sr_la_j" \
        --argjson masq "$_sr_masq_j" \
        --arg snat "$_sr_snat" \
        --argjson snat_eff "$_sr_snat_eff" \
        --argjson mdns "$_sr_mdns_j" \
        --argjson nologs "$_sr_nologs_j" \
        --arg mirror "$_sr_mirror" \
        --arg lan_ip "$_sr_lan_ip" \
        --arg lan_cidr "$_sr_lan_cidr" \
        --argjson sw_mode "$_sr_sw_json" \
        --argjson dns_active "$_sr_dns_active" \
        --argjson chk_fw "$_sr_chk_fw" \
        --argjson chk_clk "$_sr_chk_clk" \
        --arg last_control "$(_status_last_control)" \
        --argjson max_peers "$BIFROST_STATUS_MAX_PEERS" \
        '
        def strip_dot: (. // "") | sub("\\.$"; "");
        def parse_ts:
            if type != "string" or . == "" or startswith("0001-01-01") then 0
            else
                (try (
                    capture("^(?<dt>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:[0-9]{2})$")
                    | ((.dt + "Z") | fromdateiso8601)
                      - (if .tz == "Z" then 0
                         else
                           (.tz[0:1] as $s
                            | ((.tz[1:3] | tonumber) * 3600 + (.tz[4:6] | tonumber) * 60)
                            | if $s == "-" then -. else . end)
                         end)
                ) catch 0)
            end;
        def clean_expiry:
            if type != "string" or . == "" or startswith("0001-01-01") then "" else . end;
        def object_or_null: try (fromjson | if type == "object" then . else null end) catch null;
        def semver: try (split(".") | map(tonumber)) catch null;
        '"$(fw_exit_jq)"'
        def installed_arch: '"$(status_core_arch_jq)"';
        '"$(dns_policy_jq)"'

        ($st_text | object_or_null) as $st |
        (if $st != null then ($pr_text | object_or_null) else null end) as $pr |
        ($man_text | object_or_null) as $man |
        ($prev_text | object_or_null) as $prev_man |
        ($lat_text | object_or_null) as $lat |
        ($chk_text | object_or_null) as $chk |

        (if $fstate != "" then {s: $fstate, e: $ferr}
         elif $st == null then {s: "error", e: "cli_failed"}
         else
            (($st.BackendState // "") as $bs |
             if $bs == "NoState" or $bs == "Starting" then {s: "starting", e: ""}
             elif $bs == "NeedsLogin" then {s: "needs_login", e: ""}
             elif $bs == "NeedsMachineAuth" then {s: "needs_approval", e: ""}
             elif $bs == "Stopped" then {s: "stopped", e: ""}
             elif $bs == "Running" then {s: "running", e: ""}
             else {s: "error", e: "internal"} end)
         end) as $se |
        $se.s as $state |
        $se.e as $err |

        ($man.serial // 0) as $man_serial |
        ($man | installed_arch) as $core_arch |
        ($man.variant // "normal") as $core_variant |
        ($man.assets[$core_arch].raw_size // 0) as $core_size |
        ($man.assets[$core_arch].raw_sha256 // "" |
            if type == "string" and test("^[0-9a-f]{64}\\z") then . else null end) as $core_sha |
        (if $cprev and $prev_man != null then
            {
                tailscale: ($prev_man.tailscale // ""),
                revision: ($prev_man.revision // 0),
                serial: ($prev_man.serial // 0),
                arch: ($prev_man | installed_arch),
                variant: ($prev_man.variant // "normal")
            }
         else null end) as $prev_info |
        (if $chk != null and (($chk.core.latest.serial | type) == "number") then $chk.core.latest else $lat end) as $latest |
        (if $latest != null and (($latest.serial | type) == "number") and ($latest.serial > $man_serial) then
            {
                tailscale: ($latest.tailscale // ""),
                revision: ($latest.revision // 0),
                serial: $latest.serial,
                tag: ($latest.tag // ""),
                variant: ($latest.variant // $core_variant)
            }
         else null end) as $core_update |

        ((if $pr != null then ($pr.ControlURL // "") else $last_control end) | sub("/+$"; "")) as $url |
        ($url == "" or $url == "https://controlplane.tailscale.com" or $url == "https://login.tailscale.com") as $official |
        (if $official then "" else $url end) as $control |
        ($st | dns_suffix) as $msuf |

        (if $st == null then null else
            {
                hostname: ($st.Self.HostName // ""),
                dns_name: ($st.Self.DNSName | strip_dot),
                ips: ($st.TailscaleIPs // $st.Self.TailscaleIPs // []),
                tailnet: ($st.CurrentTailnet.Name // ""),
                magicdns_suffix: $msuf,
                control: $control,
                official: $official,
                key_expiry: ($st.Self.KeyExpiry | clean_expiry),
                relay: ($st.Self.Relay // ""),
                online: ($st.Self.Online == true)
            }
         end) as $self_obj |

        (if $pr == null then null else
            ($pr.AdvertiseRoutes // []) as $adv_all |
            ($adv_all | map(select(. != "0.0.0.0/0" and . != "::/0"))) as $adv_sub |
            ($adv_all | exit_routes) as $adv_exit |
            {
                advertise_routes: $adv_sub,
                advertise_exit_node: $adv_exit,
                accept_routes: ($pr.RouteAll == true),
                hostname: ($pr.Hostname // "")
            }
         end) as $prefs_obj |

        (if $st == null then [] else (($st.Self.PrimaryRoutes // []) + ($st.Self.AllowedIPs // [])) end) as $approved_set |
        ($previous_routes | object_or_null) as $last |
        (if $prefs_obj == null then ($last.routes // []) else
            ($prefs_obj.advertise_routes | map(. as $r | {
                cidr: $r,
                approved: (($approved_set | index($r)) != null)
            }))
         end) as $routes_arr |

        {
            advertised: (if $prefs_obj != null then $prefs_obj.advertise_exit_node else ($last.exit_node.advertised // false) end),
            approved: (if $st != null then
                ($st | approved_exit)
                else false end)
        } as $exit_obj |

        (if $pr != null and ((($pr.CorpDNS // false) != false) or (($pr.NetfilterMode // 0) != 0 and ($pr.NetfilterMode // 0) != "off") or (($pr.ShieldsUp // false) != false))
         then true else false end) as $chk_prefs |

        ($st | dns_plan((($drun | not) or $state == "disabled" or $state == "core_missing" or $state == "conflict"); $err) | .stale) as $chk_dns |

        ($err == "watchdog_gave_up") as $chk_wd |

        (if $st == null then [] else
            (($st.Peer // {}) | to_entries | map(.value) | map(select(.ShareeNode != true)) | map(
                (.TailscaleIPs // []) as $pips |
                (if (.HostName // "") != "" then .HostName
                 elif (.DNSName // "") != "" then ((.DNSName | strip_dot) | split(".")[0])
                 else ($pips[0] // "") end) as $pname |
                (if (.CurAddr // "") != "" then "direct"
                 elif (.PeerRelay // "") != "" then "peer-relay"
                 else "derp" end) as $ppath |
                (if $ppath == "derp" then (.Relay // "") else "" end) as $prelay |
                (if (.PrimaryRoutes | type) == "array" then .PrimaryRoutes
                 else
                    ($pips | map(. + "/32", . + "/128")) as $own |
                    (.AllowedIPs // []) | map(select((. as $r | $own | index($r)) == null))
                 end | map(select(. != "0.0.0.0/0" and . != "::/0"))) as $proutes |
                {
                    name: $pname,
                    dns_name: (.DNSName | strip_dot),
                    ip: (($pips | map(select(contains(":") | not))[0]) // $pips[0] // ""),
                    ips: $pips,
                    os: (.OS // ""),
                    online: (.Online == true),
                    path: $ppath,
                    relay: $prelay,
                    last_handshake: (.LastHandshake | parse_ts),
                    rx: (.RxBytes // 0),
                    tx: (.TxBytes // 0),
                    exit_node_option: (.ExitNodeOption == true),
                    routes: $proutes
                }
            ) | sort_by([(if .online then 0 else 1 end), (.name | ascii_downcase), .name, .ip]) | .[:$max_peers])
         end) as $peers_arr |

        {
            schema: 1,
            time: $now,
            state: $state,
            error: (if $err == "" then null else $err end),
            plugin: {
                version: $pver,
                enabled: $enabled,
                # A check recorded before an upgrade must not offer the
                # version that is now installed.
                update: ($chk.plugin.update // null |
                    if . != null and ((.version | semver) // []) > (($pver | semver) // [])
                    then . else null end)
            },
            core: {
                tailscale: ($man.tailscale // ""),
                revision: ($man.revision // 0),
                serial: $man_serial,
                arch: $core_arch,
                variant: $core_variant,
                kernel_arch: $karch,
                size: $core_size,
                sha256: $core_sha,
                installed: $cinst,
                prev: $cprev,
                prev_size: $cprev_size,
                prev_info: $prev_info,
                storage: {
                    kind: $skind,
                    fs: (if $sfs == "" then null else $sfs end),
                    total: (if $stotal == "" then null else ($stotal | tonumber) * 1024 end),
                    free: (if $sfree == "" then null else ($sfree | tonumber) * 1024 end)
                },
                update: $core_update,
                check: {
                    checked: ($chk.checked // 0),
                    status: ($chk.core.status // "unknown"),
                    error: ($chk.core.error // null)
                },
                build: (if ($man.build | type) == "object" then $man.build else null end)
            },
            daemon: { running: $drun, pid: $dpid, restarts: $restarts },
            conflict: { original_installed: $oinst, original_running: $orun },
            self: $self_obj,
            prefs: $prefs_obj,
            routes: $routes_arr,
            exit_node: $exit_obj,
            settings: {
                port: $port,
                local_access: $la,
                lan_masq: $masq,
                snat: $snat,
                snat_effective: $snat_eff,
                magicdns: $mdns,
                no_logs: $nologs,
                no_logs_forced: ($official | not),
                mirror: $mirror
            },
            lan: { ip: $lan_ip, cidr: $lan_cidr, sw_mode: $sw_mode },
            dns: { conf_dir: $conf_dir, active: $dns_active },
            auth_url: (if $state == "needs_login" and $st != null then ($st.AuthURL // "") else "" end),
            health: (if $st != null then ($st.Health // []) else [] end),
            checks: (
                (if $chk_fw then ["fw_incomplete"] else [] end) +
                (if $chk_prefs then ["prefs_drift"] else [] end) +
                (if $chk_dns then ["dns_stale"] else [] end) +
                (if $chk_wd then ["watchdog_gave_up"] else [] end) +
                (if $chk_clk then ["clock_unsynced"] else [] end)
            ),
            peers: $peers_arr
        } as $doc |
        (if $pr == null then "-" else $control end),
        (if $pr == null then "-" else ({routes:$routes_arr, exit_node:{advertised:$exit_obj.advertised}} | tojson) end),
        (($self_obj.magicdns_suffix, $self_obj.tailnet, ($control | select(length > 0) | sub("^https?://"; "") | split("/")[0] | split(":")[0]))
            | strings | select(length > 0) | gsub("[\\r\\n]"; "")),
        ($doc | tojson)
        '
}

# status_refresh: write $BIFROST_UPLOAD/bifrost_status.json (contract 6.1).
# Calls at most 2 CLI commands (status --json, debug prefs), parses status once
# in jq, and never reads or executes the core binary.
status_refresh() {
    _sr_now=$(now)
    [ -d "$BIFROST_RUN" ] || mkdir -p "$BIFROST_RUN"
    [ -d "$BIFROST_UPLOAD" ] || mkdir -p "$BIFROST_UPLOAD"

    # Plugin info & settings
    _sr_pver=""
    if [ -r "$BIFROST_VERSION_FILE" ]; then
        _sr_pver=$(head -n 1 "$BIFROST_VERSION_FILE" | tr -d '\r\n')
    fi
    _sr_enabled=$(cfg bifrost_enable)
    _sr_port=$(cfg bifrost_port)
    _sr_la=$(cfg bifrost_local_access)
    _sr_masq=$(cfg bifrost_lan_masq)
    _sr_snat=$(cfg bifrost_snat)
    if fw_snat_effective; then _sr_snat_eff=true; else _sr_snat_eff=false; fi
    _sr_magicdns=$(cfg bifrost_magicdns)
    _sr_nologs=$(cfg bifrost_no_logs)
    _sr_mirror=$(cfg bifrost_mirror)

    if [ "$_sr_enabled" = 1 ]; then _sr_enabled_j=true; else _sr_enabled_j=false; fi
    if [ "$_sr_la" = 1 ]; then _sr_la_j=true; else _sr_la_j=false; fi
    if [ "$_sr_masq" = 1 ]; then _sr_masq_j=true; else _sr_masq_j=false; fi
    if [ "$_sr_magicdns" = 1 ]; then _sr_mdns_j=true; else _sr_mdns_j=false; fi
    if [ "$_sr_nologs" = 1 ]; then _sr_nologs_j=true; else _sr_nologs_j=false; fi

    # Core metadata: never read or execute the 25 MB core binary; size/build come from manifest.
    _sr_core_ok=0
    _sr_core_inst=null
    if [ -f "$BIFROST_CORE" ]; then
        [ -x "$BIFROST_CORE" ] && _sr_core_ok=1
        _sr_mt=$(date -r "$BIFROST_CORE" +%s 2>/dev/null)
        valid_uint "$_sr_mt" && _sr_core_inst=$_sr_mt
    fi
    _sr_karch=$(uname -m 2>/dev/null || echo "")
    _sr_prev=false
    _sr_prev_size=0
    if [ -f "$BIFROST_BIN/bifrostd.prev.gz" ]; then
        _sr_prev=true
        _sr_prev_size=$(file_size "$BIFROST_BIN/bifrostd.prev.gz") || _sr_prev_size=0
        valid_uint "$_sr_prev_size" || _sr_prev_size=0
    fi
    core_storage || :

    # Daemon & conflict probes
    _sr_dpid=$(daemon_pid 2>/dev/null) || _sr_dpid=""
    if [ -n "$_sr_dpid" ]; then
        _sr_drun=true
        _sr_dpid_json=$_sr_dpid
    else
        _sr_drun=false
        _sr_dpid_json=null
    fi
    _sr_restarts=$(_status_restarts "$_sr_now")
    if orig_installed; then _sr_orig_inst=true; else _sr_orig_inst=false; fi
    if orig_running; then _sr_orig_run=true; else _sr_orig_run=false; fi

    # Daemon error file (written by P2 on failure)
    _sr_derr=""
    if [ -r "$BIFROST_DAEMON_ERR" ]; then
        _sr_raw_err=$(head -n 1 "$BIFROST_DAEMON_ERR" | tr -d ' \t\r\n')
        valid_name "$_sr_raw_err" && _sr_derr=$_sr_raw_err
    fi

    # Determine fixed state & error in contract 6.1 steps 1-5 order.
    _sr_fstate=""
    _sr_ferr=""
    if [ "$_sr_core_ok" -eq 0 ]; then
        _sr_fstate=core_missing
    elif [ "$_sr_enabled" != 1 ]; then
        _sr_fstate=disabled
    elif [ "$_sr_orig_run" = true ]; then
        _sr_fstate=conflict
    elif [ -n "$_sr_derr" ]; then
        _sr_fstate=error
        _sr_ferr=$_sr_derr
    elif [ "$_sr_drun" = false ]; then
        _sr_fstate=error
        _sr_ferr=start_failed
    fi

    # Temp files avoid ARG_MAX on large tailnets.
    _sr_st_tmp="$BIFROST_RUN/status_st.$$.json"
    _sr_pr_tmp="$BIFROST_RUN/status_pr.$$.json"
    _sr_out_tmp="$BIFROST_RUN/status_out.$$.tmp"
    _sr_st_file=/dev/null
    _sr_pr_file=/dev/null
    _sr_st_rc=0

    # Query daemon only when it is running (at most 2 CLI calls total).
    if [ "$_sr_drun" = true ]; then
        (umask 077; ts_cli status --json >"$_sr_st_tmp") 2>/dev/null
        _sr_st_rc=$?
        if [ "$_sr_st_rc" -eq 0 ] && [ -s "$_sr_st_tmp" ]; then
            _sr_st_file=$_sr_st_tmp
            if (umask 077; ts_cli debug prefs >"$_sr_pr_tmp") 2>/dev/null && [ -s "$_sr_pr_tmp" ]; then
                _sr_pr_file=$_sr_pr_tmp
            fi
        elif [ -z "$_sr_fstate" ]; then
            if [ "$_sr_st_rc" -eq 124 ]; then
                _sr_fstate=error
                _sr_ferr=timeout
            elif [ ! -e "$BIFROST_SOCK" ]; then
                _sr_fstate=starting
            else
                _sr_fstate=error
                _sr_ferr=cli_failed
            fi
        fi
    fi

    # LAN & DNS info (read tiny dnsmasq conf directly without calling jq)
    _sr_lan_ip=$(nvram get lan_ipaddr 2>/dev/null)
    valid_ipv4 "$_sr_lan_ip" || _sr_lan_ip=""
    _sr_lan_cidr=$(lan_cidr 2>/dev/null) || _sr_lan_cidr=""
    _sr_sw=$(nvram get sw_mode 2>/dev/null)
    if valid_uint "$_sr_sw"; then _sr_sw_json=$_sr_sw; else _sr_sw_json=null; fi

    _dns_observe
    # shellcheck disable=SC2154 # populated by _dns_observe in dns.sh.
    if [ "$_dns_conf_dir" = true ] && [ -s "$BIFROST_DNSMASQ_CONF" ]; then
        _sr_dns_active=true
    else
        _sr_dns_active=false
    fi

    _sr_chk_fw=false
    if [ "$_sr_drun" = true ] && ! fw_complete; then
        _sr_chk_fw=true
    fi
    _sr_chk_clk=false
    [ "$(status_time_synced)" = false ] && _sr_chk_clk=true

    _sr_man_file=/dev/null
    _sr_prev_file=/dev/null
    _sr_lat_file=/dev/null
    _sr_chk_file=/dev/null
    [ -f "$BIFROST_MANIFEST" ] && _sr_man_file=$BIFROST_MANIFEST
    [ -f "$BIFROST_BIN/bifrostd.prev.json" ] && _sr_prev_file="$BIFROST_BIN/bifrostd.prev.json"
    [ -f "$BIFROST_RUN/core_latest.json" ] && _sr_lat_file="$BIFROST_RUN/core_latest.json"
    [ -f "$BIFROST_HOME/core-check.json" ] && _sr_chk_file="$BIFROST_HOME/core-check.json"

    # The last advertised values are small and independent of the live peer
    # list. On the first refresh after an upgrade, use the existing page once.
    _sr_routes_file="$BIFROST_RUN/status.routes"
    if [ ! -f "$_sr_routes_file" ]; then
        _sr_routes_file="$BIFROST_UPLOAD/bifrost_status.json"
        [ -f "$_sr_routes_file" ] || _sr_routes_file=/dev/null
    fi
    _sr_rc=1
    if (umask 077; _status_render_jq >"$_sr_out_tmp") 2>/dev/null && [ -s "$_sr_out_tmp" ]; then
        { IFS= read -r _sr_control && IFS= read -r _sr_routes; } <"$_sr_out_tmp"
        if [ "$_sr_control" != "-" ] &&
            ! printf '%s\n' "$_sr_control" | cmp -s - "$BIFROST_RUN/status.control"; then
            printf '%s\n' "$_sr_control" | atomic_write "$BIFROST_RUN/status.control" 600
        fi
        if [ "$_sr_routes" != "-" ] &&
            ! printf '%s\n' "$_sr_routes" | cmp -s - "$BIFROST_RUN/status.routes"; then
            printf '%s\n' "$_sr_routes" | atomic_write "$BIFROST_RUN/status.routes" 600
        fi
        if sed '1,2d;$d' "$_sr_out_tmp" | _status_remember_names &&
            tail -n 1 "$_sr_out_tmp" | json_write "$BIFROST_UPLOAD/bifrost_status.json"; then
            _sr_rc=0
        fi
    fi
    rm -f "$_sr_st_tmp" "$_sr_pr_tmp" "$_sr_out_tmp"
    [ "$_sr_rc" = 0 ] || fail internal
}
