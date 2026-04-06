class ZCL_HTTP_DSL_HANDLER definition
  public
  final
  create public .

  public section.

    interfaces IF_HTTP_EXTENSION .

  private section.

    methods VALIDATE_TOKEN
      importing
        !IV_TOKEN type STRING
      exporting
        !EV_VALID type ABAP_BOOL
        !EV_SVC_USER type SYUNAME
        !EV_CLIENT_ID type STRING .

    methods SERIALIZE_RESPONSE
      importing
        !IS_RESPONSE type ZIF_JSON_DSL_TYPES=>TY_RESPONSE
      returning
        value(RV_JSON) type STRING .

    methods SERIALIZE_ERRORS
      importing
        !IT_ERRORS type ZTT_DSL_ERROR
      returning
        value(RV_JSON) type STRING .

    methods SERIALIZE_ROWS
      importing
        !IT_ROWS type ZIF_JSON_DSL_TYPES=>TY_RESULT_ROWS
      returning
        value(RV_JSON) type STRING .

    methods SEND_JSON_RESPONSE
      importing
        !IO_SERVER type ref to IF_HTTP_SERVER
        !IV_STATUS type I
        !IV_JSON type STRING .

    methods GET_HTTP_STATUS
      importing
        !IT_ERRORS type ZTT_DSL_ERROR
      returning
        value(RV_STATUS) type I .

    methods ESCAPE_JSON_STRING
      importing
        !IV_VALUE type STRING
      returning
        value(RV_ESCAPED) type STRING .
ENDCLASS.



CLASS ZCL_HTTP_DSL_HANDLER IMPLEMENTATION.


  method IF_HTTP_EXTENSION~HANDLE_REQUEST.
    DATA(lv_method) = server->request->get_header_field( name = '~request_method' ).

    " GET returns the expected JSON template (schema help)
    IF lv_method = 'GET'.
      send_json_response(
        io_server = server
        iv_status = 200
        iv_json   = '{"message":"SAP JSON DSL Engine v1.5 — POST your query here",' &&
                    '"template":' && zcl_json_dsl_engine=>get_template( ) && '}' ).
      RETURN.
    ENDIF.

    " Only accept POST for queries
    IF lv_method <> 'POST'.
      send_json_response(
        io_server = server
        iv_status = 405
        iv_json   = '{"errors":[{"code":"HTTP_405","message":"Method not allowed - use POST or GET for schema"}]}' ).
      RETURN.
    ENDIF.

    " Extract bearer token
    " SAP ICF consumes the standard Authorization header, so we
    " support both X-DSL-Token (preferred) and Authorization as fallback
    DATA lv_token TYPE string.
    lv_token = server->request->get_header_field( name = 'X-DSL-Token' ).
    IF lv_token IS INITIAL.
      lv_token = server->request->get_header_field( name = 'x-dsl-token' ).
    ENDIF.
    IF lv_token IS INITIAL.
      " Fallback: try Authorization header (works if ICF anonymous logon is configured)
      DATA(lv_auth) = server->request->get_header_field( name = 'authorization' ).
      IF lv_auth CP 'Bearer *' OR lv_auth CP 'bearer *'.
        lv_token = lv_auth+7.
      ENDIF.
    ENDIF.

    DATA lv_valid    TYPE abap_bool.
    DATA lv_svc_user TYPE syuname.
    DATA lv_client_id TYPE string.

    IF lv_token IS INITIAL.
      send_json_response(
        io_server = server
        iv_status = 401
        iv_json   = '{"errors":[{"code":"DSL_AUTH_004","message":"Missing bearer token"}]}' ).
      RETURN.
    ENDIF.

    validate_token(
      EXPORTING iv_token = lv_token
      IMPORTING ev_valid = lv_valid ev_svc_user = lv_svc_user ev_client_id = lv_client_id ).

    IF lv_valid = abap_false.
      send_json_response(
        io_server = server
        iv_status = 401
        iv_json   = '{"errors":[{"code":"DSL_AUTH_005","message":"Invalid or expired token"}]}' ).
      RETURN.
    ENDIF.

    " Read request body (DSL JSON payload)
    DATA(lv_body) = server->request->get_cdata( ).

    " Strip BOM and non-printable leading characters
    WHILE strlen( lv_body ) > 0 AND lv_body+0(1) <> '{'.
      lv_body = lv_body+1.
    ENDWHILE.

    IF lv_body IS INITIAL.
      send_json_response(
        io_server = server
        iv_status = 400
        iv_json   = '{"errors":[{"code":"DSL_PARSE_001","message":"Empty request body"}]}' ).
      RETURN.
    ENDIF.

    " Execute via the engine facade
    DATA(lo_engine) = NEW zcl_json_dsl_engine( ).
    DATA(ls_response) = lo_engine->execute(
      iv_json   = lv_body
      iv_caller = lv_svc_user ).

    " Determine HTTP status from errors
    DATA(lv_status) = 200.
    IF ls_response-errors IS NOT INITIAL.
      lv_status = get_http_status( ls_response-errors ).
    ENDIF.

    " Serialize and send response
    DATA(lv_resp_json) = serialize_response( ls_response ).
    send_json_response(
      io_server = server
      iv_status = lv_status
      iv_json   = lv_resp_json ).
  endmethod.


  method VALIDATE_TOKEN.
    ev_valid = abap_false.
    CLEAR: ev_svc_user, ev_client_id.

    DATA lv_xstr TYPE xstring.
    DATA lv_json TYPE string.

    TRY.
        CALL FUNCTION 'SCMS_BASE64_DECODE_STR'
          EXPORTING
            input  = iv_token
          IMPORTING
            output = lv_xstr.
        lv_json = cl_abap_codepage=>convert_from( lv_xstr ).

        DATA(lo_parser) = NEW zcl_json_dsl_parser( ).
        DATA(lv_cid) = lo_parser->json_extract_member( iv_json = lv_json iv_key = 'client_id' ).
        DATA(lv_usr) = lo_parser->json_extract_member( iv_json = lv_json iv_key = 'svc_user' ).
        DATA(lv_issued_str) = lo_parser->json_extract_member( iv_json = lv_json iv_key = 'issued_at' ).
        DATA(lv_ttl_str) = lo_parser->json_extract_member( iv_json = lv_json iv_key = 'ttl' ).
        " Strip quotes from JSON string values
        REPLACE ALL OCCURRENCES OF '"' IN lv_cid WITH ''.
        REPLACE ALL OCCURRENCES OF '"' IN lv_usr WITH ''.
        ev_client_id = lv_cid.
        ev_svc_user  = lv_usr.

        " Check expiry
        DATA lv_issued TYPE timestamp.
        DATA lv_now    TYPE timestamp.
        lv_issued = lv_issued_str.
        GET TIME STAMP FIELD lv_now.

        DATA(lv_ttl) = CONV i( lv_ttl_str ).
        DATA lv_elapsed TYPE i.
        lv_elapsed = cl_abap_tstmp=>subtract(
          tstmp1 = lv_now
          tstmp2 = lv_issued ).

        IF lv_elapsed <= lv_ttl AND ev_client_id IS NOT INITIAL.
          ev_valid = abap_true.
        ENDIF.
      CATCH cx_root.
        ev_valid = abap_false.
    ENDTRY.
  endmethod.


  method SERIALIZE_RESPONSE.
    " Build JSON response manually for full control
    rv_json = '{"query_id":"' && escape_json_string( is_response-query_id ) && '"'.

    " Metadata — pass through if present
    IF is_response-metric_name IS NOT INITIAL.
      rv_json = rv_json && ',"metricName":"' && escape_json_string( is_response-metric_name ) && '"'.
    ENDIF.
    IF is_response-metric_id IS NOT INITIAL.
      rv_json = rv_json && ',"metricId":"' && escape_json_string( is_response-metric_id ) && '"'.
    ENDIF.
    IF is_response-priority IS NOT INITIAL.
      rv_json = rv_json && ',"priority":"' && escape_json_string( is_response-priority ) && '"'.
    ENDIF.
    IF is_response-module IS NOT INITIAL.
      rv_json = rv_json && ',"module":"' && escape_json_string( is_response-module ) && '"'.
    ENDIF.

    " Data section
    rv_json = rv_json && ',"data":{"rows":'.
    rv_json = rv_json && serialize_rows( is_response-rows ).

    " Aggregates
    rv_json = rv_json && ',"aggregates":['.
    DATA lv_first TYPE abap_bool VALUE abap_true.
    LOOP AT is_response-aggregates INTO DATA(ls_agg).
      IF lv_first = abap_false. rv_json = rv_json && ','. ENDIF.
      rv_json = rv_json && '{"alias":"' && escape_json_string( ls_agg-alias )
             && '","type":"' && escape_json_string( ls_agg-type )
             && '","value":' && ls_agg-value && '}'.
      lv_first = abap_false.
    ENDLOOP.
    rv_json = rv_json && ']}'.

    " Meta
    rv_json = rv_json && ',"meta":{'.
    rv_json = rv_json && '"row_count":' && is_response-meta-row_count.
    rv_json = rv_json && ',"total_count":' && is_response-meta-total_count.
    IF is_response-meta-has_more = abap_true.
      rv_json = rv_json && ',"has_more":true'.
    ELSE.
      rv_json = rv_json && ',"has_more":false'.
    ENDIF.
    IF is_response-meta-next_page_token IS NOT INITIAL.
      rv_json = rv_json && ',"next_page_token":"'
             && escape_json_string( is_response-meta-next_page_token ) && '"'.
    ELSE.
      rv_json = rv_json && ',"next_page_token":null'.
    ENDIF.
    rv_json = rv_json && ',"execution_time_ms":' && is_response-meta-execution_time_ms.
    rv_json = rv_json && ',"strategy_used":"' && is_response-meta-strategy_used && '"'.
    IF is_response-meta-count_distinct_fallback = abap_true.
      rv_json = rv_json && ',"count_distinct_fallback":true'.
    ELSE.
      rv_json = rv_json && ',"count_distinct_fallback":false'.
    ENDIF.
    IF is_response-meta-entity_resolved IS NOT INITIAL.
      rv_json = rv_json && ',"entity_resolved":"'
             && escape_json_string( is_response-meta-entity_resolved ) && '"'.
    ELSE.
      rv_json = rv_json && ',"entity_resolved":null'.
    ENDIF.
    rv_json = rv_json && '}'.

    " Warnings
    rv_json = rv_json && ',"warnings":' && serialize_errors( is_response-warnings ).

    " Errors
    rv_json = rv_json && ',"errors":' && serialize_errors( is_response-errors ).

    rv_json = rv_json && '}'.
  endmethod.


  method SERIALIZE_ROWS.
    rv_json = '['.
    DATA lv_first_row TYPE abap_bool.
    DATA lv_first_fld TYPE abap_bool.
    lv_first_row = abap_true.

    LOOP AT it_rows INTO DATA(lt_nv).
      IF lv_first_row = abap_false. rv_json = rv_json && ','. ENDIF.
      rv_json = rv_json && '{'.

      lv_first_fld = abap_true.
      LOOP AT lt_nv INTO DATA(ls_nv).
        IF lv_first_fld = abap_false. rv_json = rv_json && ','. ENDIF.
        rv_json = rv_json && '"' && escape_json_string( ls_nv-name )
               && '":"' && escape_json_string( ls_nv-value ) && '"'.
        lv_first_fld = abap_false.
      ENDLOOP.

      rv_json = rv_json && '}'.
      lv_first_row = abap_false.
    ENDLOOP.

    rv_json = rv_json && ']'.
  endmethod.


  method SERIALIZE_ERRORS.
    rv_json = '['.
    DATA lv_first TYPE abap_bool VALUE abap_true.

    LOOP AT it_errors INTO DATA(ls_err).
      IF lv_first = abap_false. rv_json = rv_json && ','. ENDIF.
      rv_json = rv_json && '{"code":"' && escape_json_string( CONV string( ls_err-code ) )
             && '","severity":"' && escape_json_string( CONV string( ls_err-severity ) )
             && '","message":"' && escape_json_string( CONV string( ls_err-message ) ) && '"'.
      IF ls_err-field IS NOT INITIAL.
        rv_json = rv_json && ',"field":"' && escape_json_string( CONV string( ls_err-field ) ) && '"'.
      ELSE.
        rv_json = rv_json && ',"field":null'.
      ENDIF.
      IF ls_err-tabname IS NOT INITIAL.
        rv_json = rv_json && ',"table":"' && escape_json_string( CONV string( ls_err-tabname ) ) && '"'.
      ELSE.
        rv_json = rv_json && ',"table":null'.
      ENDIF.
      IF ls_err-hint IS NOT INITIAL.
        rv_json = rv_json && ',"hint":"' && escape_json_string( CONV string( ls_err-hint ) ) && '"'.
      ELSE.
        rv_json = rv_json && ',"hint":null'.
      ENDIF.
      rv_json = rv_json && '}'.
      lv_first = abap_false.
    ENDLOOP.

    rv_json = rv_json && ']'.
  endmethod.


  method GET_HTTP_STATUS.
    " Map first error code to HTTP status (§20.4)
    READ TABLE it_errors INDEX 1 INTO DATA(ls_err).
    IF sy-subrc <> 0.
      rv_status = 200.
      RETURN.
    ENDIF.

    DATA(lv_code) = ls_err-code.
    IF lv_code CP 'DSL_PARSE*' OR lv_code CP 'DSL_SEM*'.
      rv_status = 400.
    ELSEIF lv_code CP 'DSL_WL_ROLE*'.
      rv_status = 403.
    ELSEIF lv_code CP 'DSL_GUARD_001'.
      rv_status = 429.
    ELSEIF lv_code CP 'DSL_EXEC_002'.
      rv_status = 504.
    ELSEIF lv_code CP 'DSL_EXEC*'.
      rv_status = 500.
    ELSEIF lv_code CP 'DSL_SEC*'.
      rv_status = 400.
    ELSE.
      rv_status = 500.
    ENDIF.
  endmethod.


  method ESCAPE_JSON_STRING.
    rv_escaped = iv_value.
    REPLACE ALL OCCURRENCES OF '\' IN rv_escaped WITH '\\'.
    REPLACE ALL OCCURRENCES OF '"' IN rv_escaped WITH '\"'.
    REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>newline IN rv_escaped WITH '\n'.
    REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>horizontal_tab IN rv_escaped WITH '\t'.
  endmethod.


  method SEND_JSON_RESPONSE.
    io_server->response->set_status( code = iv_status reason = '' ).
    io_server->response->set_header_field(
      name  = 'Content-Type'
      value = 'application/json' ).
    io_server->response->set_cdata( data = iv_json ).
  endmethod.
ENDCLASS.
