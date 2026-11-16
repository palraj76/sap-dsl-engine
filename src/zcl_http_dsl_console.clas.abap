class ZCL_HTTP_DSL_CONSOLE definition
  public
  final
  create public .

  public section.

    " ICF handler for /sap/zdsl/console
    "   GET  -> the DSL Query Console page (HTML built in GET_PAGE_LINES)
    "   POST -> runs the posted DSL JSON as the logged-on SAP user
    interfaces IF_HTTP_EXTENSION .

  private section.

    methods SERVE_PAGE
      importing
        !IO_SERVER type ref to IF_HTTP_SERVER .

    methods RUN_QUERY
      importing
        !IO_SERVER type ref to IF_HTTP_SERVER .

    methods CHECK_TABLE_AUTHORITY
      importing
        !IV_JSON type STRING
      exporting
        !EV_QUERY_ID type STRING
        !ET_DENIED type STRING_TABLE .

    methods COLLECT_TABLES
      importing
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY
        !IV_DEPTH type I default 0
      changing
        !CT_TABLES type STRING_TABLE .

    methods IS_SERVICE_USER
      returning
        value(RV_IS_SVC) type ABAP_BOOL .

    methods SEND_ERROR
      importing
        !IO_SERVER type ref to IF_HTTP_SERVER
        !IV_STATUS type I
        !IV_CODE type STRING
        !IV_MESSAGE type STRING
        !IV_HINT type STRING optional .

    methods SEND
      importing
        !IO_SERVER type ref to IF_HTTP_SERVER
        !IV_STATUS type I
        !IV_CONTENT_TYPE type STRING
        !IV_BODY type STRING .

    methods GET_PAGE_LINES
      returning
        value(RT_LINES) type STRING_TABLE .
ENDCLASS.



CLASS ZCL_HTTP_DSL_CONSOLE IMPLEMENTATION.


  method IF_HTTP_EXTENSION~HANDLE_REQUEST.
    DATA(lv_method) = server->request->get_header_field( name = '~request_method' ).

    CASE lv_method.
      WHEN 'GET'.
        serve_page( server ).
      WHEN 'POST'.
        run_query( server ).
      WHEN OTHERS.
        send_error(
          io_server  = server
          iv_status  = 405
          iv_code    = `HTTP_405`
          iv_message = `Method not allowed - GET opens the console, POST runs a query` ).
    ENDCASE.
  endmethod.


  method SERVE_PAGE.
    DATA lv_wl   TYPE zjson_dsl_config-config_value.
    DATA lv_text TYPE string.

    SELECT SINGLE config_value INTO lv_wl
      FROM zjson_dsl_config
      WHERE config_key = 'WHITELIST_MODE'.
    IF lv_wl IS INITIAL.
      lv_wl = 'STRICT'.
    ENDIF.

    DATA(lv_html) = concat_lines_of( table = get_page_lines( )
                                     sep   = cl_abap_char_utilities=>newline ).

    " Fill the page's placeholders (HTML-escaped; they also sit inside JS strings)
    lv_text = sy-uname.
    lv_text = cl_http_utility=>escape_html( lv_text ).
    REPLACE ALL OCCURRENCES OF `__DSL_USER__` IN lv_html WITH lv_text.
    lv_text = sy-sysid.
    lv_text = cl_http_utility=>escape_html( lv_text ).
    REPLACE ALL OCCURRENCES OF `__DSL_SYSID__` IN lv_html WITH lv_text.
    lv_text = sy-mandt.
    REPLACE ALL OCCURRENCES OF `__DSL_CLIENT__` IN lv_html WITH lv_text.
    lv_text = lv_wl.
    lv_text = cl_http_utility=>escape_html( lv_text ).
    REPLACE ALL OCCURRENCES OF `__DSL_WLMODE__` IN lv_html WITH lv_text.
    IF is_service_user( ) = abap_true.
      lv_text = `X`.
    ELSE.
      lv_text = ``.
    ENDIF.
    REPLACE ALL OCCURRENCES OF `__DSL_ISSVC__` IN lv_html WITH lv_text.

    io_server->response->set_header_field( name = 'Cache-Control'          value = 'no-store' ).
    io_server->response->set_header_field( name = 'X-Frame-Options'        value = 'SAMEORIGIN' ).
    io_server->response->set_header_field( name = 'X-Content-Type-Options' value = 'nosniff' ).
    send( io_server       = io_server
          iv_status       = 200
          iv_content_type = `text/html; charset=utf-8`
          iv_body         = lv_html ).
  endmethod.


  method RUN_QUERY.
    DATA ls_response TYPE zif_json_dsl_types=>ty_response.
    DATA lv_status   TYPE i.
    DATA lv_qid      TYPE string.
    DATA lt_denied   TYPE string_table.

    " 1. Only the console page may post here. The page always sends this header;
    "    a browser will not add a custom header to a cross-site request without a
    "    CORS preflight, which SAP does not answer, so another site cannot make a
    "    logged-on user run queries (CSRF).
    IF io_server->request->get_header_field( name = 'X-DSL-Console' ) <> '1'.
      send_error(
        io_server  = io_server
        iv_status  = 403
        iv_code    = `DSL_AUTH_007`
        iv_message = `Request did not come from the DSL console page (header X-DSL-Console missing)` ).
      RETURN.
    ENDIF.

    " 2. The console must run under a person's own user, never a service user
    IF is_service_user( ) = abap_true.
      send_error(
        io_server  = io_server
        iv_status  = 403
        iv_code    = `DSL_AUTH_008`
        iv_message = |The console is running as service user { sy-uname }|
        iv_hint    = `Remove the fixed logon data from SICF node /sap/zdsl/console so that people log on with their own user.` ).
      RETURN.
    ENDIF.

    " 3. Request body (strip BOM / anything before the first '{', as the query handler does)
    DATA(lv_body) = io_server->request->get_cdata( ).
    WHILE strlen( lv_body ) > 0 AND lv_body+0(1) <> '{'.
      lv_body = lv_body+1.
    ENDWHILE.
    IF lv_body IS INITIAL.
      send_error(
        io_server  = io_server
        iv_status  = 400
        iv_code    = `DSL_PARSE_001`
        iv_message = `Empty request body` ).
      RETURN.
    ENDIF.

    DATA(lo_out) = NEW zcl_http_dsl_handler( ).

    " 4. Open SQL does not check table authorizations, so check them here: the
    "    logged-on user must be able to display every table the query reads.
    check_table_authority(
      EXPORTING iv_json     = lv_body
      IMPORTING ev_query_id = lv_qid
                et_denied   = lt_denied ).
    IF lt_denied IS NOT INITIAL.
      ls_response-query_id = lv_qid.
      LOOP AT lt_denied INTO DATA(lv_tab).
        APPEND VALUE zst_dsl_error(
          code     = 'DSL_AUTH_006'
          severity = 'ERROR'
          message  = |User { sy-uname } has no display authorization for table { lv_tab }|
          tabname  = lv_tab
          hint     = |Needs S_TABU_DIS (ACTVT 03) for the authorization group of { lv_tab }, or S_TABU_NAM | &&
                     |(ACTVT 03) for { lv_tab }. Run SU53 right after this request to see the failed check.|
        ) TO ls_response-errors.
      ENDLOOP.
      io_server->response->set_header_field( name = 'Cache-Control' value = 'no-store' ).
      send( io_server       = io_server
            iv_status       = 403
            iv_content_type = `application/json`
            iv_body         = lo_out->serialize_response( ls_response ) ).
      RETURN.
    ENDIF.

    " 5. Run the engine as the logged-on user (audit log records sy-uname)
    ls_response = NEW zcl_json_dsl_engine( )->execute(
      iv_json   = lv_body
      iv_caller = sy-uname ).

    lv_status = 200.
    IF ls_response-errors IS NOT INITIAL.
      lv_status = lo_out->get_http_status( ls_response-errors ).
    ENDIF.

    io_server->response->set_header_field( name = 'Cache-Control' value = 'no-store' ).
    send( io_server       = io_server
          iv_status       = lv_status
          iv_content_type = `application/json`
          iv_body         = lo_out->serialize_response( ls_response ) ).
  endmethod.


  method CHECK_TABLE_AUTHORITY.
    DATA ls_query  TYPE zif_json_dsl_types=>ty_query.
    DATA lt_tables TYPE string_table.
    DATA lv_tab    TYPE tabname.

    CLEAR: ev_query_id, et_denied.

    " A request that does not parse is left to the engine, which reports it in
    " its usual format. Nothing is read from the database in that case.
    TRY.
        ls_query = NEW zcl_json_dsl_parser( )->parse( iv_json ).
        ls_query = NEW zcl_json_dsl_entity_resolver( )->resolve( ls_query ).
      CATCH zcx_dsl_parse.
        RETURN.
    ENDTRY.
    ev_query_id = ls_query-query_id.

    collect_tables( EXPORTING is_query = ls_query CHANGING ct_tables = lt_tables ).
    SORT lt_tables.
    DELETE ADJACENT DUPLICATES FROM lt_tables.

    " VIEW_AUTHORITY_CHECK is the check SE16 / SM30 use: S_TABU_DIS for the
    " table's authorization group, or S_TABU_NAM for the table itself.
    LOOP AT lt_tables INTO DATA(lv_name).
      lv_tab = to_upper( lv_name ).
      CALL FUNCTION 'VIEW_AUTHORITY_CHECK'
        EXPORTING
          view_action                    = 'S'
          view_name                      = lv_tab
          no_warning_for_clientindep     = 'X'
        EXCEPTIONS
          invalid_action                 = 1
          no_authority                   = 2
          no_clientindependent_authority = 3
          table_not_found                = 4
          no_linedependent_authority     = 5
          OTHERS                         = 6.
      CASE sy-subrc.
        WHEN 0.
          " allowed
        WHEN 4.
          " unknown table: the engine reports it with its own error
        WHEN OTHERS.
          APPEND CONV string( lv_tab ) TO et_denied.
      ENDCASE.
    ENDLOOP.
  endmethod.


  method COLLECT_TABLES.
    DATA lt_nodes TYPE zif_json_dsl_types=>ty_cond_nodes.
    DATA lv_sub   TYPE string.
    DATA ls_sub   TYPE zif_json_dsl_types=>ty_query.

    LOOP AT is_query-sources INTO DATA(ls_src).
      APPEND CONV string( ls_src-table ) TO ct_tables.
    ENDLOOP.
    LOOP AT is_query-joins INTO DATA(ls_join).
      APPEND CONV string( ls_join-target_table ) TO ct_tables.
    ENDLOOP.
    LOOP AT is_query-union-branches INTO DATA(ls_br).
      LOOP AT ls_br-sources INTO DATA(ls_bsrc).
        APPEND CONV string( ls_bsrc-table ) TO ct_tables.
      ENDLOOP.
      APPEND LINES OF ls_br-filter_nodes TO lt_nodes.
    ENDLOOP.

    " Tables inside IN / NOT IN subqueries (top level and union branches)
    IF iv_depth >= 3.
      RETURN.
    ENDIF.
    APPEND LINES OF is_query-filter_nodes TO lt_nodes.
    LOOP AT lt_nodes INTO DATA(ls_node) WHERE subquery_json IS NOT INITIAL.
      lv_sub = ls_node-subquery_json.
      DATA(lo_parser) = NEW zcl_json_dsl_parser( ).
      IF lo_parser->json_extract_member( iv_json = lv_sub iv_key = 'version' ) IS INITIAL.
        REPLACE FIRST OCCURRENCE OF '{' IN lv_sub WITH '{"version":"1.3",'.
      ENDIF.
      TRY.
          ls_sub = lo_parser->parse( lv_sub ).
          collect_tables(
            EXPORTING is_query  = ls_sub
                      iv_depth  = iv_depth + 1
            CHANGING  ct_tables = ct_tables ).
        CATCH zcx_dsl_parse.
          " An unparsable subquery makes the whole statement fail at execution,
          " so it cannot read data.
      ENDTRY.
    ENDLOOP.
  endmethod.


  method IS_SERVICE_USER.
    " A user that ZJSON_DSL_CLNT maps a client_id to is a service user
    rv_is_svc = abap_false.
    SELECT COUNT(*) FROM zjson_dsl_clnt
      WHERE svc_user = sy-uname.
    IF sy-dbcnt > 0.
      rv_is_svc = abap_true.
    ENDIF.
  endmethod.


  method SEND_ERROR.
    DATA ls_response TYPE zif_json_dsl_types=>ty_response.

    APPEND VALUE zst_dsl_error(
      code     = iv_code
      severity = 'ERROR'
      message  = iv_message
      hint     = iv_hint
    ) TO ls_response-errors.

    io_server->response->set_header_field( name = 'Cache-Control' value = 'no-store' ).
    send( io_server       = io_server
          iv_status       = iv_status
          iv_content_type = `application/json`
          iv_body         = NEW zcl_http_dsl_handler( )->serialize_response( ls_response ) ).
  endmethod.


  method SEND.
    io_server->response->set_status( code = iv_status reason = '' ).
    io_server->response->set_header_field( name = 'Content-Type' value = iv_content_type ).
    io_server->response->set_cdata( data = iv_body ).
  endmethod.


  method GET_PAGE_LINES.
    " >>> GENERATED from web/dsl_console.html by tools/gen_console_abap.py - do not edit by hand
    APPEND `<!DOCTYPE html>` TO rt_lines.
    APPEND `<html lang="en">` TO rt_lines.
    APPEND `<head>` TO rt_lines.
    APPEND `<meta charset="utf-8">` TO rt_lines.
    APPEND `<meta name="viewport" content="width=device-width, initial-scale=1">` TO rt_lines.
    APPEND `<title>DSL Query Console</title>` TO rt_lines.
    APPEND `<style>` TO rt_lines.
    APPEND `/* Source of the page served by ZCL_HTTP_DSL_CONSOLE at /sap/zdsl/console.` TO rt_lines.
    APPEND `   Edit this file, then run tools/gen_console_abap.py to regenerate the class.` TO rt_lines.
    APPEND `   Rules: ASCII only, no line longer than 200 characters. */` TO rt_lines.
    APPEND `:root {` TO rt_lines.
    APPEND `  --bg: #EEF2F3; --panel: #FFFFFF; --sunk: #F6F8F9; --ink: #15212A; --muted: #5A6974;` TO rt_lines.
    APPEND `  --line: #D3DBE0; --accent: #0B6C77; --accent-soft: #DCEEF0; --accent-ink: #FFFFFF;` TO rt_lines.
    APPEND `  --ok: #1E7341; --ok-bg: #E2F3E8; --warn: #9A5800; --warn-bg: #FBEFD9;` TO rt_lines.
    APPEND `  --err: #B0261C; --err-bg: #FBE4E1; --info-bg: #E4EEF8; --info: #1F4E7A;` TO rt_lines.
    APPEND `  --f-ui: "Segoe UI", "Helvetica Neue", Arial, sans-serif;` TO rt_lines.
    APPEND `  --f-label: "Segoe UI Semibold", "Arial Narrow", Arial, sans-serif;` TO rt_lines.
    APPEND `  --f-code: Consolas, "Cascadia Mono", "Courier New", monospace;` TO rt_lines.
    APPEND `  --r: 6px;` TO rt_lines.
    APPEND `}` TO rt_lines.
    APPEND `@media (prefers-color-scheme: dark) {` TO rt_lines.
    APPEND `  :root {` TO rt_lines.
    APPEND `    --bg: #0E1418; --panel: #151D22; --sunk: #10171B; --ink: #E2E9ED; --muted: #8FA0AB;` TO rt_lines.
    APPEND `    --line: #27333B; --accent: #43B6C2; --accent-soft: #143A40; --accent-ink: #052326;` TO rt_lines.
    APPEND `    --ok: #57C985; --ok-bg: #12301F; --warn: #E3A746; --warn-bg: #36280F;` TO rt_lines.
    APPEND `    --err: #F27A70; --err-bg: #3A1714; --info-bg: #13283B; --info: #8EC1EE; color-scheme: dark;` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `}` TO rt_lines.
    APPEND `* { box-sizing: border-box; }` TO rt_lines.
    APPEND `html, body { height: 100%; }` TO rt_lines.
    APPEND `body { margin: 0; background: var(--bg); color: var(--ink); font: 14px/1.45 var(--f-ui); }` TO rt_lines.
    APPEND `button, input, select, textarea { font: inherit; color: inherit; }` TO rt_lines.
    APPEND `:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }` TO rt_lines.
    APPEND `[hidden] { display: none !important; }` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `.top { position: sticky; top: 0; z-index: 5; background: var(--panel); border-bottom: 1px solid var(--line);` TO rt_lines.
    APPEND `  padding: 10px 16px; display: flex; flex-wrap: wrap; align-items: center; gap: 10px 18px; }` TO rt_lines.
    APPEND `.brand { display: flex; align-items: baseline; gap: 10px; }` TO rt_lines.
    APPEND `.brand b { font: 600 17px/1 var(--f-label); }` TO rt_lines.
    APPEND `.brand span { color: var(--muted); font-size: 12px; }` TO rt_lines.
    APPEND `.sys { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; margin-left: auto; }` TO rt_lines.
    APPEND `.chip { display: inline-flex; align-items: center; gap: 6px; padding: 3px 9px; border: 1px solid var(--line);` TO rt_lines.
    APPEND `  border-radius: 999px; font: 12px/1.4 var(--f-code); background: var(--sunk); color: var(--muted); white-space: nowrap; }` TO rt_lines.
    APPEND `.chip .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--muted); }` TO rt_lines.
    APPEND `.chip.ok { color: var(--ok); background: var(--ok-bg); border-color: transparent; }` TO rt_lines.
    APPEND `.chip.ok .dot { background: var(--ok); }` TO rt_lines.
    APPEND `.chip.warn { color: var(--warn); background: var(--warn-bg); border-color: transparent; }` TO rt_lines.
    APPEND `.chip.warn .dot { background: var(--warn); }` TO rt_lines.
    APPEND `.chip.err { color: var(--err); background: var(--err-bg); border-color: transparent; }` TO rt_lines.
    APPEND `.chip.err .dot { background: var(--err); }` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `.shell { display: grid; grid-template-columns: 300px minmax(0, 1fr); gap: 16px; padding: 16px 16px 28px;` TO rt_lines.
    APPEND `  max-width: 1640px; margin: 0 auto; }` TO rt_lines.
    APPEND `@media (max-width: 980px) { .shell { grid-template-columns: minmax(0, 1fr); } }` TO rt_lines.
    APPEND `.rail { display: flex; flex-direction: column; gap: 12px; min-width: 0; }` TO rt_lines.
    APPEND `details.sec { background: var(--panel); border: 1px solid var(--line); border-radius: var(--r); }` TO rt_lines.
    APPEND `details.sec > summary { list-style: none; cursor: pointer; padding: 10px 12px; display: flex; align-items: center; gap: 8px;` TO rt_lines.
    APPEND `  font: 600 12px/1.2 var(--f-label); letter-spacing: .07em; text-transform: uppercase; color: var(--muted); }` TO rt_lines.
    APPEND `details.sec > summary::-webkit-details-marker { display: none; }` TO rt_lines.
    APPEND `details.sec > summary::after { content: "\25BE"; margin-left: auto; }` TO rt_lines.
    APPEND `details.sec:not([open]) > summary::after { content: "\25B8"; }` TO rt_lines.
    APPEND `details.sec > summary .chip { text-transform: none; letter-spacing: 0; }` TO rt_lines.
    APPEND `.sec-body { padding: 2px 12px 12px; display: flex; flex-direction: column; gap: 10px; }` TO rt_lines.
    APPEND `.field { display: flex; flex-direction: column; gap: 4px; min-width: 0; }` TO rt_lines.
    APPEND `.field label, .lbl { font-size: 12px; color: var(--muted); }` TO rt_lines.
    APPEND `.field input[type=text], .field input[type=password], .field input[type=number], .field select {` TO rt_lines.
    APPEND `  width: 100%; padding: 6px 8px; border: 1px solid var(--line); border-radius: 4px; background: var(--sunk); }` TO rt_lines.
    APPEND `.field input:focus, .field select:focus { border-color: var(--accent); outline: none; box-shadow: 0 0 0 2px var(--accent-soft); }` TO rt_lines.
    APPEND `.mono { font-family: var(--f-code); font-size: 12.5px; }` TO rt_lines.
    APPEND `.row2 { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }` TO rt_lines.
    APPEND `.hint { font-size: 12px; color: var(--muted); }` TO rt_lines.
    APPEND `.seg { display: grid; grid-template-columns: 1fr 1fr; border: 1px solid var(--line); border-radius: 4px; overflow: hidden; }` TO rt_lines.
    APPEND `.seg input { position: absolute; opacity: 0; pointer-events: none; }` TO rt_lines.
    APPEND `.seg label { text-align: center; padding: 6px; font-size: 12.5px; color: var(--muted); cursor: pointer; background: var(--sunk); }` TO rt_lines.
    APPEND `.seg input:checked + label { background: var(--accent); color: var(--accent-ink); font-weight: 600; }` TO rt_lines.
    APPEND `.seg input:focus-visible + label { outline: 2px solid var(--accent); outline-offset: -2px; }` TO rt_lines.
    APPEND `.seg input:disabled + label { opacity: .45; cursor: not-allowed; }` TO rt_lines.
    APPEND `.tok { border: 1px dashed var(--line); border-radius: 4px; padding: 8px; display: flex; flex-direction: column; gap: 6px; background: var(--sunk); }` TO rt_lines.
    APPEND `.tok-line { display: flex; justify-content: space-between; gap: 8px; align-items: center; }` TO rt_lines.
    APPEND `.tok code { font: 12px var(--f-code); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }` TO rt_lines.
    APPEND `.bar { height: 4px; border-radius: 2px; background: var(--line); overflow: hidden; }` TO rt_lines.
    APPEND `.bar i { display: block; height: 100%; background: var(--ok); width: 0; }` TO rt_lines.
    APPEND `.ovr { display: grid; grid-template-columns: 1fr auto; gap: 6px 8px; align-items: center; }` TO rt_lines.
    APPEND `.ovr .k { font: 12.5px var(--f-code); }` TO rt_lines.
    APPEND `.tri { display: flex; border: 1px solid var(--line); border-radius: 4px; overflow: hidden; }` TO rt_lines.
    APPEND `.tri button { border: 0; background: var(--sunk); padding: 2px 7px; font: 11.5px var(--f-code); color: var(--muted); cursor: pointer; }` TO rt_lines.
    APPEND `.tri button[aria-pressed="true"] { background: var(--accent); color: var(--accent-ink); }` TO rt_lines.
    APPEND `.check { display: flex; gap: 8px; align-items: flex-start; font-size: 13px; }` TO rt_lines.
    APPEND `.check input { margin-top: 3px; }` TO rt_lines.
    APPEND `.hist { margin: 0; padding: 0; list-style: none; }` TO rt_lines.
    APPEND `.hist li { display: grid; grid-template-columns: auto 1fr auto; gap: 8px; align-items: baseline; padding: 6px 0;` TO rt_lines.
    APPEND `  border-top: 1px solid var(--line); font-size: 12px; }` TO rt_lines.
    APPEND `.hist li:first-child { border-top: 0; }` TO rt_lines.
    APPEND `.hist .t { font-family: var(--f-code); color: var(--muted); }` TO rt_lines.
    APPEND `.hist .q { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }` TO rt_lines.
    APPEND `.hist .f { grid-column: 2 / -1; font: 11.5px var(--f-code); color: var(--muted); overflow-wrap: anywhere; }` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `.work { display: flex; flex-direction: column; gap: 12px; min-width: 0; }` TO rt_lines.
    APPEND `.notice { border-radius: var(--r); padding: 10px 14px; display: flex; gap: 12px; align-items: flex-start; font-size: 13px; }` TO rt_lines.
    APPEND `.notice b { font-family: var(--f-label); }` TO rt_lines.
    APPEND `.notice.info { background: var(--info-bg); color: var(--info); }` TO rt_lines.
    APPEND `.notice.err { background: var(--err-bg); color: var(--err); }` TO rt_lines.
    APPEND `.notice code { font: 12.5px var(--f-code); }` TO rt_lines.
    APPEND `.panes { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 12px; }` TO rt_lines.
    APPEND `@media (max-width: 1180px) { .panes { grid-template-columns: minmax(0, 1fr); } }` TO rt_lines.
    APPEND `.pane { background: var(--panel); border: 1px solid var(--line); border-radius: var(--r); display: flex; flex-direction: column; min-width: 0; }` TO rt_lines.
    APPEND `.pane-h { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; padding: 10px 12px; border-bottom: 1px solid var(--line); }` TO rt_lines.
    APPEND `.pane-h h2 { margin: 0; font: 600 13px/1 var(--f-label); letter-spacing: .07em; text-transform: uppercase; }` TO rt_lines.
    APPEND `.sp { flex: 1; }` TO rt_lines.
    APPEND `.btn { display: inline-flex; align-items: center; gap: 6px; padding: 5px 10px; border-radius: 4px; border: 1px solid var(--line);` TO rt_lines.
    APPEND `  background: var(--panel); cursor: pointer; font-size: 13px; white-space: nowrap; }` TO rt_lines.
    APPEND `.btn:hover { border-color: var(--accent); color: var(--accent); }` TO rt_lines.
    APPEND `.btn:disabled { opacity: .45; cursor: not-allowed; }` TO rt_lines.
    APPEND `.btn.primary { background: var(--accent); border-color: var(--accent); color: var(--accent-ink); font-weight: 600; }` TO rt_lines.
    APPEND `.btn.primary:hover { color: var(--accent-ink); filter: brightness(1.08); }` TO rt_lines.
    APPEND `.btn.big { padding: 9px 18px; font-size: 14px; }` TO rt_lines.
    APPEND `.kbd { font: 11px var(--f-code); opacity: .8; border: 1px solid currentColor; border-radius: 3px; padding: 0 4px; }` TO rt_lines.
    APPEND `.editor { display: flex; flex: 1; min-height: 0; }` TO rt_lines.
    APPEND `textarea.code { flex: 1; width: 100%; min-height: 460px; resize: vertical; border: 0; margin: 0; padding: 12px 14px;` TO rt_lines.
    APPEND `  font: 13px/1.55 var(--f-code); background: var(--sunk); color: var(--ink); tab-size: 2; white-space: pre; overflow: auto; }` TO rt_lines.
    APPEND `textarea.code:focus { outline: none; box-shadow: inset 0 0 0 2px var(--accent-soft); }` TO rt_lines.
    APPEND `.pane-f { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; padding: 8px 12px; border-top: 1px solid var(--line);` TO rt_lines.
    APPEND `  font-size: 12px; color: var(--muted); }` TO rt_lines.
    APPEND `.applied { display: flex; flex-wrap: wrap; gap: 6px; }` TO rt_lines.
    APPEND `.applied .chip { font-size: 11.5px; padding: 1px 7px; color: var(--accent); background: var(--accent-soft); border-color: transparent; }` TO rt_lines.
    APPEND `.send { background: var(--panel); border: 1px solid var(--line); border-radius: var(--r); display: flex; flex-wrap: wrap;` TO rt_lines.
    APPEND `  align-items: center; gap: 12px 16px; padding: 10px 12px; }` TO rt_lines.
    APPEND `.steps { display: flex; flex-wrap: wrap; gap: 6px 14px; align-items: center; min-width: 0; flex: 1; }` TO rt_lines.
    APPEND `.step { display: flex; align-items: center; gap: 8px; font: 12.5px var(--f-code); color: var(--muted); min-width: 0; }` TO rt_lines.
    APPEND `.step .det { overflow-wrap: anywhere; }` TO rt_lines.
    APPEND `.step .n { width: 20px; height: 20px; flex: none; border-radius: 50%; display: grid; place-items: center; border: 1px solid var(--line);` TO rt_lines.
    APPEND `  font-size: 11px; background: var(--sunk); }` TO rt_lines.
    APPEND `.step.done .n { background: var(--ok); color: var(--panel); border-color: var(--ok); }` TO rt_lines.
    APPEND `.step.fail .n { background: var(--err); color: var(--panel); border-color: var(--err); }` TO rt_lines.
    APPEND `.step.run .n { border-color: var(--accent); color: var(--accent); }` TO rt_lines.
    APPEND `.step .what { color: var(--ink); }` TO rt_lines.
    APPEND `.summary { display: flex; flex-wrap: wrap; gap: 6px; padding: 10px 12px; border-bottom: 1px solid var(--line); }` TO rt_lines.
    APPEND `.stat { display: flex; flex-direction: column; gap: 1px; padding: 4px 8px; border-left: 2px solid var(--line); min-width: 70px; }` TO rt_lines.
    APPEND `.stat .l { font: 600 10.5px/1.2 var(--f-label); letter-spacing: .07em; text-transform: uppercase; color: var(--muted); }` TO rt_lines.
    APPEND `.stat .v { font: 600 14px/1.3 var(--f-code); }` TO rt_lines.
    APPEND `.status { font: 600 13px/1 var(--f-code); padding: 5px 9px; border-radius: 4px; align-self: center; }` TO rt_lines.
    APPEND `.status.ok { background: var(--ok-bg); color: var(--ok); }` TO rt_lines.
    APPEND `.status.err { background: var(--err-bg); color: var(--err); }` TO rt_lines.
    APPEND `.status.idle { background: var(--sunk); color: var(--muted); border: 1px solid var(--line); }` TO rt_lines.
    APPEND `.tabs { display: flex; gap: 2px; padding: 0 8px; border-bottom: 1px solid var(--line); overflow-x: auto; }` TO rt_lines.
    APPEND `.tabs button { border: 0; background: none; padding: 8px 10px; font-size: 13px; color: var(--muted); cursor: pointer;` TO rt_lines.
    APPEND `  border-bottom: 2px solid transparent; margin-bottom: -1px; white-space: nowrap; }` TO rt_lines.
    APPEND `.tabs button[aria-selected="true"] { color: var(--ink); border-bottom-color: var(--accent); font-weight: 600; }` TO rt_lines.
    APPEND `.cnt { font: 11px var(--f-code); margin-left: 4px; padding: 0 5px; border-radius: 8px; background: var(--sunk); border: 1px solid var(--line); }` TO rt_lines.
    APPEND `.cnt.err { background: var(--err-bg); color: var(--err); border-color: transparent; }` TO rt_lines.
    APPEND `.cnt.warn { background: var(--warn-bg); color: var(--warn); border-color: transparent; }` TO rt_lines.
    APPEND `.tabpanel { flex: 1; display: flex; flex-direction: column; min-height: 0; }` TO rt_lines.
    APPEND `.scroll { overflow: auto; max-height: 560px; min-height: 460px; background: var(--sunk); }` TO rt_lines.
    APPEND `table.rows { border-collapse: collapse; width: 100%; font: 12.5px var(--f-code); }` TO rt_lines.
    APPEND `table.rows th, table.rows td { text-align: left; padding: 6px 12px; border-bottom: 1px solid var(--line); white-space: nowrap; }` TO rt_lines.
    APPEND `table.rows th { position: sticky; top: 0; background: var(--panel); font: 600 11px var(--f-label); letter-spacing: .06em;` TO rt_lines.
    APPEND `  text-transform: uppercase; color: var(--muted); }` TO rt_lines.
    APPEND `table.rows td.num { text-align: right; }` TO rt_lines.
    APPEND `.msgs { display: flex; flex-direction: column; gap: 10px; padding: 12px; }` TO rt_lines.
    APPEND `.msg { border: 1px solid var(--line); border-left: 3px solid var(--muted); border-radius: 4px; padding: 10px 12px;` TO rt_lines.
    APPEND `  background: var(--panel); display: flex; flex-direction: column; gap: 6px; }` TO rt_lines.
    APPEND `.msg.err { border-left-color: var(--err); }` TO rt_lines.
    APPEND `.msg.warn { border-left-color: var(--warn); }` TO rt_lines.
    APPEND `.msg .h { display: flex; flex-wrap: wrap; gap: 8px; align-items: baseline; }` TO rt_lines.
    APPEND `.msg .code { font: 600 12.5px var(--f-code); }` TO rt_lines.
    APPEND `.msg.err .code { color: var(--err); }` TO rt_lines.
    APPEND `.msg.warn .code { color: var(--warn); }` TO rt_lines.
    APPEND `.msg pre { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font: 12px/1.5 var(--f-code); color: var(--muted);` TO rt_lines.
    APPEND `  background: var(--sunk); padding: 8px; border-radius: 4px; }` TO rt_lines.
    APPEND `.empty { padding: 28px 16px; color: var(--muted); text-align: center; font-size: 13px; }` TO rt_lines.
    APPEND `.cnts { display: flex; flex-direction: column; gap: 8px; padding: 12px; }` TO rt_lines.
    APPEND `.cnt-row { display: grid; grid-template-columns: minmax(0, 220px) 1fr auto; gap: 10px; align-items: center; font: 12.5px var(--f-code); }` TO rt_lines.
    APPEND `.cnt-row .nm { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }` TO rt_lines.
    APPEND `.cnt-row .b { height: 8px; border-radius: 2px; background: var(--line); overflow: hidden; }` TO rt_lines.
    APPEND `.cnt-row .b i { display: block; height: 100%; background: var(--accent); }` TO rt_lines.
    APPEND `.cnt-row.zero .nm, .cnt-row.zero .v { color: var(--err); font-weight: 600; }` TO rt_lines.
    APPEND `.sql { margin: 0 12px 12px; padding: 10px; border-radius: 4px; background: var(--panel); border: 1px solid var(--line);` TO rt_lines.
    APPEND `  font: 12px/1.55 var(--f-code); white-space: pre-wrap; overflow-wrap: anywhere; }` TO rt_lines.
    APPEND `.sub { padding: 12px 12px 0; font: 600 11px var(--f-label); letter-spacing: .07em; text-transform: uppercase; color: var(--muted); }` TO rt_lines.
    APPEND `.toast { position: fixed; right: 16px; bottom: 16px; max-width: min(460px, calc(100vw - 32px)); background: var(--ink);` TO rt_lines.
    APPEND `  color: var(--panel); padding: 10px 14px; border-radius: 6px; font-size: 13px; box-shadow: 0 6px 24px rgba(0,0,0,.25); z-index: 20; }` TO rt_lines.
    APPEND `</style>` TO rt_lines.
    APPEND `</head>` TO rt_lines.
    APPEND `<body>` TO rt_lines.
    APPEND `<header class="top">` TO rt_lines.
    APPEND `  <div class="brand"><b>DSL Query Console</b><span>JSON DSL Engine &middot; /sap/zdsl</span></div>` TO rt_lines.
    APPEND `  <div class="sys">` TO rt_lines.
    APPEND `    <span class="chip" id="hdrSys">__DSL_SYSID__ &middot; client __DSL_CLIENT__</span>` TO rt_lines.
    APPEND `    <span class="chip" id="hdrUser">__DSL_USER__</span>` TO rt_lines.
    APPEND `    <span class="chip" id="hdrWl">WHITELIST __DSL_WLMODE__</span>` TO rt_lines.
    APPEND `    <span class="chip warn" id="hdrTok"><span class="dot"></span><span>-</span></span>` TO rt_lines.
    APPEND `  </div>` TO rt_lines.
    APPEND `</header>` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `<div class="shell">` TO rt_lines.
    APPEND `  <aside class="rail" aria-label="Settings">` TO rt_lines.
    APPEND `    <details class="sec" open>` TO rt_lines.
    APPEND `      <summary>Run as</summary>` TO rt_lines.
    APPEND `      <div class="sec-body">` TO rt_lines.
    APPEND `        <div class="seg" role="radiogroup" aria-label="Run queries as">` TO rt_lines.
    APPEND `          <input type="radio" name="mode" id="modeUser" value="user" checked><label for="modeUser">My SAP user</label>` TO rt_lines.
    APPEND `          <input type="radio" name="mode" id="modeTok" value="token"><label for="modeTok">Service client</label>` TO rt_lines.
    APPEND `        </div>` TO rt_lines.
    APPEND `        <span class="hint" id="modeHint"></span>` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `        <div id="tokSettings" class="sec-body" style="padding:0">` TO rt_lines.
    APPEND `          <div class="field">` TO rt_lines.
    APPEND `            <label for="base">Endpoint base</label>` TO rt_lines.
    APPEND `            <input id="base" type="text" class="mono" value="/sap/zdsl" spellcheck="false">` TO rt_lines.
    APPEND `            <span class="hint">Token from <span class="mono">.../auth</span>, query to <span class="mono">.../query</span></span>` TO rt_lines.
    APPEND `          </div>` TO rt_lines.
    APPEND `          <div class="field">` TO rt_lines.
    APPEND `            <label for="cid">client_id</label>` TO rt_lines.
    APPEND `            <input id="cid" type="text" class="mono" spellcheck="false" autocomplete="off">` TO rt_lines.
    APPEND `          </div>` TO rt_lines.
    APPEND `          <div class="field">` TO rt_lines.
    APPEND `            <label for="csec">client_secret</label>` TO rt_lines.
    APPEND `            <input id="csec" type="password" class="mono" autocomplete="off">` TO rt_lines.
    APPEND `          </div>` TO rt_lines.
    APPEND `          <div class="field">` TO rt_lines.
    APPEND `            <span class="lbl">Send token in</span>` TO rt_lines.
    APPEND `            <div class="seg" role="radiogroup" aria-label="Token header">` TO rt_lines.
    APPEND `              <input type="radio" name="hdr" id="hdrX" value="x" checked><label for="hdrX" class="mono">X-DSL-Token</label>` TO rt_lines.
    APPEND `              <input type="radio" name="hdr" id="hdrA" value="a"><label for="hdrA" class="mono">Authorization</label>` TO rt_lines.
    APPEND `            </div>` TO rt_lines.
    APPEND `          </div>` TO rt_lines.
    APPEND `          <div class="tok" aria-live="polite">` TO rt_lines.
    APPEND `            <div class="tok-line"><span class="lbl">Token</span><span class="chip" id="tokState"><span class="dot"></span><span>none</span></span></div>` TO rt_lines.
    APPEND `            <code id="tokVal">-</code>` TO rt_lines.
    APPEND `            <div class="bar" aria-hidden="true"><i id="tokBar"></i></div>` TO rt_lines.
    APPEND `            <div class="tok-line">` TO rt_lines.
    APPEND `              <label class="check hint"><input type="checkbox" id="autoAuth" checked> Get token automatically</label>` TO rt_lines.
    APPEND `              <button class="btn" id="btnAuth" type="button">Get token</button>` TO rt_lines.
    APPEND `            </div>` TO rt_lines.
    APPEND `            <span class="hint">Kept in page memory only. Reloading the page discards it.</span>` TO rt_lines.
    APPEND `          </div>` TO rt_lines.
    APPEND `        </div>` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `        <div class="row2">` TO rt_lines.
    APPEND `          <div class="field">` TO rt_lines.
    APPEND `            <label for="client">sap-client</label>` TO rt_lines.
    APPEND `            <input id="client" type="text" class="mono" value="__DSL_CLIENT__">` TO rt_lines.
    APPEND `          </div>` TO rt_lines.
    APPEND `          <div class="field">` TO rt_lines.
    APPEND `            <label for="timeout">Timeout (s)</label>` TO rt_lines.
    APPEND `            <input id="timeout" type="number" class="mono" value="120" min="5" max="900">` TO rt_lines.
    APPEND `          </div>` TO rt_lines.
    APPEND `        </div>` TO rt_lines.
    APPEND `      </div>` TO rt_lines.
    APPEND `    </details>` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `    <details class="sec" open>` TO rt_lines.
    APPEND `      <summary>Request options <span class="chip" id="ovrCount">0 applied</span></summary>` TO rt_lines.
    APPEND `      <div class="sec-body">` TO rt_lines.
    APPEND `        <span class="hint">Values set here replace the matching keys in the request when you send it. "as is" leaves the request unchanged.</span>` TO rt_lines.
    APPEND `        <div class="field">` TO rt_lines.
    APPEND `          <span class="lbl">output</span>` TO rt_lines.
    APPEND `          <div id="triList" class="ovr"></div>` TO rt_lines.
    APPEND `        </div>` TO rt_lines.
    APPEND `        <div class="field">` TO rt_lines.
    APPEND `          <span class="lbl">limit</span>` TO rt_lines.
    APPEND `          <div class="row2">` TO rt_lines.
    APPEND `            <div class="field"><label for="oRows" class="mono">rows</label><input id="oRows" type="number" class="mono" placeholder="as is" min="1"></div>` TO rt_lines.
    APPEND `            <div class="field"><label for="oPage" class="mono">page_size</label><input id="oPage" type="number" class="mono" placeholder="as is" min="1"></div>` TO rt_lines.
    APPEND `          </div>` TO rt_lines.
    APPEND `          <span class="hint">Above MAX_ROWS_ALLOWED the engine rejects the request (DSL_GUARD_001).</span>` TO rt_lines.
    APPEND `        </div>` TO rt_lines.
    APPEND `        <div class="row2">` TO rt_lines.
    APPEND `          <div class="field">` TO rt_lines.
    APPEND `            <label for="oVer" class="mono">version</label>` TO rt_lines.
    APPEND `            <select id="oVer" class="mono"><option value="">as is</option><option>1.3</option><option>1.2</option></select>` TO rt_lines.
    APPEND `          </div>` TO rt_lines.
    APPEND `          <div class="field">` TO rt_lines.
    APPEND `            <label for="oQid" class="mono">query_id</label>` TO rt_lines.
    APPEND `            <input id="oQid" type="text" class="mono" placeholder="as is">` TO rt_lines.
    APPEND `          </div>` TO rt_lines.
    APPEND `        </div>` TO rt_lines.
    APPEND `      </div>` TO rt_lines.
    APPEND `    </details>` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `    <details class="sec" open>` TO rt_lines.
    APPEND `      <summary>Save responses</summary>` TO rt_lines.
    APPEND `      <div class="sec-body">` TO rt_lines.
    APPEND `        <label class="check"><input type="checkbox" id="autoSave" checked> Save every response automatically</label>` TO rt_lines.
    APPEND `        <label class="check"><input type="checkbox" id="saveReq"> Include the sent request in the file</label>` TO rt_lines.
    APPEND `        <label class="check"><input type="checkbox" id="askWhere"> Ask where to save (Save button, Chrome and Edge)</label>` TO rt_lines.
    APPEND `        <div class="field">` TO rt_lines.
    APPEND `          <label for="fname">File name pattern</label>` TO rt_lines.
    APPEND `          <input id="fname" type="text" class="mono" value="{query_id}_{yyyyMMdd-HHmmss}_{status}.json" spellcheck="false">` TO rt_lines.
    APPEND `          <span class="hint">Tokens: {query_id} {metricId} {status} {page} {yyyyMMdd-HHmmss}. Automatic saves go to the browser's Downloads folder.</span>` TO rt_lines.
    APPEND `        </div>` TO rt_lines.
    APPEND `      </div>` TO rt_lines.
    APPEND `    </details>` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `    <details class="sec">` TO rt_lines.
    APPEND `      <summary>Session history <span class="chip" id="histCount">0</span></summary>` TO rt_lines.
    APPEND `      <div class="sec-body">` TO rt_lines.
    APPEND `        <ul class="hist" id="hist"></ul>` TO rt_lines.
    APPEND `        <div class="hint" id="histEmpty">Runs from this session appear here with the file each one was saved to.</div>` TO rt_lines.
    APPEND `      </div>` TO rt_lines.
    APPEND `    </details>` TO rt_lines.
    APPEND `  </aside>` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `  <main class="work">` TO rt_lines.
    APPEND `    <div class="notice info" id="authNotice">` TO rt_lines.
    APPEND `      <div>` TO rt_lines.
    APPEND `        <b>Queries run as your SAP user __DSL_USER__.</b>` TO rt_lines.
    APPEND `        You need display authorization for every table in the request: <code>S_TABU_DIS</code> for the table's` TO rt_lines.
    APPEND `        authorization group, or <code>S_TABU_NAM</code> for the table itself. The console checks this before it runs a query` TO rt_lines.
    APPEND `        and stops with <code>DSL_AUTH_006</code> if one is missing. The engine whitelist (mode __DSL_WLMODE__) applies as well.` TO rt_lines.
    APPEND `      </div>` TO rt_lines.
    APPEND `    </div>` TO rt_lines.
    APPEND `    <div class="notice err" id="svcNotice" hidden>` TO rt_lines.
    APPEND `      <div>` TO rt_lines.
    APPEND `        <b>This page is running as service user __DSL_USER__, not as a person.</b>` TO rt_lines.
    APPEND `        The SICF node <code>/sap/zdsl/console</code> has fixed logon data. Remove it so that people log on with their own user.` TO rt_lines.
    APPEND `        Until then only the service-client mode is available.` TO rt_lines.
    APPEND `      </div>` TO rt_lines.
    APPEND `    </div>` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `    <div class="send">` TO rt_lines.
    APPEND `      <button class="btn primary big" id="btnSend" type="button">Send request <span class="kbd">Ctrl+Enter</span></button>` TO rt_lines.
    APPEND `      <div class="steps" aria-live="polite">` TO rt_lines.
    APPEND `        <div class="step" id="stAuth"><span class="n">1</span><span><span class="what" id="stAuthWhat">Logon</span> <span class="det">-</span></span></div>` TO rt_lines.
    APPEND `        <div class="step" id="stQry"><span class="n">2</span><span><span class="what">Query</span> <span class="det">-</span></span></div>` TO rt_lines.
    APPEND `        <div class="step" id="stSave"><span class="n">3</span><span><span class="what">Save</span> <span class="det">-</span></span></div>` TO rt_lines.
    APPEND `      </div>` TO rt_lines.
    APPEND `    </div>` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `    <div class="panes">` TO rt_lines.
    APPEND `      <section class="pane" aria-label="Request">` TO rt_lines.
    APPEND `        <div class="pane-h">` TO rt_lines.
    APPEND `          <h2>Request</h2>` TO rt_lines.
    APPEND `          <span class="sp"></span>` TO rt_lines.
    APPEND `          <select class="btn" id="preset" aria-label="Load an example">` TO rt_lines.
    APPEND `            <option value="">Load example...</option>` TO rt_lines.
    APPEND `            <option value="template">Engine template (GET /query)</option>` TO rt_lines.
    APPEND `            <option value="single">Single table: dialog users</option>` TO rt_lines.
    APPEND `            <option value="join">Join + group: users with many roles</option>` TO rt_lines.
    APPEND `            <option value="union">Union count: holders of two roles</option>` TO rt_lines.
    APPEND `            <option value="subq">Subquery: users without any role</option>` TO rt_lines.
    APPEND `          </select>` TO rt_lines.
    APPEND `          <button class="btn" id="btnOpen" type="button">Open file...</button>` TO rt_lines.
    APPEND `          <input type="file" id="file" accept=".json,application/json" hidden>` TO rt_lines.
    APPEND `          <button class="btn" id="btnFmt" type="button">Format</button>` TO rt_lines.
    APPEND `        </div>` TO rt_lines.
    APPEND `        <div class="editor"><textarea id="req" class="code" spellcheck="false" aria-label="Request JSON"></textarea></div>` TO rt_lines.
    APPEND `        <div class="pane-f">` TO rt_lines.
    APPEND `          <span id="reqState" class="chip"><span class="dot"></span><span>-</span></span>` TO rt_lines.
    APPEND `          <span id="reqMode" class="mono"></span>` TO rt_lines.
    APPEND `          <span class="sp"></span>` TO rt_lines.
    APPEND `          <div class="applied" id="applied"></div>` TO rt_lines.
    APPEND `        </div>` TO rt_lines.
    APPEND `      </section>` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `      <section class="pane" aria-label="Response">` TO rt_lines.
    APPEND `        <div class="pane-h">` TO rt_lines.
    APPEND `          <h2>Response</h2>` TO rt_lines.
    APPEND `          <span class="sp"></span>` TO rt_lines.
    APPEND `          <button class="btn" id="btnNext" type="button" disabled title="Fetch the next page with meta.next_page_token">Next page</button>` TO rt_lines.
    APPEND `          <button class="btn" id="btnCopy" type="button" disabled>Copy</button>` TO rt_lines.
    APPEND `          <button class="btn" id="btnSave" type="button" disabled>Save .json</button>` TO rt_lines.
    APPEND `        </div>` TO rt_lines.
    APPEND `        <div class="summary">` TO rt_lines.
    APPEND `          <span class="status idle" id="httpStatus">Not sent</span>` TO rt_lines.
    APPEND `          <div class="stat"><span class="l">rows</span><span class="v" id="sRows">-</span></div>` TO rt_lines.
    APPEND `          <div class="stat"><span class="l">count</span><span class="v" id="sAgg">-</span></div>` TO rt_lines.
    APPEND `          <div class="stat"><span class="l">strategy</span><span class="v" id="sStrat">-</span></div>` TO rt_lines.
    APPEND `          <div class="stat"><span class="l">engine time</span><span class="v" id="sTime">-</span></div>` TO rt_lines.
    APPEND `          <div class="stat"><span class="l">more pages</span><span class="v" id="sMore">-</span></div>` TO rt_lines.
    APPEND `        </div>` TO rt_lines.
    APPEND `        <div class="tabs" role="tablist">` TO rt_lines.
    APPEND `          <button role="tab" aria-selected="true" data-tab="raw">Response JSON</button>` TO rt_lines.
    APPEND `          <button role="tab" aria-selected="false" data-tab="rows">Rows<span class="cnt" id="cRows">0</span></button>` TO rt_lines.
    APPEND `          <button role="tab" aria-selected="false" data-tab="msgs">Messages<span class="cnt" id="cMsgs">0</span></button>` TO rt_lines.
    APPEND `          <button role="tab" aria-selected="false" data-tab="debug">Debug</button>` TO rt_lines.
    APPEND `          <button role="tab" aria-selected="false" data-tab="sent">Sent request</button>` TO rt_lines.
    APPEND `        </div>` TO rt_lines.
    APPEND `        <div class="tabpanel" data-panel="raw">` TO rt_lines.
    APPEND `          <div class="editor"><textarea id="resp" class="code" readonly spellcheck="false" aria-label="Response JSON"` TO rt_lines.
    APPEND `            placeholder="The response appears here."></textarea></div>` TO rt_lines.
    APPEND `        </div>` TO rt_lines.
    APPEND `        <div class="tabpanel" data-panel="rows" hidden><div class="scroll" id="rowsBox"></div></div>` TO rt_lines.
    APPEND `        <div class="tabpanel" data-panel="msgs" hidden><div class="scroll"><div class="msgs" id="msgsBox"></div></div></div>` TO rt_lines.
    APPEND `        <div class="tabpanel" data-panel="debug" hidden><div class="scroll" id="dbgBox"></div></div>` TO rt_lines.
    APPEND `        <div class="tabpanel" data-panel="sent" hidden>` TO rt_lines.
    APPEND `          <div class="editor"><textarea id="sent" class="code" readonly spellcheck="false" aria-label="Request as sent"></textarea></div>` TO rt_lines.
    APPEND `        </div>` TO rt_lines.
    APPEND `        <div class="pane-f"><span id="saveInfo">Nothing saved yet</span></div>` TO rt_lines.
    APPEND `      </section>` TO rt_lines.
    APPEND `    </div>` TO rt_lines.
    APPEND `  </main>` TO rt_lines.
    APPEND `</div>` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `<div class="toast" id="toast" role="status" hidden></div>` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `<script>` TO rt_lines.
    APPEND `(function () {` TO rt_lines.
    APPEND `  "use strict";` TO rt_lines.
    APPEND `  var CFG = { user: "__DSL_USER__", client: "__DSL_CLIENT__", isSvc: "__DSL_ISSVC__" === "X" };` TO rt_lines.
    APPEND `  var STORE = "zdsl.console.v1";` TO rt_lines.
    APPEND `  var $ = function (id) { return document.getElementById(id); };` TO rt_lines.
    APPEND `  var DOT = "\u00b7";` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `  /* ---------- examples (generic only: our metric catalog never ships to a client system) ---------- */` TO rt_lines.
    APPEND `  var PRESETS = {` TO rt_lines.
    APPEND `    single: {` TO rt_lines.
    APPEND `      version: "1.3", query_id: "DIALOG-USERS",` TO rt_lines.
    APPEND `      sources: [{ table: "USR02", alias: "u" }],` TO rt_lines.
    APPEND `      select: [{ field: "u.BNAME", alias: "user" }, { field: "u.TRDAT", alias: "last_logon" }],` TO rt_lines.
    APPEND `      filters: { logic: "AND", conditions: [{ field: "u.USTYP", op: "IN", value: ["A"] }] },` TO rt_lines.
    APPEND `      order_by: [{ field: "u.BNAME", direction: "asc" }],` TO rt_lines.
    APPEND `      limit: { rows: 200, page_size: 50 }` TO rt_lines.
    APPEND `    },` TO rt_lines.
    APPEND `    join: {` TO rt_lines.
    APPEND `      version: "1.3", query_id: "USERS-MANY-ROLES",` TO rt_lines.
    APPEND `      sources: [{ table: "USR02", alias: "u" }],` TO rt_lines.
    APPEND `      joins: [{ type: "inner", target: { table: "AGR_USERS", alias: "ru" },` TO rt_lines.
    APPEND `        on: { logic: "AND", conditions: [{ left: "u.BNAME", op: "=", right: "ru.UNAME" }] } }],` TO rt_lines.
    APPEND `      select: [{ field: "u.BNAME", alias: "user" }],` TO rt_lines.
    APPEND `      metrics: [{ type: "count", field: "*", alias: "role_count" }],` TO rt_lines.
    APPEND `      filters: { logic: "AND", conditions: [{ field: "ru.TO_DAT", op: ">=", param: "asOf" }] },` TO rt_lines.
    APPEND `      group_by: ["u.BNAME"],` TO rt_lines.
    APPEND `      having: [{ metric: "role_count", op: ">", value: 20 }],` TO rt_lines.
    APPEND `      order_by: [{ field: "role_count", direction: "desc" }],` TO rt_lines.
    APPEND `      limit: { rows: 500 },` TO rt_lines.
    APPEND `      params: { asOf: "20260101" }` TO rt_lines.
    APPEND `    },` TO rt_lines.
    APPEND `    union: {` TO rt_lines.
    APPEND `      version: "1.3", query_id: "ROLE-HOLDERS",` TO rt_lines.
    APPEND `      union: { distinct: true, branches: [` TO rt_lines.
    APPEND `        { sources: [{ table: "AGR_USERS", alias: "a" }], select: [{ field: "a.UNAME", alias: "user" }],` TO rt_lines.
    APPEND `          filters: { logic: "AND", conditions: [{ field: "a.AGR_NAME", op: "IN", value: ["SAP_ALL"] }] } },` TO rt_lines.
    APPEND `        { sources: [{ table: "AGR_USERS", alias: "b" }], select: [{ field: "b.UNAME", alias: "user" }],` TO rt_lines.
    APPEND `          filters: { logic: "AND", conditions: [{ field: "b.AGR_NAME", op: "IN", value: ["SAP_NEW"] }] } }` TO rt_lines.
    APPEND `      ] },` TO rt_lines.
    APPEND `      metrics: [{ type: "count", field: "*", alias: "holders" }],` TO rt_lines.
    APPEND `      output: { include_rows: false, include_aggregates: true }` TO rt_lines.
    APPEND `    },` TO rt_lines.
    APPEND `    subq: {` TO rt_lines.
    APPEND `      version: "1.3", query_id: "USERS-NO-ROLE",` TO rt_lines.
    APPEND `      sources: [{ table: "USR02", alias: "u" }],` TO rt_lines.
    APPEND `      select: [{ field: "u.BNAME", alias: "user" }],` TO rt_lines.
    APPEND `      filters: { logic: "AND", conditions: [` TO rt_lines.
    APPEND `        { field: "u.USTYP", op: "IN", value: ["A"] },` TO rt_lines.
    APPEND `        { field: "u.BNAME", op: "NOT IN", subquery: {` TO rt_lines.
    APPEND `          sources: [{ table: "AGR_USERS", alias: "su" }], select: [{ field: "su.UNAME", alias: "uname" }] } }` TO rt_lines.
    APPEND `      ] },` TO rt_lines.
    APPEND `      limit: { rows: 200 }` TO rt_lines.
    APPEND `    }` TO rt_lines.
    APPEND `  };` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `  /* ---------- settings persistence (no secrets, no tokens) ---------- */` TO rt_lines.
    APPEND `  var KEEP = ["base", "cid", "client", "timeout", "oRows", "oPage", "oVer", "oQid", "fname"];` TO rt_lines.
    APPEND `  var KEEP_CHK = ["autoAuth", "autoSave", "saveReq", "askWhere"];` TO rt_lines.
    APPEND `  function loadSettings() {` TO rt_lines.
    APPEND `    var s = null;` TO rt_lines.
    APPEND `    try { s = JSON.parse(localStorage.getItem(STORE) || "null"); } catch (e) { s = null; }` TO rt_lines.
    APPEND `    return s || {};` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  function saveSettings() {` TO rt_lines.
    APPEND `    var s = { tri: tri, mode: mode(), hdr: hdrMode(), draft: $("req").value };` TO rt_lines.
    APPEND `    KEEP.forEach(function (id) { s[id] = $(id).value; });` TO rt_lines.
    APPEND `    KEEP_CHK.forEach(function (id) { s[id] = $(id).checked; });` TO rt_lines.
    APPEND `    try { localStorage.setItem(STORE, JSON.stringify(s)); } catch (e) { /* storage blocked: settings just aren't kept */ }` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  var saved = loadSettings();` TO rt_lines.
    APPEND `  KEEP.forEach(function (id) { if (saved[id] !== undefined) $(id).value = saved[id]; });` TO rt_lines.
    APPEND `  KEEP_CHK.forEach(function (id) { if (saved[id] !== undefined) $(id).checked = saved[id]; });` TO rt_lines.
    APPEND `  if (!saved.client) $("client").value = CFG.client;` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `  /* ---------- mode ---------- */` TO rt_lines.
    APPEND `  function mode() { return $("modeTok").checked ? "token" : "user"; }` TO rt_lines.
    APPEND `  function hdrMode() { return $("hdrA").checked ? "a" : "x"; }` TO rt_lines.
    APPEND `  if (saved.mode === "token" || CFG.isSvc) $("modeTok").checked = true;` TO rt_lines.
    APPEND `  if (saved.hdr === "a") $("hdrA").checked = true;` TO rt_lines.
    APPEND `  if (CFG.isSvc) { $("modeUser").disabled = true; $("svcNotice").hidden = false; }` TO rt_lines.
    APPEND `  function paintMode() {` TO rt_lines.
    APPEND `    var tok = mode() === "token";` TO rt_lines.
    APPEND `    $("tokSettings").hidden = !tok;` TO rt_lines.
    APPEND `    $("authNotice").hidden = tok || CFG.isSvc;` TO rt_lines.
    APPEND `    $("stAuthWhat").textContent = tok ? "POST /auth" : "Logon";` TO rt_lines.
    APPEND `    $("modeHint").textContent = tok` TO rt_lines.
    APPEND `      ? "Same path as our external application: client_id and secret give a token, the query runs as the client's service user."` TO rt_lines.
    APPEND `      : "Runs the query directly as you. No token needed; the audit log records your user name.";` TO rt_lines.
    APPEND `    paintToken();` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  ["modeUser", "modeTok"].forEach(function (id) { $(id).addEventListener("change", function () { paintMode(); saveSettings(); }); });` TO rt_lines.
    APPEND `  ["hdrX", "hdrA"].forEach(function (id) { $(id).addEventListener("change", saveSettings); });` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `  /* ---------- output overrides (as is / true / false) ---------- */` TO rt_lines.
    APPEND `  var OUT_KEYS = ["include_rows", "include_aggregates", "include_summary", "debug"];` TO rt_lines.
    APPEND `  var tri = saved.tri || { include_rows: null, include_aggregates: null, include_summary: null, debug: null };` TO rt_lines.
    APPEND `  OUT_KEYS.forEach(function (k) {` TO rt_lines.
    APPEND `    var name = document.createElement("span");` TO rt_lines.
    APPEND `    name.className = "k"; name.textContent = k;` TO rt_lines.
    APPEND `    var g = document.createElement("div");` TO rt_lines.
    APPEND `    g.className = "tri"; g.setAttribute("role", "group"); g.setAttribute("aria-label", k);` TO rt_lines.
    APPEND `    [["as is", null], ["true", true], ["false", false]].forEach(function (p) {` TO rt_lines.
    APPEND `      var b = document.createElement("button");` TO rt_lines.
    APPEND `      b.type = "button"; b.textContent = p[0];` TO rt_lines.
    APPEND `      b.setAttribute("aria-pressed", String(tri[k] === p[1]));` TO rt_lines.
    APPEND `      b.addEventListener("click", function () {` TO rt_lines.
    APPEND `        tri[k] = p[1];` TO rt_lines.
    APPEND `        Array.prototype.forEach.call(g.children, function (x) { x.setAttribute("aria-pressed", "false"); });` TO rt_lines.
    APPEND `        b.setAttribute("aria-pressed", "true");` TO rt_lines.
    APPEND `        refreshApplied(); saveSettings();` TO rt_lines.
    APPEND `      });` TO rt_lines.
    APPEND `      g.appendChild(b);` TO rt_lines.
    APPEND `    });` TO rt_lines.
    APPEND `    $("triList").appendChild(name); $("triList").appendChild(g);` TO rt_lines.
    APPEND `  });` TO rt_lines.
    APPEND `  function overrides() {` TO rt_lines.
    APPEND `    var o = [];` TO rt_lines.
    APPEND `    OUT_KEYS.forEach(function (k) { if (tri[k] !== null && tri[k] !== undefined) o.push(["output." + k, tri[k]]); });` TO rt_lines.
    APPEND `    if ($("oRows").value) o.push(["limit.rows", Number($("oRows").value)]);` TO rt_lines.
    APPEND `    if ($("oPage").value) o.push(["limit.page_size", Number($("oPage").value)]);` TO rt_lines.
    APPEND `    if ($("oVer").value) o.push(["version", $("oVer").value]);` TO rt_lines.
    APPEND `    if ($("oQid").value.trim()) o.push(["query_id", $("oQid").value.trim()]);` TO rt_lines.
    APPEND `    return o;` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  function applyOverrides(obj) {` TO rt_lines.
    APPEND `    var out = JSON.parse(JSON.stringify(obj));` TO rt_lines.
    APPEND `    overrides().forEach(function (p) {` TO rt_lines.
    APPEND `      var parts = p[0].split("."), cur = out;` TO rt_lines.
    APPEND `      for (var i = 0; i < parts.length - 1; i++) {` TO rt_lines.
    APPEND `        if (typeof cur[parts[i]] !== "object" || cur[parts[i]] === null) cur[parts[i]] = {};` TO rt_lines.
    APPEND `        cur = cur[parts[i]];` TO rt_lines.
    APPEND `      }` TO rt_lines.
    APPEND `      cur[parts[parts.length - 1]] = p[1];` TO rt_lines.
    APPEND `    });` TO rt_lines.
    APPEND `    return out;` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  function refreshApplied() {` TO rt_lines.
    APPEND `    var o = overrides();` TO rt_lines.
    APPEND `    $("ovrCount").textContent = o.length + " applied";` TO rt_lines.
    APPEND `    var box = $("applied"); box.innerHTML = "";` TO rt_lines.
    APPEND `    o.forEach(function (p) {` TO rt_lines.
    APPEND `      var c = document.createElement("span"); c.className = "chip"; c.textContent = p[0] + " = " + JSON.stringify(p[1]);` TO rt_lines.
    APPEND `      box.appendChild(c);` TO rt_lines.
    APPEND `    });` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  ["oRows", "oPage", "oVer", "oQid"].forEach(function (id) {` TO rt_lines.
    APPEND `    $(id).addEventListener("input", function () { refreshApplied(); saveSettings(); });` TO rt_lines.
    APPEND `  });` TO rt_lines.
    APPEND `  ["base", "cid", "client", "timeout", "fname"].forEach(function (id) { $(id).addEventListener("change", saveSettings); });` TO rt_lines.
    APPEND `  KEEP_CHK.forEach(function (id) { $(id).addEventListener("change", saveSettings); });` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `  /* ---------- request editor ---------- */` TO rt_lines.
    APPEND `  var req = $("req");` TO rt_lines.
    APPEND `  function setReq(obj) { req.value = JSON.stringify(obj, null, 2); checkReq(); saveSettings(); }` TO rt_lines.
    APPEND `  function checkReq() {` TO rt_lines.
    APPEND `    var st = $("reqState"), md = $("reqMode");` TO rt_lines.
    APPEND `    try {` TO rt_lines.
    APPEND `      var o = JSON.parse(req.value);` TO rt_lines.
    APPEND `      st.className = "chip ok"; st.lastChild.textContent = "Valid JSON";` TO rt_lines.
    APPEND `      var m = o.union ? "union" : o.entity ? "entity" : o.sources ? "raw" : "no source";` TO rt_lines.
    APPEND `      md.textContent = "v" + (o.version || "?") + " " + DOT + " " + m + " mode";` TO rt_lines.
    APPEND `      return o;` TO rt_lines.
    APPEND `    } catch (e) {` TO rt_lines.
    APPEND `      st.className = "chip err"; st.lastChild.textContent = "Invalid JSON";` TO rt_lines.
    APPEND `      md.textContent = String(e.message).slice(0, 80);` TO rt_lines.
    APPEND `      return null;` TO rt_lines.
    APPEND `    }` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  var draftTimer;` TO rt_lines.
    APPEND `  req.addEventListener("input", function () { checkReq(); clearTimeout(draftTimer); draftTimer = setTimeout(saveSettings, 600); });` TO rt_lines.
    APPEND `  req.addEventListener("keydown", function (e) {` TO rt_lines.
    APPEND `    if (e.key === "Tab" && !e.shiftKey) { e.preventDefault(); req.setRangeText("  ", req.selectionStart, req.selectionEnd, "end"); }` TO rt_lines.
    APPEND `  });` TO rt_lines.
    APPEND `  $("preset").addEventListener("change", function (e) {` TO rt_lines.
    APPEND `    var v = e.target.value; e.target.value = "";` TO rt_lines.
    APPEND `    if (v === "template") { loadTemplate(); return; }` TO rt_lines.
    APPEND `    if (PRESETS[v]) setReq(PRESETS[v]);` TO rt_lines.
    APPEND `  });` TO rt_lines.
    APPEND `  $("btnFmt").addEventListener("click", function () {` TO rt_lines.
    APPEND `    var o = checkReq(); if (o) setReq(o); else toast("Fix the JSON first: " + $("reqMode").textContent);` TO rt_lines.
    APPEND `  });` TO rt_lines.
    APPEND `  $("btnOpen").addEventListener("click", function () { $("file").click(); });` TO rt_lines.
    APPEND `  $("file").addEventListener("change", function (e) {` TO rt_lines.
    APPEND `    var f = e.target.files[0]; if (!f) return;` TO rt_lines.
    APPEND `    var r = new FileReader();` TO rt_lines.
    APPEND `    r.onload = function () { req.value = String(r.result); var o = checkReq(); if (o) setReq(o); toast("Loaded " + f.name); };` TO rt_lines.
    APPEND `    r.readAsText(f); e.target.value = "";` TO rt_lines.
    APPEND `  });` TO rt_lines.
    APPEND `  function loadTemplate() {` TO rt_lines.
    APPEND `    callJson(withClient(base() + "/query"), { method: "GET" }).then(function (r) {` TO rt_lines.
    APPEND `      if (r.body && r.body.template) { setReq(r.body.template); toast("Loaded the engine's own template"); }` TO rt_lines.
    APPEND `      else toast("Could not load the template from " + base() + "/query (HTTP " + r.status + ")");` TO rt_lines.
    APPEND `    });` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `  /* ---------- HTTP ---------- */` TO rt_lines.
    APPEND `  function base() { return $("base").value.replace(/\/+$/, "") || "/sap/zdsl"; }` TO rt_lines.
    APPEND `  function withClient(url) {` TO rt_lines.
    APPEND `    var c = $("client").value.trim();` TO rt_lines.
    APPEND `    return c ? url + (url.indexOf("?") < 0 ? "?" : "&") + "sap-client=" + encodeURIComponent(c) : url;` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  function timeoutMs() { return Math.max(5, Number($("timeout").value) || 120) * 1000; }` TO rt_lines.
    APPEND `  function callJson(url, opts) {` TO rt_lines.
    APPEND `    var ctl = new AbortController(), ms = timeoutMs();` TO rt_lines.
    APPEND `    var timer = setTimeout(function () { ctl.abort(); }, ms);` TO rt_lines.
    APPEND `    var t0 = performance.now();` TO rt_lines.
    APPEND `    var o = { signal: ctl.signal, credentials: "same-origin", cache: "no-store" };` TO rt_lines.
    APPEND `    Object.keys(opts).forEach(function (k) { o[k] = opts[k]; });` TO rt_lines.
    APPEND `    return fetch(url, o).then(function (res) {` TO rt_lines.
    APPEND `      return res.text().then(function (text) {` TO rt_lines.
    APPEND `        var body = null;` TO rt_lines.
    APPEND `        try { body = JSON.parse(text); } catch (e) { body = null; }` TO rt_lines.
    APPEND `        return { status: res.status, body: body, text: text, ms: Math.round(performance.now() - t0) };` TO rt_lines.
    APPEND `      });` TO rt_lines.
    APPEND `    }).catch(function (e) {` TO rt_lines.
    APPEND `      var msg = e && e.name === "AbortError" ? "No answer within " + ms / 1000 + " s" : "Network error: " + e;` TO rt_lines.
    APPEND `      return { status: 0, body: null, text: msg, ms: Math.round(performance.now() - t0) };` TO rt_lines.
    APPEND `    }).then(function (r) { clearTimeout(timer); return r; });` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `  /* ---------- token (service-client mode) ---------- */` TO rt_lines.
    APPEND `  var token = null;` TO rt_lines.
    APPEND `  function tokenValid() { return token !== null && token.exp > Date.now(); }` TO rt_lines.
    APPEND `  function paintToken() {` TO rt_lines.
    APPEND `    var st = $("tokState"), hdr = $("hdrTok");` TO rt_lines.
    APPEND `    if (mode() === "user") {` TO rt_lines.
    APPEND `      hdr.className = "chip ok"; hdr.lastChild.textContent = "Signed in";` TO rt_lines.
    APPEND `    } else if (tokenValid()) {` TO rt_lines.
    APPEND `      var left = Math.max(0, Math.round((token.exp - Date.now()) / 1000));` TO rt_lines.
    APPEND `      var mmss = String(Math.floor(left / 60)).padStart(2, "0") + ":" + String(left % 60).padStart(2, "0");` TO rt_lines.
    APPEND `      st.className = "chip ok"; st.lastChild.textContent = "valid " + mmss;` TO rt_lines.
    APPEND `      hdr.className = "chip ok"; hdr.lastChild.textContent = "Token " + mmss;` TO rt_lines.
    APPEND `      $("tokVal").textContent = token.value.slice(0, 10) + "..." + token.value.slice(-6);` TO rt_lines.
    APPEND `      $("tokBar").style.width = (left / token.ttl * 100) + "%";` TO rt_lines.
    APPEND `    } else {` TO rt_lines.
    APPEND `      st.className = "chip warn"; st.lastChild.textContent = token ? "expired" : "none";` TO rt_lines.
    APPEND `      hdr.className = "chip warn"; hdr.lastChild.textContent = token ? "Token expired" : "No token";` TO rt_lines.
    APPEND `      $("tokVal").textContent = "-"; $("tokBar").style.width = "0";` TO rt_lines.
    APPEND `    }` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  setInterval(paintToken, 1000);` TO rt_lines.
    APPEND `  function getToken() {` TO rt_lines.
    APPEND `    setStep("stAuth", "run", "requesting...");` TO rt_lines.
    APPEND `    var body = JSON.stringify({ client_id: $("cid").value.trim(), client_secret: $("csec").value });` TO rt_lines.
    APPEND `    return callJson(withClient(base() + "/auth"), {` TO rt_lines.
    APPEND `      method: "POST", headers: { "Content-Type": "application/json" }, body: body` TO rt_lines.
    APPEND `    }).then(function (r) {` TO rt_lines.
    APPEND `      if (r.status === 200 && r.body && r.body.access_token) {` TO rt_lines.
    APPEND `        var ttl = Number(r.body.expires_in) || 3600;` TO rt_lines.
    APPEND `        token = { value: r.body.access_token, exp: Date.now() + ttl * 1000, ttl: ttl };` TO rt_lines.
    APPEND `        paintToken(); setStep("stAuth", "done", "200 " + DOT + " " + r.ms + " ms");` TO rt_lines.
    APPEND `        return true;` TO rt_lines.
    APPEND `      }` TO rt_lines.
    APPEND `      var code = r.body && r.body.errors && r.body.errors[0] ? r.body.errors[0].code : "";` TO rt_lines.
    APPEND `      setStep("stAuth", "fail", (r.status || "no answer") + (code ? " " + DOT + " " + code : ""));` TO rt_lines.
    APPEND `      showResult({ status: r.status, body: r.body, text: r.text }, { auth: true });` TO rt_lines.
    APPEND `      return false;` TO rt_lines.
    APPEND `    });` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  $("btnAuth").addEventListener("click", function () {` TO rt_lines.
    APPEND `    getToken().then(function (ok) { if (ok) toast("Token issued, valid for " + Math.round(token.ttl / 60) + " minutes"); });` TO rt_lines.
    APPEND `  });` TO rt_lines.
    APPEND `  function setStep(id, state, det) {` TO rt_lines.
    APPEND `    var el = $(id); el.className = "step " + (state || "");` TO rt_lines.
    APPEND `    el.querySelector(".det").textContent = det;` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `  /* ---------- send ---------- */` TO rt_lines.
    APPEND `  var last = null, busy = false, page = 1, nextToken = null;` TO rt_lines.
    APPEND `  function send(opts) {` TO rt_lines.
    APPEND `    opts = opts || {};` TO rt_lines.
    APPEND `    if (busy) return;` TO rt_lines.
    APPEND `    var q0 = checkReq();` TO rt_lines.
    APPEND `    if (!q0) { toast("The request is not valid JSON: " + $("reqMode").textContent); req.focus(); return; }` TO rt_lines.
    APPEND `    var q = applyOverrides(q0);` TO rt_lines.
    APPEND `    if (opts.pageToken) {` TO rt_lines.
    APPEND `      if (typeof q.limit !== "object" || q.limit === null) q.limit = {};` TO rt_lines.
    APPEND `      q.limit.page_token = opts.pageToken;` TO rt_lines.
    APPEND `      page = opts.page;` TO rt_lines.
    APPEND `    } else {` TO rt_lines.
    APPEND `      page = 1;` TO rt_lines.
    APPEND `    }` TO rt_lines.
    APPEND `    var payload = JSON.stringify(q);` TO rt_lines.
    APPEND `    $("sent").value = JSON.stringify(q, null, 2);` TO rt_lines.
    APPEND `    busy = true; $("btnSend").disabled = true;` TO rt_lines.
    APPEND `    setStep("stAuth", "", "-"); setStep("stQry", "", "-"); setStep("stSave", "", "-");` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `    var run;` TO rt_lines.
    APPEND `    if (mode() === "user") {` TO rt_lines.
    APPEND `      setStep("stAuth", "done", CFG.user);` TO rt_lines.
    APPEND `      run = query(window.location.pathname, { "X-DSL-Console": "1" }, payload, q);` TO rt_lines.
    APPEND `    } else {` TO rt_lines.
    APPEND `      var ready = tokenValid() ? Promise.resolve(true)` TO rt_lines.
    APPEND `        : $("autoAuth").checked ? getToken() : Promise.resolve(false);` TO rt_lines.
    APPEND `      run = ready.then(function (ok) {` TO rt_lines.
    APPEND `        if (!ok && !tokenValid()) {` TO rt_lines.
    APPEND `          if (!$("autoAuth").checked) { setStep("stAuth", "fail", "no token"); toast("Get a token first, or turn on automatic tokens."); }` TO rt_lines.
    APPEND `          return null;` TO rt_lines.
    APPEND `        }` TO rt_lines.
    APPEND `        if (tokenValid()) setStep("stAuth", "done", $("stAuth").querySelector(".det").textContent === "-" ? "token reused" : $("stAuth").querySelector(".det").textContent);` TO rt_lines.
    APPEND `        var h = hdrMode() === "a" ? { "Authorization": "Bearer " + token.value } : { "X-DSL-Token": token.value };` TO rt_lines.
    APPEND `        return query(base() + "/query", h, payload, q);` TO rt_lines.
    APPEND `      });` TO rt_lines.
    APPEND `    }` TO rt_lines.
    APPEND `    run.then(function () { busy = false; $("btnSend").disabled = false; },` TO rt_lines.
    APPEND `             function () { busy = false; $("btnSend").disabled = false; });` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  function query(url, headers, payload, q) {` TO rt_lines.
    APPEND `    setStep("stQry", "run", "running...");` TO rt_lines.
    APPEND `    var h = { "Content-Type": "application/json" };` TO rt_lines.
    APPEND `    Object.keys(headers).forEach(function (k) { h[k] = headers[k]; });` TO rt_lines.
    APPEND `    return callJson(withClient(url), { method: "POST", headers: h, body: payload }).then(function (r) {` TO rt_lines.
    APPEND `      var errs = r.body && r.body.errors ? r.body.errors : [];` TO rt_lines.
    APPEND `      var tag = r.status ? String(r.status) : "no answer";` TO rt_lines.
    APPEND `      setStep("stQry", r.status === 200 && !errs.length ? "done" : "fail",` TO rt_lines.
    APPEND `        tag + " " + DOT + " " + r.ms + " ms" + (errs[0] ? " " + DOT + " " + errs[0].code : ""));` TO rt_lines.
    APPEND `      if (r.status === 401 && mode() === "token") token = null;` TO rt_lines.
    APPEND `      last = { status: r.status, body: r.body, text: r.text, sent: q, at: new Date() };` TO rt_lines.
    APPEND `      showResult(r, {});` TO rt_lines.
    APPEND `      if ($("autoSave").checked) save(true); else setStep("stSave", "", "not saved");` TO rt_lines.
    APPEND `    });` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  $("btnSend").addEventListener("click", function () { send(); });` TO rt_lines.
    APPEND `  $("btnNext").addEventListener("click", function () { if (nextToken) send({ pageToken: nextToken, page: page + 1 }); });` TO rt_lines.
    APPEND `  document.addEventListener("keydown", function (e) {` TO rt_lines.
    APPEND `    if ((e.ctrlKey || e.metaKey) && e.key === "Enter") { e.preventDefault(); send(); }` TO rt_lines.
    APPEND `  });` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `  /* ---------- render ---------- */` TO rt_lines.
    APPEND `  function showResult(r, opt) {` TO rt_lines.
    APPEND `    var b = r.body;` TO rt_lines.
    APPEND `    var ok = r.status === 200 && b && !(b.errors || []).length;` TO rt_lines.
    APPEND `    var hs = $("httpStatus");` TO rt_lines.
    APPEND `    hs.className = "status " + (ok ? "ok" : "err");` TO rt_lines.
    APPEND `    hs.textContent = r.status ? "HTTP " + r.status + (ok ? " OK" : "") : "No answer";` TO rt_lines.
    APPEND `    var m = (b && b.meta) || null, d = (b && b.data) || null;` TO rt_lines.
    APPEND `    $("sRows").textContent = m ? m.row_count : "-";` TO rt_lines.
    APPEND `    $("sAgg").textContent = d && d.aggregates && d.aggregates.length ? Number(d.aggregates[0].value).toLocaleString() : "-";` TO rt_lines.
    APPEND `    $("sStrat").textContent = m && m.strategy_used ? m.strategy_used : "-";` TO rt_lines.
    APPEND `    $("sTime").textContent = m ? m.execution_time_ms + " ms" : "-";` TO rt_lines.
    APPEND `    $("sMore").textContent = m ? (m.has_more ? "yes" : "no") + " " + DOT + " page " + page : "-";` TO rt_lines.
    APPEND `    nextToken = m && m.has_more && m.next_page_token ? m.next_page_token : null;` TO rt_lines.
    APPEND `    $("btnNext").disabled = !nextToken;` TO rt_lines.
    APPEND `    $("resp").value = b ? JSON.stringify(b, null, 2) : (r.text || "");` TO rt_lines.
    APPEND `    $("btnCopy").disabled = false; $("btnSave").disabled = opt.auth === true;` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `    var rows = d && d.rows ? d.rows : [];` TO rt_lines.
    APPEND `    $("cRows").textContent = rows.length;` TO rt_lines.
    APPEND `    var rb = $("rowsBox"); rb.innerHTML = "";` TO rt_lines.
    APPEND `    if (!rows.length) {` TO rt_lines.
    APPEND `      rb.innerHTML = '<div class="empty">' + (d && d.aggregates && d.aggregates.length` TO rt_lines.
    APPEND `        ? "No rows. This request returned the count only (output.include_rows = false)." : "No rows returned.") + "</div>";` TO rt_lines.
    APPEND `    } else {` TO rt_lines.
    APPEND `      var cols = Object.keys(rows[0]);` TO rt_lines.
    APPEND `      var html = '<table class="rows"><thead><tr><th>#</th>';` TO rt_lines.
    APPEND `      cols.forEach(function (c) { html += "<th>" + esc(c) + "</th>"; });` TO rt_lines.
    APPEND `      html += "</tr></thead><tbody>";` TO rt_lines.
    APPEND `      rows.forEach(function (row, i) {` TO rt_lines.
    APPEND `        html += '<tr><td class="num">' + (i + 1) + "</td>";` TO rt_lines.
    APPEND `        cols.forEach(function (c) { html += "<td" + (/^-?\d+(\.\d+)?$/.test(row[c]) ? ' class="num"' : "") + ">" + esc(row[c]) + "</td>"; });` TO rt_lines.
    APPEND `        html += "</tr>";` TO rt_lines.
    APPEND `      });` TO rt_lines.
    APPEND `      rb.innerHTML = html + "</tbody></table>";` TO rt_lines.
    APPEND `    }` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `    var msgs = [];` TO rt_lines.
    APPEND `    if (b) {` TO rt_lines.
    APPEND `      (b.errors || []).forEach(function (e) { msgs.push(["err", e]); });` TO rt_lines.
    APPEND `      (b.warnings || []).forEach(function (w) { msgs.push(["warn", w]); });` TO rt_lines.
    APPEND `    } else {` TO rt_lines.
    APPEND `      var why;` TO rt_lines.
    APPEND `      if (!r.status) why = r.text;` TO rt_lines.
    APPEND `      else if (r.status >= 500) why = "SAP stopped with a runtime error (short dump) before it could answer. " +` TO rt_lines.
    APPEND `        "Open ST22, filter on user " + CFG.user + " and today's date, and note the runtime error name and the trigger location.";` TO rt_lines.
    APPEND `      else if (r.status === 401 || r.status === 403 || /logon|login|anmeld/i.test(r.text || ""))` TO rt_lines.
    APPEND `        why = "SAP answered with a logon page. Your session has probably expired: reload this page.";` TO rt_lines.
    APPEND `      else why = "SAP answered with something that is not JSON (HTTP " + r.status + ").";` TO rt_lines.
    APPEND `      msgs.push(["err", { code: r.status ? "HTTP " + r.status : "NO_ANSWER", severity: "ERROR", message: why,` TO rt_lines.
    APPEND `        hint: r.status ? String(r.text || "").replace(/<style[\s\S]*?<\/style>/gi, "").replace(/<[^>]+>/g, " ")` TO rt_lines.
    APPEND `          .replace(/\s+/g, " ").trim().slice(0, 600) : null }]);` TO rt_lines.
    APPEND `    }` TO rt_lines.
    APPEND `    var cm = $("cMsgs"); cm.textContent = msgs.length;` TO rt_lines.
    APPEND `    cm.className = "cnt" + (msgs.some(function (x) { return x[0] === "err"; }) ? " err" : msgs.length ? " warn" : "");` TO rt_lines.
    APPEND `    var mb = $("msgsBox"); mb.innerHTML = "";` TO rt_lines.
    APPEND `    if (!msgs.length) mb.innerHTML = '<div class="empty">No errors or warnings.</div>';` TO rt_lines.
    APPEND `    msgs.forEach(function (x) {` TO rt_lines.
    APPEND `      var e = x[1], div = document.createElement("div");` TO rt_lines.
    APPEND `      div.className = "msg " + x[0];` TO rt_lines.
    APPEND `      div.innerHTML = '<div class="h"><span class="code">' + esc(e.code) + '</span><span class="chip">' +` TO rt_lines.
    APPEND `        esc(e.severity || (x[0] === "err" ? "ERROR" : "WARNING")) + "</span>" +` TO rt_lines.
    APPEND `        (e.table ? '<span class="chip">' + esc(e.table) + "</span>" : "") + "</div>" +` TO rt_lines.
    APPEND `        "<div>" + esc(e.message) + "</div>" + (e.hint ? "<pre>" + esc(e.hint) + "</pre>" : "");` TO rt_lines.
    APPEND `      mb.appendChild(div);` TO rt_lines.
    APPEND `    });` TO rt_lines.
    APPEND `    selectTab(msgs.some(function (x) { return x[0] === "err"; }) ? "msgs" : "raw");` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `    var db = $("dbgBox"); db.innerHTML = "";` TO rt_lines.
    APPEND `    if (!b || !b.debug) {` TO rt_lines.
    APPEND `      db.innerHTML = '<div class="empty">No debug block. Set output.debug to true under Request options to get the generated SQL ' +` TO rt_lines.
    APPEND `        "and an unfiltered row count for every table.</div>";` TO rt_lines.
    APPEND `    } else {` TO rt_lines.
    APPEND `      var sc = b.debug.source_counts || [];` TO rt_lines.
    APPEND `      var max = Math.max.apply(null, [1].concat(sc.map(function (s) { return s.row_count; })));` TO rt_lines.
    APPEND `      var h2 = '<div class="sub">Unfiltered rows per table</div><div class="cnts">';` TO rt_lines.
    APPEND `      sc.forEach(function (s) {` TO rt_lines.
    APPEND `        var w = s.row_count <= 0 ? 0 : Math.max(2, Math.log(s.row_count + 1) / Math.log(max + 1) * 100);` TO rt_lines.
    APPEND `        h2 += '<div class="cnt-row' + (s.row_count === 0 ? " zero" : "") + '"><span class="nm" title="' + esc(s.table) + '">' +` TO rt_lines.
    APPEND `          esc(s.table) + '</span><span class="b"><i style="width:' + w.toFixed(1) + '%"></i></span><span class="v">' +` TO rt_lines.
    APPEND `          (s.row_count < 0 ? "count failed" : Number(s.row_count).toLocaleString()) + "</span></div>";` TO rt_lines.
    APPEND `      });` TO rt_lines.
    APPEND `      h2 += "</div>";` TO rt_lines.
    APPEND `      if (sc.some(function (s) { return s.row_count === 0; })) {` TO rt_lines.
    APPEND `        h2 += '<div class="sub" style="text-transform:none;letter-spacing:0;color:var(--err)">' +` TO rt_lines.
    APPEND `          "A table is empty. The result is empty because the data is missing, not because of the query.</div>";` TO rt_lines.
    APPEND `      }` TO rt_lines.
    APPEND `      h2 += '<div class="sub">Generated SQL ' + DOT + " " + esc(b.debug.strategy) + '</div><pre class="sql">' + esc(b.debug.generated_sql) + "</pre>";` TO rt_lines.
    APPEND `      db.innerHTML = h2;` TO rt_lines.
    APPEND `    }` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  function esc(s) {` TO rt_lines.
    APPEND `    return String(s === undefined || s === null ? "" : s).replace(/[&<>"]/g, function (c) {` TO rt_lines.
    APPEND `      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;" }[c];` TO rt_lines.
    APPEND `    });` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `  /* ---------- tabs ---------- */` TO rt_lines.
    APPEND `  function selectTab(name) {` TO rt_lines.
    APPEND `    document.querySelectorAll(".tabs [role=tab]").forEach(function (t) { t.setAttribute("aria-selected", String(t.dataset.tab === name)); });` TO rt_lines.
    APPEND `    document.querySelectorAll(".tabpanel").forEach(function (p) { p.hidden = p.dataset.panel !== name; });` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  document.querySelectorAll(".tabs [role=tab]").forEach(function (t) {` TO rt_lines.
    APPEND `    t.addEventListener("click", function () { selectTab(t.dataset.tab); });` TO rt_lines.
    APPEND `  });` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `  /* ---------- save ---------- */` TO rt_lines.
    APPEND `  function pad(n) { return String(n).padStart(2, "0"); }` TO rt_lines.
    APPEND `  function fileName() {` TO rt_lines.
    APPEND `    var d = last.at, b = last.body || {};` TO rt_lines.
    APPEND `    var stamp = d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) + "-" + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds());` TO rt_lines.
    APPEND `    var status = b.errors && b.errors.length ? b.errors[0].code : last.status === 200 ? "OK" : "HTTP" + last.status;` TO rt_lines.
    APPEND `    var name = $("fname").value` TO rt_lines.
    APPEND `      .split("{query_id}").join(b.query_id || last.sent.query_id || "query")` TO rt_lines.
    APPEND `      .split("{metricId}").join(b.metricId || last.sent.metricId || "")` TO rt_lines.
    APPEND `      .split("{status}").join(status)` TO rt_lines.
    APPEND `      .split("{page}").join("p" + page)` TO rt_lines.
    APPEND `      .split("{yyyyMMdd-HHmmss}").join(stamp);` TO rt_lines.
    APPEND `    name = name.replace(/[^\w.\-]+/g, "_");` TO rt_lines.
    APPEND `    return /\.json$/i.test(name) ? name : name + ".json";` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  function fileContent() {` TO rt_lines.
    APPEND `    var resp = last.body !== null ? last.body : last.text;` TO rt_lines.
    APPEND `    if (!$("saveReq").checked) return JSON.stringify(resp, null, 2);` TO rt_lines.
    APPEND `    return JSON.stringify({ saved_at: last.at.toISOString(), http_status: last.status, request: last.sent, response: resp }, null, 2);` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  function download(name, content) {` TO rt_lines.
    APPEND `    var url = URL.createObjectURL(new Blob([content], { type: "application/json" }));` TO rt_lines.
    APPEND `    var a = document.createElement("a");` TO rt_lines.
    APPEND `    a.href = url; a.download = name; document.body.appendChild(a); a.click();` TO rt_lines.
    APPEND `    setTimeout(function () { URL.revokeObjectURL(url); a.remove(); }, 1000);` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  function save(auto) {` TO rt_lines.
    APPEND `    if (!last) return;` TO rt_lines.
    APPEND `    var name = fileName(), content = fileContent();` TO rt_lines.
    APPEND `    var done = function (finalName) {` TO rt_lines.
    APPEND `      setStep("stSave", "done", finalName);` TO rt_lines.
    APPEND `      $("saveInfo").innerHTML = "Saved as <span class=\"mono\">" + esc(finalName) + "</span>" + ($("saveReq").checked ? " (with request)" : "");` TO rt_lines.
    APPEND `      addHist(finalName);` TO rt_lines.
    APPEND `      toast((auto ? "Saved " : "Saved ") + finalName);` TO rt_lines.
    APPEND `    };` TO rt_lines.
    APPEND `    if (!auto && $("askWhere").checked && window.showSaveFilePicker) {` TO rt_lines.
    APPEND `      window.showSaveFilePicker({ suggestedName: name, types: [{ description: "JSON", accept: { "application/json": [".json"] } }] })` TO rt_lines.
    APPEND `        .then(function (h) {` TO rt_lines.
    APPEND `          return h.createWritable().then(function (w) { return w.write(content).then(function () { return w.close(); }); })` TO rt_lines.
    APPEND `            .then(function () { done(h.name); });` TO rt_lines.
    APPEND `        })` TO rt_lines.
    APPEND `        .catch(function (e) { if (!e || e.name !== "AbortError") { download(name, content); done(name); } });` TO rt_lines.
    APPEND `      return;` TO rt_lines.
    APPEND `    }` TO rt_lines.
    APPEND `    download(name, content); done(name);` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `  $("btnSave").addEventListener("click", function () { save(false); });` TO rt_lines.
    APPEND `  $("btnCopy").addEventListener("click", function () {` TO rt_lines.
    APPEND `    var text = $("resp").value;` TO rt_lines.
    APPEND `    if (navigator.clipboard && window.isSecureContext) {` TO rt_lines.
    APPEND `      navigator.clipboard.writeText(text).then(function () { toast("Response copied"); },` TO rt_lines.
    APPEND `        function () { selectTab("raw"); $("resp").select(); toast("Press Ctrl+C to copy the selected response"); });` TO rt_lines.
    APPEND `    } else { selectTab("raw"); $("resp").select(); toast("Press Ctrl+C to copy the selected response"); }` TO rt_lines.
    APPEND `  });` TO rt_lines.
    APPEND `  function addHist(name) {` TO rt_lines.
    APPEND `    var b = last.body || {}, ok = last.status === 200 && !(b.errors || []).length;` TO rt_lines.
    APPEND `    var li = document.createElement("li");` TO rt_lines.
    APPEND `    li.innerHTML = '<span class="t">' + pad(last.at.getHours()) + ":" + pad(last.at.getMinutes()) + ":" + pad(last.at.getSeconds()) +` TO rt_lines.
    APPEND `      '</span><span class="q">' + esc(b.query_id || last.sent.query_id || "-") + '</span><span class="chip ' + (ok ? "ok" : "err") +` TO rt_lines.
    APPEND `      '"><span class="dot"></span>' + esc(ok ? last.status : (b.errors && b.errors[0] ? b.errors[0].code : "HTTP " + last.status)) +` TO rt_lines.
    APPEND `      '</span><span class="f">' + esc(name) + "</span>";` TO rt_lines.
    APPEND `    $("hist").insertBefore(li, $("hist").firstChild);` TO rt_lines.
    APPEND `    $("histEmpty").hidden = true;` TO rt_lines.
    APPEND `    $("histCount").textContent = $("hist").children.length;` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `  /* ---------- toast ---------- */` TO rt_lines.
    APPEND `  var tt;` TO rt_lines.
    APPEND `  function toast(msg) {` TO rt_lines.
    APPEND `    var t = $("toast"); t.textContent = msg; t.hidden = false;` TO rt_lines.
    APPEND `    clearTimeout(tt); tt = setTimeout(function () { t.hidden = true; }, 4000);` TO rt_lines.
    APPEND `  }` TO rt_lines.
    APPEND `` TO rt_lines.
    APPEND `  /* ---------- start ---------- */` TO rt_lines.
    APPEND `  if (saved.draft) { req.value = saved.draft; checkReq(); } else setReq(PRESETS.single);` TO rt_lines.
    APPEND `  refreshApplied();` TO rt_lines.
    APPEND `  paintMode();` TO rt_lines.
    APPEND `})();` TO rt_lines.
    APPEND `</script>` TO rt_lines.
    APPEND `</body>` TO rt_lines.
    APPEND `</html>` TO rt_lines.
    " <<< END GENERATED
  endmethod.
ENDCLASS.
