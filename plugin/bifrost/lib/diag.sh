# shellcheck shell=sh
# Diagnostics: netcheck, ping, redacted logs and environment checks.
# Contract file: see docs/dev/contract.md, sections 4, 6.2, 6.3, 7.
# No "local" in POSIX sh: function variables use a _<abbr>_ prefix.

: "${BIFROST_NETCHECK_TIMEOUT:=60}"
: "${BIFROST_PING_TIMEOUT:=5}"
: "${BIFROST_PING_CMD_TIMEOUT:=10}"
: "${BIFROST_LOG_TAIL_LINES:=200}"
: "${BIFROST_JFFS_PATH:=$BIFROST_KSROOT}"

# redact [tailnet_or_suffix...]: filter stdin -> stdout applying all 7 PLAN 13.10
# redaction classes while preserving private IPv4, 100.64.0.0/10,
# fd7a:115c:a1e0::/48, and device names. Pure BusyBox awk (no grep -P).
redact() {
    _rd_extra=""
    for _rd_arg in "$@"; do
        [ -n "$_rd_arg" ] || continue
        _rd_extra="${_rd_extra}${_rd_arg}
"
    done
    awk -v extra="$_rd_extra" '
    BEGIN {
        n_tn = 0
        n = split(extra, raw_tn, "\n")
        for (i = 1; i <= n; i++) {
            s = raw_tn[i]
            sub(/^\.+/, "", s)
            sub(/\.+$/, "", s)
            if (length(s) >= 3) {
                n_tn++
                tn[n_tn] = s
                tn_lc[n_tn] = tolower(s)
            }
        }
        # Sort longest first so suffixes replace before shorter substrings.
        for (i = 1; i <= n_tn; i++) {
            for (j = i + 1; j <= n_tn; j++) {
                if (length(tn[j]) > length(tn[i])) {
                    tmp = tn[i]; tn[i] = tn[j]; tn[j] = tmp
                    tmp = tn_lc[i]; tn_lc[i] = tn_lc[j]; tn_lc[j] = tmp
                }
            }
        }
    }

    function is_alnum(c) {
        return (c != "" && c ~ /^[A-Za-z0-9]$/)
    }

    function is_hex(c) {
        return (c != "" && c ~ /^[0-9A-Fa-f]$/)
    }

    function redact_auth_urls(line,    out, rest, seg, pos) {
        # 1a. Explicit auth/login/register URL paths.
        out = ""
        rest = line
        while (match(rest, /https?:\/\/[^ \t\r\n"'\''<>)]+\/(a|f|register|oidc\/register|login\/a|auth)\/[^ \t\r\n"'\''<>)]+/)) {
            out = out substr(rest, 1, RSTART - 1) "<auth-url>"
            rest = substr(rest, RSTART + RLENGTH)
        }
        line = out rest

        # 1b. Any URL following AuthURL / auth_url / authenticate prompt on the line.
        out = ""
        rest = line
        while (match(rest, /([Aa]uth_?[Uu][Rr][Ll][ \t]*[:=][ \t]*"?|authenticate,[ \t]+visit:[ \t]*)https?:\/\/[^ \t\r\n"'\''<>)]+/)) {
            seg = substr(rest, RSTART, RLENGTH)
            pos = index(seg, "http")
            out = out substr(rest, 1, RSTART - 1) substr(seg, 1, pos - 1) "<auth-url>"
            rest = substr(rest, RSTART + RLENGTH)
        }
        return out rest
    }

    function redact_keys(line,    out, rest, prev, m) {
        out = ""
        rest = line
        while (match(rest, /(tskey|hskey)-[A-Za-z0-9._-]+/)) {
            prev = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
            m = substr(rest, RSTART, RLENGTH)
            if (is_alnum(prev)) {
                out = out substr(rest, 1, RSTART + RLENGTH - 1)
            } else {
                out = out substr(rest, 1, RSTART - 1) "<key>"
            }
            rest = substr(rest, RSTART + RLENGTH)
        }
        return out rest
    }

    function redact_emails(line,    out, rest, prev) {
        out = ""
        rest = line
        while (match(rest, /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z][A-Za-z]+/)) {
            prev = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
            if (is_alnum(prev) || prev == "." || prev == "_" || prev == "%" || prev == "+" || prev == "-") {
                out = out substr(rest, 1, RSTART + RLENGTH - 1)
            } else {
                out = out substr(rest, 1, RSTART - 1) "<email>"
            }
            rest = substr(rest, RSTART + RLENGTH)
        }
        return out rest
    }

    function redact_literal_ci(line, pat_lc,    out, rest, lc, pos, plen, prev, nxt) {
        plen = length(pat_lc)
        out = ""
        rest = line
        while (1) {
            lc = tolower(rest)
            pos = index(lc, pat_lc)
            if (pos == 0) break
            prev = (pos > 1) ? substr(rest, pos - 1, 1) : ""
            nxt = substr(rest, pos + plen, 1)
            # Token boundary: do not match in the middle of a label; "." before is
            # allowed so "<device>.<suffix>" becomes "<device>.<tailnet>".
            if (is_alnum(prev) || prev == "-" || is_alnum(nxt) || nxt == "-") {
                out = out substr(rest, 1, pos + plen - 1)
                rest = substr(rest, pos + plen)
            } else {
                out = out substr(rest, 1, pos - 1) "<tailnet>"
                rest = substr(rest, pos + plen)
            }
        }
        return out rest
    }

    function redact_tailnets(line,    i, out, rest, prev, nxt) {
        for (i = 1; i <= n_tn; i++) {
            line = redact_literal_ci(line, tn_lc[i])
        }
        # Generic Tailscale MagicDNS suffix (such as example.ts.net or beta).
        # Preserves any preceding "<device>." hostname label.
        out = ""
        rest = line
        while (match(rest, /[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[Bb][Ee][Tt][Aa])?\.[Tt][Ss]\.[Nn][Ee][Tt]/)) {
            prev = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
            nxt = substr(rest, RSTART + RLENGTH, 1)
            if (is_alnum(prev) || prev == "-" || is_alnum(nxt) || nxt == "-") {
                out = out substr(rest, 1, RSTART + RLENGTH - 1)
            } else {
                out = out substr(rest, 1, RSTART - 1) "<tailnet>"
            }
            rest = substr(rest, RSTART + RLENGTH)
        }
        return out rest
    }

    function redact_macs(line,    out, rest, prev, nxt) {
        # Colon-separated MAC (must not touch IPv6 groups: neither side hex or ":")
        out = ""
        rest = line
        while (match(rest, /[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]/)) {
            prev = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
            nxt = substr(rest, RSTART + RLENGTH, 1)
            if (is_hex(prev) || prev == ":" || is_hex(nxt) || nxt == ":") {
                out = out substr(rest, 1, RSTART + RLENGTH - 1)
            } else {
                out = out substr(rest, 1, RSTART - 1) "<mac>"
            }
            rest = substr(rest, RSTART + RLENGTH)
        }
        line = out rest

        # Hyphen-separated MAC
        out = ""
        rest = line
        while (match(rest, /[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]/)) {
            prev = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
            nxt = substr(rest, RSTART + RLENGTH, 1)
            if (is_hex(prev) || prev == "-" || is_hex(nxt) || nxt == "-") {
                out = out substr(rest, 1, RSTART + RLENGTH - 1)
            } else {
                out = out substr(rest, 1, RSTART - 1) "<mac>"
            }
            rest = substr(rest, RSTART + RLENGTH)
        }
        return out rest
    }

    function valid_ipv4_str(s,    p, n, i, v) {
        n = split(s, p, ".")
        if (n != 4) return 0
        for (i = 1; i <= 4; i++) {
            if (p[i] !~ /^[0-9]+$/ || length(p[i]) > 3) return 0
            v = p[i] + 0
            if (v < 0 || v > 255) return 0
        }
        return 1
    }

    function is_valid_ipv6(s,    lc, has_dc, idx, left, right, g, ng, n1, n2, i) {
        lc = tolower(s)
        if (index(lc, ":::") > 0) return 0
        # Handle IPv4-embedded tail like ::ffff:203.0.113.1
        if (index(lc, ".") > 0) {
            if (!match(lc, /:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) return 0
            if (!valid_ipv4_str(substr(lc, RSTART + 1))) return 0
            lc = substr(lc, 1, RSTART) "0:0"
        }
        idx = index(lc, "::")
        has_dc = (idx > 0)
        if (has_dc) {
            left = substr(lc, 1, idx - 1)
            right = substr(lc, idx + 2)
            if (index(right, "::") > 0) return 0
            ng = 0
            if (left != "") {
                n1 = split(left, g, ":")
                for (i = 1; i <= n1; i++) {
                    if (g[i] !~ /^[0-9a-f]+$/ || length(g[i]) > 4) return 0
                }
                ng += n1
            }
            if (right != "") {
                n2 = split(right, g, ":")
                for (i = 1; i <= n2; i++) {
                    if (g[i] !~ /^[0-9a-f]+$/ || length(g[i]) > 4) return 0
                }
                ng += n2
            }
            return (ng <= 7)
        } else {
            ng = split(lc, g, ":")
            if (ng != 8) return 0
            for (i = 1; i <= 8; i++) {
                if (g[i] !~ /^[0-9a-f]+$/ || length(g[i]) > 4) return 0
            }
            return 1
        }
    }

    function keep_ipv6(s,    lc) {
        lc = tolower(s)
        if (lc == "::" || lc == "::1") return 1
        # Keep Tailscale IPv6 fd7a:115c:a1e0::/48
        if (lc ~ /^fd7a:115c:a1e0:/) return 1
        return 0
    }

    function redact_ipv6(line,    out, rest, ms, ml, cand, prev, nxt, lead, trim) {
        out = ""
        rest = line
        while (match(rest, /[0-9A-Fa-f:]*:[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*/)) {
            ms = RSTART
            ml = RLENGTH
            cand = substr(rest, ms, ml)
            prev = (ms > 1) ? substr(rest, ms - 1, 1) : ""
            nxt = substr(rest, ms + ml, 1)
            lead = ""
            trim = ""
            # Strip single leading colon (e.g. "addr:2001:db8::1") without breaking "::".
            if (length(cand) > 2 && substr(cand, 1, 1) == ":" && substr(cand, 2, 1) != ":") {
                lead = ":"
                cand = substr(cand, 2)
                prev = ":"
            }
            # Strip trailing single colon or sentence-ending period.
            while (length(cand) > 2 && substr(cand, length(cand), 1) == ":" && substr(cand, length(cand) - 1, 1) != ":") {
                trim = ":" trim
                cand = substr(cand, 1, length(cand) - 1)
            }
            while (length(cand) > 0 && substr(cand, length(cand), 1) == ".") {
                trim = "." trim
                cand = substr(cand, 1, length(cand) - 1)
            }
            if (!is_alnum(prev) && !is_alnum(nxt) && is_valid_ipv6(cand)) {
                if (keep_ipv6(cand)) {
                    out = out substr(rest, 1, ms - 1) lead cand trim
                } else {
                    out = out substr(rest, 1, ms - 1) lead "<ipv6>" trim
                }
            } else {
                out = out substr(rest, 1, ms + ml - 1)
            }
            rest = substr(rest, ms + ml)
        }
        return out rest
    }

    function keep_ipv4(s,    p, o1, o2, o3, o4) {
        split(s, p, ".")
        o1 = p[1] + 0; o2 = p[2] + 0; o3 = p[3] + 0; o4 = p[4] + 0
        if (o1 == 10) return 1
        if (o1 == 172 && o2 >= 16 && o2 <= 31) return 1
        if (o1 == 192 && o2 == 168) return 1
        if (o1 == 100 && o2 >= 64 && o2 <= 127) return 1
        if (o1 == 127) return 1
        if (o1 == 169 && o2 == 254) return 1
        if (o1 == 0 && o2 == 0 && o3 == 0 && o4 == 0) return 1
        if (o1 == 255) return 1
        return 0
    }

    function redact_ipv4(line,    out, rest, cand, prev, nxt) {
        out = ""
        rest = line
        while (match(rest, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
            cand = substr(rest, RSTART, RLENGTH)
            prev = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
            nxt = substr(rest, RSTART + RLENGTH, 1)
            if (prev ~ /[0-9.]/ || nxt ~ /[0-9.]/ || !valid_ipv4_str(cand) || keep_ipv4(cand)) {
                out = out substr(rest, 1, RSTART + RLENGTH - 1)
            } else {
                out = out substr(rest, 1, RSTART - 1) "<ipv4>"
            }
            rest = substr(rest, RSTART + RLENGTH)
        }
        return out rest
    }

    {
        l = $0
        l = redact_auth_urls(l)
        l = redact_keys(l)
        l = redact_emails(l)
        l = redact_tailnets(l)
        l = redact_macs(l)
        l = redact_ipv6(l)
        l = redact_ipv4(l)
        print l
    }
    '
}

# act_netcheck: start background netcheck job (contract 4, 6.2).
act_netcheck() {
    if ! daemon_running && [ ! -e "$BIFROST_SOCK" ]; then
        fail not_running
        return 1
    fi
    job_start netcheck
}

# job_netcheck: run "tailscale netcheck --format=json" and format report (contract 6.2).
job_netcheck() {
    job_phase netcheck running 10 || return 1
    [ -d "$BIFROST_RUN" ] || mkdir -p "$BIFROST_RUN"
    _jn_out="$BIFROST_RUN/netcheck.$$.json"
    _jn_dm="$BIFROST_RUN/derpmap.$$.json"
    ts_cli_t "$BIFROST_NETCHECK_TIMEOUT" netcheck --format=json >"$_jn_out" 2>/dev/null
    _jn_rc=$?
    if [ "$_jn_rc" -eq 124 ]; then
        rm -f "$_jn_out"
        fail timeout
        return 1
    fi
    if [ "$_jn_rc" -ne 0 ] || ! jq -e 'type == "object"' "$_jn_out" >/dev/null 2>&1; then
        rm -f "$_jn_out"
        fail cli_failed
        return 1
    fi

    # Obtain DERP map to map numeric region IDs to region codes without hardcoding.
    _jn_dm_file=/dev/null
    if ts_cli_t 5 debug derp-map >"$_jn_dm" 2>/dev/null && jq -e 'type == "object"' "$_jn_dm" >/dev/null 2>&1; then
        _jn_dm_file=$_jn_dm
    elif [ -r "$BIFROST_STATE/derpmap.cached.json" ] && jq -e 'type == "object"' "$BIFROST_STATE/derpmap.cached.json" >/dev/null 2>&1; then
        _jn_dm_file="$BIFROST_STATE/derpmap.cached.json"
    fi

    _jn_rep=$(jq -c --slurpfile dm_a "$_jn_dm_file" '
        ($dm_a[0].Regions // {}) as $regs |
        def code_of($id):
            ($regs[$id | tostring].RegionCode // "") as $c |
            if $c != "" then $c else ("derp" + ($id | tostring)) end;
        (if (.UPnP == null and .PMP == null and .PCP == null) then "not checked"
         else
            ([
                (if .UPnP == true then "UPnP" else empty end),
                (if .PMP == true then "NAT-PMP" else empty end),
                (if .PCP == true then "PCP" else empty end)
            ] | join(", "))
         end) as $pm |
        {
            report: {
                udp: (.UDP == true),
                ipv4: (.IPv4 == true),
                ipv6: (.IPv6 == true),
                mapping_varies: (if (.MappingVariesByDestIP | type) == "boolean" then .MappingVariesByDestIP else null end),
                portmap: $pm,
                preferred_derp: (if (.PreferredDERP // 0) != 0 then code_of(.PreferredDERP) else "" end),
                derp: (
                    (.RegionLatency // {}) | to_entries
                    | map(select((.value | type) == "number") | {
                        code: code_of(.key),
                        latency_ms: ((.value / 1000000) | round)
                    })
                    | sort_by([.latency_ms, .code])
                )
            }
        }
    ' "$_jn_out" 2>/dev/null)
    rm -f "$_jn_out" "$_jn_dm"
    if [ -z "$_jn_rep" ]; then
        fail internal
        return 1
    fi
    job_data netcheck "$_jn_rep"
}

# act_ping <tailnet_ip>: ping a known peer and return latency/path/relay (contract 4).
act_ping() {
    _ap_ip=$1
    if ! valid_tailnet_ip "$_ap_ip"; then
        fail unknown_peer
        return 1
    fi
    if ! daemon_running && [ ! -e "$BIFROST_SOCK" ]; then
        fail not_running
        return 1
    fi
    _ap_st=$(ts_cli status --json 2>/dev/null)
    _ap_rc=$?
    if [ "$_ap_rc" -eq 124 ]; then
        fail timeout
        return 1
    fi
    if [ "$_ap_rc" -ne 0 ] || [ -z "$_ap_st" ]; then
        fail not_running
        return 1
    fi
    if ! printf '%s\n' "$_ap_st" | jq -e --arg ip "$_ap_ip" '
        (.Peer // {}) | to_entries | map(.value) | map(select(.ShareeNode != true))
        | any((.TailscaleIPs // []) | index($ip) != null)
    ' >/dev/null 2>&1; then
        fail unknown_peer
        return 1
    fi

    _ap_out=$(ts_cli_t "$BIFROST_PING_CMD_TIMEOUT" ping -c 1 --until-direct=false "--timeout=${BIFROST_PING_TIMEOUT}s" "$_ap_ip" 2>&1)
    _ap_rc=$?
    if [ "$_ap_rc" -eq 124 ]; then
        fail timeout
        return 1
    fi

    _ap_parsed=$(printf '%s\n' "$_ap_out" | awk '
        /^pong from .* via .* in / {
            line = $0
            sub(/^pong from .* via /, "", line)
            idx = match(line, / in [0-9.]+(ms|s|us|µs)[ \t]*$/)
            if (idx == 0) next
            via = substr(line, 1, idx - 1)
            lat = substr(line, idx + 4)
            sub(/[ \t]*$/, "", lat)
            if (lat ~ /ms$/) {
                sub(/ms$/, "", lat)
                ms = int((lat + 0) + 0.5)
            } else if (lat ~ /(us|µs)$/) {
                sub(/(us|µs)$/, "", lat)
                ms = int((lat + 0) / 1000 + 0.5)
            } else if (lat ~ /s$/) {
                sub(/s$/, "", lat)
                ms = int((lat + 0) * 1000 + 0.5)
            } else {
                next
            }
            path = "direct"
            relay = ""
            if (via ~ /^DERP\([^)]*\)$/) {
                path = "derp"
                relay = via
                sub(/^DERP\(/, "", relay)
                sub(/\)$/, "", relay)
            } else if (via ~ /^peer-relay\(.*\)$/) {
                path = "peer-relay"
                relay = ""
            }
            print ms "\t" path "\t" relay
            exit 0
        }
    ')
    if [ -n "$_ap_parsed" ]; then
        _ap_ms=$(printf '%s' "$_ap_parsed" | cut -f1)
        _ap_path=$(printf '%s' "$_ap_parsed" | cut -f2)
        _ap_relay=$(printf '%s' "$_ap_parsed" | cut -f3)
        # Keep relay safe for respond() (no & + % =).
        case "$_ap_relay" in *[!A-Za-z0-9._-]*) _ap_relay="" ;; esac
        BIFROST_RESULT=$(jq -cn --argjson ms "$_ap_ms" --arg p "$_ap_path" --arg r "$_ap_relay" \
            '{latency_ms:$ms, path:$p, relay:$r}')
        return 0
    fi
    case "$_ap_out" in
        *"timed out"* | *"no reply"*)
            fail timeout
            return 1
            ;;
    esac
    fail cli_failed
    return 1
}

# _diag_wan_cgnat: print "true", "false", or "null" (RFC 6598 100.64.0.0/10 check).
_diag_wan_cgnat() {
    _dw_ip=$(nvram get wan0_ipaddr 2>/dev/null)
    if [ -z "$_dw_ip" ] || [ "$_dw_ip" = "0.0.0.0" ]; then
        _dw_ip=$(nvram get wan_ipaddr 2>/dev/null)
    fi
    if [ -z "$_dw_ip" ] || [ "$_dw_ip" = "0.0.0.0" ] || ! valid_ipv4 "$_dw_ip"; then
        echo null
        return 0
    fi
    if valid_tailnet_ip "$_dw_ip"; then
        echo true
    else
        echo false
    fi
}

# _diag_jffs_free_kb: print integer free KiB on $BIFROST_JFFS_PATH or "null".
_diag_jffs_free_kb() {
    [ -e "$BIFROST_JFFS_PATH" ] || {
        echo null
        return 0
    }
    _dj_kb=$(df -k "$BIFROST_JFFS_PATH" 2>/dev/null | awk 'NR > 1 && NF >= 4 { a = $(NF - 2) } END { print a }')
    if valid_uint "$_dj_kb"; then
        printf '%s\n' "$_dj_kb"
    else
        echo null
    fi
}

# act_logs: write $BIFROST_UPLOAD/bifrost_diag.json and $BIFROST_UPLOAD/bifrost_logs.txt (contract 6.3).
act_logs() {
    [ -d "$BIFROST_UPLOAD" ] || mkdir -p "$BIFROST_UPLOAD" 2>/dev/null || {
        fail internal
        return 1
    }
    _al_now=$(now)

    # Refresh status file first so summary reflects live state/settings/prefs.
    status_refresh >/dev/null 2>&1 || true
    _al_st_json="$BIFROST_UPLOAD/bifrost_status.json"

    # Environment checks (contract 6.3, PLAN 13.4)
    if [ -e "$BIFROST_TUN_DEV" ]; then _al_tun=true; else _al_tun=false; fi
    if daemon_running; then
        if fw_check; then _al_fw=true; else _al_fw=false; fi
    else
        _al_fw=null
    fi
    if orig_running; then _al_conflict=true; else _al_conflict=false; fi
    _al_cgnat=$(_diag_wan_cgnat)
    _al_jffs=$(_diag_jffs_free_kb)
    _al_tsync=$(status_time_synced)
    if dns_has_conf_dir; then _al_conf_dir=true; else _al_conf_dir=false; fi

    jq -n \
        --argjson t "$_al_now" \
        --argjson tun "$_al_tun" \
        --argjson fw "$_al_fw" \
        --argjson conflict "$_al_conflict" \
        --argjson cgnat "$_al_cgnat" \
        --argjson jffs "$_al_jffs" \
        --argjson tsync "$_al_tsync" \
        --argjson conf_dir "$_al_conf_dir" \
        '{
            schema: 1,
            time: $t,
            tun: $tun,
            fw_complete: $fw,
            conflict: $conflict,
            wan_cgnat: $cgnat,
            jffs_free_kb: $jffs,
            time_synced: $tsync,
            dnsmasq_conf_dir: $conf_dir
        }' | json_write "$BIFROST_UPLOAD/bifrost_diag.json" || return 1

    # Gather tailnet names / MagicDNS suffix and BackendState for summary & redaction.
    _al_tn=""
    _al_msuf=""
    _al_bstate=""
    if [ -r "$_al_st_json" ]; then
        _al_tn=$(jq -r '.self.tailnet // ""' "$_al_st_json" 2>/dev/null)
        _al_msuf=$(jq -r '.self.magicdns_suffix // ""' "$_al_st_json" 2>/dev/null)
    fi
    if daemon_running; then
        _al_bstate=$(ts_cli status --json 2>/dev/null | jq -r '.BackendState // ""' 2>/dev/null)
    fi

    _al_pver=""
    [ -r "$BIFROST_VERSION_FILE" ] && _al_pver=$(head -n 1 "$BIFROST_VERSION_FILE" | tr -d '\r\n')
    _al_cver=""
    _al_carch=""
    if [ -r "$BIFROST_MANIFEST" ]; then
        _al_cver=$(jq -r '.tailscale // ""' "$BIFROST_MANIFEST" 2>/dev/null)
        _al_carch=$(jq -r 'if (.arch // "") != "" then .arch elif ((.assets // {}) | keys | length) == 1 then (.assets | keys)[0] else "" end' "$BIFROST_MANIFEST" 2>/dev/null)
    fi
    _al_state=""
    _al_prefs_adv=""
    _al_prefs_exit=""
    _al_prefs_acc=""
    _al_prefs_host=""
    if [ -r "$_al_st_json" ]; then
        _al_state=$(jq -r '.state // ""' "$_al_st_json" 2>/dev/null)
        _al_prefs_adv=$(jq -r 'if .prefs then (.prefs.advertise_routes | join(",")) else "unavailable" end' "$_al_st_json" 2>/dev/null)
        _al_prefs_exit=$(jq -r 'if .prefs then (.prefs.advertise_exit_node | tostring) else "unavailable" end' "$_al_st_json" 2>/dev/null)
        _al_prefs_acc=$(jq -r 'if .prefs then (.prefs.accept_routes | tostring) else "unavailable" end' "$_al_st_json" 2>/dev/null)
        _al_prefs_host=$(jq -r 'if .prefs then .prefs.hostname else "unavailable" end' "$_al_st_json" 2>/dev/null)
    fi

    if fw_snat_effective; then _al_snat_eff=true; else _al_snat_eff=false; fi

    {
        printf 'Redacted: public IPv4 (<ipv4>), non-tailnet IPv6 (<ipv6>), emails (<email>), tailnet/MagicDNS (<tailnet>), auth URLs (<auth-url>), auth keys (<key>), MAC addresses (<mac>).\n'
        {
            printf '== summary ==\n'
            printf 'time: %s\n' "$_al_now"
            printf 'plugin_version: %s\n' "$_al_pver"
            printf 'core_version: %s\n' "$_al_cver"
            printf 'core_arch: %s\n' "$_al_carch"
            printf 'kernel_arch: %s\n' "$(uname -m 2>/dev/null)"
            printf 'state: %s\n' "$_al_state"
            printf 'backend_state: %s\n' "${_al_bstate:-unavailable}"
            printf 'setting_enable: %s\n' "$(cfg bifrost_enable)"
            printf 'setting_port: %s\n' "$(cfg bifrost_port)"
            printf 'setting_local_access: %s\n' "$(cfg bifrost_local_access)"
            printf 'setting_lan_masq: %s\n' "$(cfg bifrost_lan_masq)"
            printf 'setting_snat: %s (effective=%s)\n' "$(cfg bifrost_snat)" "$_al_snat_eff"
            printf 'setting_magicdns: %s\n' "$(cfg bifrost_magicdns)"
            printf 'setting_no_logs: %s\n' "$(cfg bifrost_no_logs)"
            printf 'setting_mirror: %s\n' "$(cfg bifrost_mirror)"
            printf 'prefs_advertise_routes: %s\n' "$_al_prefs_adv"
            printf 'prefs_advertise_exit_node: %s\n' "$_al_prefs_exit"
            printf 'prefs_accept_routes: %s\n' "$_al_prefs_acc"
            printf 'prefs_hostname: %s\n' "$_al_prefs_host"
            printf 'check_tun: %s\n' "$_al_tun"
            printf 'check_fw_complete: %s\n' "$_al_fw"
            printf 'check_conflict: %s\n' "$_al_conflict"
            printf 'check_wan_cgnat: %s\n' "$_al_cgnat"
            printf 'check_jffs_free_kb: %s\n' "$_al_jffs"
            printf 'check_time_synced: %s\n' "$_al_tsync"
            printf 'check_dnsmasq_conf_dir: %s\n' "$_al_conf_dir"
            printf '== bifrost.log ==\n'
            if [ -s "$BIFROST_LOG" ]; then
                tail -n "$BIFROST_LOG_TAIL_LINES" "$BIFROST_LOG"
            else
                printf '(empty)\n'
            fi
            printf '== bifrostd.log ==\n'
            if [ -s "$BIFROST_DLOG" ]; then
                tail -n "$BIFROST_LOG_TAIL_LINES" "$BIFROST_DLOG"
            else
                printf '(empty)\n'
            fi
        } | redact "$_al_msuf" "$_al_tn"
    } | atomic_write "$BIFROST_UPLOAD/bifrost_logs.txt" 644 || {
        fail internal
        return 1
    }
    return 0
}
