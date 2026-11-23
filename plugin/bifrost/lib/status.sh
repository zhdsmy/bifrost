# shellcheck shell=sh
# Status file generator ($BIFROST_UPLOAD/bifrost_status.json).
# Contract file: see docs/dev/contract.md, section 6.1.
# No "local" in POSIX sh: function variables use a _<abbr>_ prefix.

: "${BIFROST_STATUS_MAX_PEERS:=500}"
: "${BIFROST_WATCHDOG_WINDOW:=1800}"
: "${BIFROST_MIN_EPOCH:=1700000000}"

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

# _status_valid_json_obj <file>: 0 when file exists and contains a JSON object.
_status_valid_json_obj() {
    [ -s "$1" ] && jq -e 'type == "object"' "$1" >/dev/null 2>&1
}

# status_refresh: write $BIFROST_UPLOAD/bifrost_status.json (contract 6.1).
# Calls at most 2 CLI commands (status --json, debug prefs) and builds the JSON
# in one jq invocation. Never executes the core binary.
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

    # Core file metadata (read manifest only; never invoke core --version)
    _sr_core_ok=0
    _sr_core_size=0
    _sr_core_inst=null
    if [ -f "$BIFROST_CORE" ] && [ -x "$BIFROST_CORE" ]; then
        _sr_core_ok=1
    fi
    if [ -f "$BIFROST_CORE" ]; then
        _sr_sz=$(file_size "$BIFROST_CORE" 2>/dev/null)
        valid_uint "$_sr_sz" && _sr_core_size=$_sr_sz
        _sr_mt=$(date -r "$BIFROST_CORE" +%s 2>/dev/null)
        valid_uint "$_sr_mt" && _sr_core_inst=$_sr_mt
    fi
    _sr_karch=$(uname -m 2>/dev/null || echo "")
    if [ -f "$BIFROST_BIN/bifrostd.prev.gz" ]; then _sr_prev=true; else _sr_prev=false; fi

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

    # Temp files avoid ARG_MAX on large tailnets (up to 500+ peers).
    _sr_st_tmp="$BIFROST_RUN/status_st.$$.json"
    _sr_pr_tmp="$BIFROST_RUN/status_pr.$$.json"
    _sr_st_file=/dev/null
    _sr_pr_file=/dev/null
    _sr_st_rc=0

    # Determine state & error in exact contract 6.1 precedence order.
    _sr_state=""
    _sr_error=""
    if [ "$_sr_core_ok" -eq 0 ]; then
        _sr_state=core_missing
    elif [ "$_sr_enabled" != 1 ]; then
        _sr_state=disabled
    elif [ "$_sr_orig_run" = true ]; then
        _sr_state=conflict
    elif [ -n "$_sr_derr" ]; then
        _sr_state=error
        _sr_error=$_sr_derr
    elif [ "$_sr_drun" = false ]; then
        _sr_state=error
        _sr_error=start_failed
    fi

    # Query daemon only when it is running (at most 2 CLI calls total).
    if [ "$_sr_drun" = true ]; then
        ts_cli status --json >"$_sr_st_tmp" 2>/dev/null
        _sr_st_rc=$?
        if [ "$_sr_st_rc" -eq 0 ] && _status_valid_json_obj "$_sr_st_tmp"; then
            _sr_st_file=$_sr_st_tmp
            if ts_cli debug prefs >"$_sr_pr_tmp" 2>/dev/null && _status_valid_json_obj "$_sr_pr_tmp"; then
                _sr_pr_file=$_sr_pr_tmp
            fi
        fi
    fi

    # Derive state from BackendState when not already fixed by steps 1-5.
    if [ -z "$_sr_state" ]; then
        if [ "$_sr_st_file" = /dev/null ]; then
            if [ "$_sr_st_rc" -eq 124 ]; then
                _sr_state=error
                _sr_error=timeout
            elif [ ! -e "$BIFROST_SOCK" ]; then
                _sr_state=starting
            else
                _sr_state=error
                _sr_error=cli_failed
            fi
        else
            _sr_bstate=$(jq -r '.BackendState // ""' "$_sr_st_file" 2>/dev/null)
            case "$_sr_bstate" in
                NoState | Starting) _sr_state=starting ;;
                NeedsLogin) _sr_state=needs_login ;;
                NeedsMachineAuth) _sr_state=needs_approval ;;
                Stopped) _sr_state=stopped ;;
                Running) _sr_state=running ;;
                *)
                    _sr_state=error
                    _sr_error=internal
                    ;;
            esac
        fi
    fi

    # LAN & DNS info
    _sr_lan_ip=$(nvram get lan_ipaddr 2>/dev/null)
    valid_ipv4 "$_sr_lan_ip" || _sr_lan_ip=""
    _sr_lan_cidr=$(lan_cidr 2>/dev/null) || _sr_lan_cidr=""
    _sr_sw=$(nvram get sw_mode 2>/dev/null)
    if valid_uint "$_sr_sw"; then _sr_sw_json=$_sr_sw; else _sr_sw_json=null; fi

    if dns_has_conf_dir; then _sr_conf_dir=true; else _sr_conf_dir=false; fi
    if [ "$_sr_conf_dir" = true ] && [ -s "$BIFROST_DNSMASQ_CONF" ]; then
        _sr_dns_active=true
    else
        _sr_dns_active=false
    fi

    # Checks (only codes listed in contract 6.1)
    _sr_chk_fw=false
    if [ "$_sr_drun" = true ] && ! fw_check; then
        _sr_chk_fw=true
    fi
    _sr_chk_dns=false
    if [ "$_sr_magicdns" != 1 ] && [ -e "$BIFROST_DNSMASQ_CONF" ]; then
        _sr_chk_dns=true
    elif [ "$_sr_drun" = true ] && [ "$_sr_state" = running ] && [ "$_sr_magicdns" = 1 ]; then
        _sr_suf=$(jq -r 'if (.MagicDNSSuffix // "") != "" then .MagicDNSSuffix elif (.CurrentTailnet.MagicDNSSuffix // "") != "" then .CurrentTailnet.MagicDNSSuffix else "" end' "$_sr_st_file" 2>/dev/null)
        if [ -n "$_sr_suf" ] && valid_dns_name "$_sr_suf"; then
            dns_check "{\"MagicDNSSuffix\":\"$_sr_suf\"}" || _sr_chk_dns=true
        else
            _sr_chk_dns=true
        fi
    fi
    _sr_chk_wd=false
    [ "$_sr_error" = watchdog_gave_up ] && _sr_chk_wd=true
    _sr_chk_clk=false
    [ "$(status_time_synced)" = false ] && _sr_chk_clk=true

    # Manifest & cached latest manifest
    _sr_man_file=/dev/null
    _status_valid_json_obj "$BIFROST_MANIFEST" && _sr_man_file=$BIFROST_MANIFEST
    _sr_lat_file=/dev/null
    _status_valid_json_obj "$BIFROST_RUN/core_latest.json" && _sr_lat_file="$BIFROST_RUN/core_latest.json"

    jq -n \
        --slurpfile st_a "$_sr_st_file" \
        --slurpfile pr_a "$_sr_pr_file" \
        --slurpfile man_a "$_sr_man_file" \
        --slurpfile lat_a "$_sr_lat_file" \
        --argjson now "$_sr_now" \
        --arg state "$_sr_state" \
        --arg err "$_sr_error" \
        --arg pver "$_sr_pver" \
        --argjson enabled "$([ "$_sr_enabled" = 1 ] && echo true || echo false)" \
        --arg karch "$_sr_karch" \
        --argjson csize "$_sr_core_size" \
        --argjson cinst "$_sr_core_inst" \
        --argjson cprev "$_sr_prev" \
        --argjson drun "$_sr_drun" \
        --argjson dpid "$_sr_dpid_json" \
        --argjson restarts "$_sr_restarts" \
        --argjson oinst "$_sr_orig_inst" \
        --argjson orun "$_sr_orig_run" \
        --argjson port "$_sr_port" \
        --argjson la "$([ "$_sr_la" = 1 ] && echo true || echo false)" \
        --argjson masq "$([ "$_sr_masq" = 1 ] && echo true || echo false)" \
        --arg snat "$_sr_snat" \
        --argjson snat_eff "$_sr_snat_eff" \
        --argjson mdns "$([ "$_sr_magicdns" = 1 ] && echo true || echo false)" \
        --argjson nologs "$([ "$_sr_nologs" = 1 ] && echo true || echo false)" \
        --arg mirror "$_sr_mirror" \
        --arg lan_ip "$_sr_lan_ip" \
        --arg lan_cidr "$_sr_lan_cidr" \
        --argjson sw_mode "$_sr_sw_json" \
        --argjson conf_dir "$_sr_conf_dir" \
        --argjson dns_active "$_sr_dns_active" \
        --argjson chk_fw "$_sr_chk_fw" \
        --argjson chk_dns "$_sr_chk_dns" \
        --argjson chk_wd "$_sr_chk_wd" \
        --argjson chk_clk "$_sr_chk_clk" \
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

        ($st_a[0] // null) as $st |
        ($pr_a[0] // null) as $pr |
        ($man_a[0] // null) as $man |
        ($lat_a[0] // null) as $lat |

        (($man.serial // 0)) as $man_serial |
        (if $man == null then ""
         elif ($man.arch // "") != "" then $man.arch
         elif (($man.assets // {}) | keys | length) == 1 then (($man.assets | keys)[0])
         else "" end) as $core_arch |
        (if $lat != null and (($lat.serial | type) == "number") and ($lat.serial > $man_serial) then
            {
                tailscale: ($lat.tailscale // ""),
                revision: ($lat.revision // 0),
                serial: $lat.serial,
                tag: ($lat.tag // "")
            }
         else null end) as $core_update |

        ((($pr.ControlURL // "") | sub("/+$"; ""))) as $ctrl_raw |
        ($ctrl_raw == "" or $ctrl_raw == "https://controlplane.tailscale.com" or $ctrl_raw == "https://login.tailscale.com") as $official |

        (if $st == null then null else
            {
                hostname: ($st.Self.HostName // ""),
                dns_name: ($st.Self.DNSName | strip_dot),
                ips: ($st.TailscaleIPs // $st.Self.TailscaleIPs // []),
                tailnet: ($st.CurrentTailnet.Name // ""),
                magicdns_suffix: (if ($st.CurrentTailnet.MagicDNSSuffix // "") != "" then $st.CurrentTailnet.MagicDNSSuffix else ($st.MagicDNSSuffix // "") end),
                control: (if $official then "" else $ctrl_raw end),
                official: $official,
                key_expiry: ($st.Self.KeyExpiry | clean_expiry),
                relay: ($st.Self.Relay // ""),
                online: ($st.Self.Online == true)
            }
         end) as $self_obj |

        (if $pr == null then null else
            ($pr.AdvertiseRoutes // []) as $adv_all |
            ($adv_all | map(select(. != "0.0.0.0/0" and . != "::/0"))) as $adv_sub |
            (($adv_all | index("0.0.0.0/0") != null) and ($adv_all | index("::/0") != null)) as $adv_exit |
            {
                advertise_routes: $adv_sub,
                advertise_exit_node: $adv_exit,
                accept_routes: ($pr.RouteAll == true),
                hostname: ($pr.Hostname // "")
            }
         end) as $prefs_obj |

        (if $st == null then [] else (($st.Self.PrimaryRoutes // []) + ($st.Self.AllowedIPs // [])) end) as $approved_set |
        (if $prefs_obj == null then [] else
            ($prefs_obj.advertise_routes | map(. as $r | {
                cidr: $r,
                approved: (($approved_set | index($r)) != null)
            }))
         end) as $routes_arr |

        {
            advertised: (if $prefs_obj != null then $prefs_obj.advertise_exit_node else false end),
            approved: (if $st != null then
                (($st.Self.ExitNodeOption == true) or
                 ((($st.Self.AllowedIPs // []) | index("0.0.0.0/0") != null) and
                  (($st.Self.AllowedIPs // []) | index("::/0") != null)))
                else false end)
        } as $exit_obj |

        (if $pr != null and ((($pr.CorpDNS // false) != false) or (($pr.NetfilterMode // 0) != 0 and ($pr.NetfilterMode // 0) != "off") or (($pr.ShieldsUp // false) != false))
         then true else false end) as $chk_prefs |

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
            plugin: { version: $pver, enabled: $enabled },
            core: {
                tailscale: ($man.tailscale // ""),
                revision: ($man.revision // 0),
                serial: $man_serial,
                arch: $core_arch,
                kernel_arch: $karch,
                size: $csize,
                installed: $cinst,
                prev: $cprev,
                update: $core_update
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
        }
        ' | json_write "$BIFROST_UPLOAD/bifrost_status.json"
    _sr_rc=$?
    rm -f "$_sr_st_tmp" "$_sr_pr_tmp"
    return "$_sr_rc"
}
