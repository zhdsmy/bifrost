#!/bin/sh
# Tests for plugin/bifrost/scripts/bifrost_config.sh (request handling only).
# shellcheck disable=SC1091
. tests/shell/lib.sh
t_setup

t_call evil
eq reject-first-arg 2 "$?"
t_call '1;id' ui en dark
eq reject-id 2 "$?"
eq no-response-for-rejected "" "$(t_resp)"

eq unknown-action '{"ok":false,"code":"unknown_action"}' "$(t_page frobnicate)"
eq bad-action-name '{"ok":false,"code":"invalid_param"}' "$(t_page 'Ui')"
eq bad-param '{"ok":false,"code":"invalid_param"}' "$(t_page ui 'en;' dark)"
eq bad-param-space '{"ok":false,"code":"invalid_param"}' "$(t_page ui 'en x' dark)"
eq wrong-count '{"ok":false,"code":"invalid_param"}' "$(t_page ui en)"
eq wrong-count2 '{"ok":false,"code":"invalid_param"}' "$(t_page enable extra)"
eq login-two-params '{"ok":false,"code":"invalid_param"}' "$(t_page login - -)"
eq relogin-no-param '{"ok":false,"code":"invalid_param"}' "$(t_page relogin)"
eq no-action '{"ok":false,"code":"invalid_param"}' "$(t_page)"

: >"$MOCK_STATE/resp.log"
eq ui-ok '{"ok":true}' "$(t_page ui en light)"
eq ui-lang en "$(dbus get bifrost_ui_lang)"
eq ui-mode light "$(dbus get bifrost_ui_mode)"
eq ui-bad '{"ok":false,"code":"invalid_param"}' "$(t_page ui fr dark)"
eq ui-unchanged en "$(dbus get bifrost_ui_lang)"
eq ui-one-response-each 2 "$(wc -l <"$MOCK_STATE/resp.log" | tr -d ' ')"

t_load
run_act act_does_not_exist >/dev/null
eq missing-act not_implemented "$(run_act act_does_not_exist | jq -r .code)"
act_demo() { BIFROST_RESULT='{"job":"demo"}'; }
eq act-result '{"ok":true,"job":"demo"}' "$(run_act act_demo)"
act_fail() { fail busy; }
eq act-fail '{"ok":false,"code":"busy"}' "$(run_act act_fail)"
eq undash-empty "" "$(undash -)"
eq undash-value a "$(undash a)"

t_call local nosuch
eq local-unknown 1 "$?"
t_call local job 'Bad'
eq local-job-bad-name 1 "$?"

t_done
