class ZCL_JSON_DSL_EXECUTOR definition
  public
  final
  create public .

  public section.

    methods EXECUTE
      importing
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY
        !IS_SQL type ZCL_JSON_DSL_BUILDER=>TY_SQL_RESULT
        !IV_CALLER type SYUNAME default SY-UNAME
      returning
        value(RS_RESPONSE) type ZIF_JSON_DSL_TYPES=>TY_RESPONSE
      raising
        ZCX_DSL_PARSE .

  private section.

    methods EXECUTE_OPEN_SQL
      importing
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY
        !IS_SQL type ZCL_JSON_DSL_BUILDER=>TY_SQL_RESULT
      exporting
        !ET_ROWS type ZIF_JSON_DSL_TYPES=>TY_RESULT_ROWS
        !EV_DBCNT type I
      raising
        ZCX_DSL_PARSE .

    methods BUILD_DYNAMIC_SELECT
      importing
        !IS_SQL type ZCL_JSON_DSL_BUILDER=>TY_SQL_RESULT
      returning
        value(RV_SQL) type STRING .

    methods RESULT_TO_NV_ROWS
      importing
        !IR_TABLE type REF TO DATA
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY
      returning
        value(RT_ROWS) type ZIF_JSON_DSL_TYPES=>TY_RESULT_ROWS .

    methods APPLY_PAGINATION
      importing
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY
      changing
        !CT_ROWS type ZIF_JSON_DSL_TYPES=>TY_RESULT_ROWS
        !CS_META type ZIF_JSON_DSL_TYPES=>TY_META .

    methods BUILD_PAGE_TOKEN
      importing
        !IV_OFFSET type I
      returning
        value(RV_TOKEN) type STRING .

    methods DECODE_PAGE_TOKEN
      importing
        !IV_TOKEN type STRING
      returning
        value(RV_OFFSET) type I .

    methods WRITE_AUDIT_LOG
      importing
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY
        !IS_SQL type ZCL_JSON_DSL_BUILDER=>TY_SQL_RESULT
        !IS_RESPONSE type ZIF_JSON_DSL_TYPES=>TY_RESPONSE
        !IV_CALLER type SYUNAME
        !IV_EXEC_MS type I .

    methods GET_TIMESTAMP
      returning
        value(RV_TS) type TIMESTAMP .
ENDCLASS.



CLASS ZCL_JSON_DSL_EXECUTOR IMPLEMENTATION.


  method EXECUTE.
    DATA lv_start TYPE i.
    DATA lv_end   TYPE i.
    DATA lt_rows  TYPE zif_json_dsl_types=>ty_result_rows.
    DATA lv_dbcnt TYPE i.

    rs_response-query_id = is_query-query_id.

    " Capture start time
    GET RUN TIME FIELD lv_start.

    TRY.
        CASE is_sql-strategy.
          WHEN 'OPEN_SQL'.
            execute_open_sql(
              EXPORTING is_query = is_query is_sql = is_sql
              IMPORTING et_rows = lt_rows ev_dbcnt = lv_dbcnt ).
          WHEN OTHERS.
            " NATIVE_SQL and AMDP — fallback to Open SQL for now
            execute_open_sql(
              EXPORTING is_query = is_query is_sql = is_sql
              IMPORTING et_rows = lt_rows ev_dbcnt = lv_dbcnt ).
        ENDCASE.

      CATCH cx_sy_dynamic_osql_error INTO DATA(lx_sql).
        APPEND VALUE zst_dsl_error(
          code     = 'DSL_EXEC_001'
          severity = 'ERROR'
          message  = lx_sql->get_text( )
        ) TO rs_response-errors.
        RETURN.

      CATCH cx_root INTO DATA(lx_any).
        APPEND VALUE zst_dsl_error(
          code     = 'DSL_EXEC_001'
          severity = 'ERROR'
          message  = lx_any->get_text( )
        ) TO rs_response-errors.
        RETURN.
    ENDTRY.

    GET RUN TIME FIELD lv_end.
    DATA(lv_exec_ms) = ( lv_end - lv_start ) / 1000.

    " Build meta
    rs_response-meta-execution_time_ms = lv_exec_ms.
    rs_response-meta-strategy_used     = is_sql-strategy.
    rs_response-meta-row_count         = lines( lt_rows ).

    IF is_query-entity IS NOT INITIAL.
      rs_response-meta-entity_resolved = is_query-entity.
    ENDIF.

    " COUNT DISTINCT fallback detection
    IF sy-saprl < '740'.
      LOOP AT is_query-metrics TRANSPORTING NO FIELDS
        WHERE type = 'count_distinct'.
        rs_response-meta-count_distinct_fallback = abap_true.
        EXIT.
      ENDLOOP.
    ENDIF.

    " Apply pagination
    rs_response-rows = lt_rows.
    apply_pagination(
      EXPORTING is_query = is_query
      CHANGING ct_rows = rs_response-rows
               cs_meta = rs_response-meta ).

    " Include summary total if requested
    IF is_query-output-include_summary = abap_true.
      rs_response-meta-total_count = lv_dbcnt.
    ENDIF.

    " Write audit log for Flex Mode
    write_audit_log(
      is_query    = is_query
      is_sql      = is_sql
      is_response = rs_response
      iv_caller   = iv_caller
      iv_exec_ms  = lv_exec_ms ).
  endmethod.


  method EXECUTE_OPEN_SQL.
    DATA lr_table TYPE REF TO data.
    DATA lr_line  TYPE REF TO data.

    TRY.
        " ── Build dynamic result structure via RTTI ──
        DATA lt_components TYPE cl_abap_structdescr=>component_table.
        DATA ls_comp       LIKE LINE OF lt_components.

        " One string component per select field alias
        LOOP AT is_query-select_fields INTO DATA(ls_fld).
          CLEAR ls_comp.
          IF ls_fld-alias IS NOT INITIAL.
            ls_comp-name = to_upper( ls_fld-alias ).
          ELSE.
            ls_comp-name = to_upper( ls_fld-field ).
            REPLACE ALL OCCURRENCES OF '.' IN ls_comp-name WITH '_'.
          ENDIF.
          ls_comp-type = cl_abap_elemdescr=>get_string( ).
          APPEND ls_comp TO lt_components.
        ENDLOOP.

        " One string component per metric alias
        LOOP AT is_query-metrics INTO DATA(ls_met).
          CLEAR ls_comp.
          ls_comp-name = to_upper( ls_met-alias ).
          ls_comp-type = cl_abap_elemdescr=>get_string( ).
          APPEND ls_comp TO lt_components.
        ENDLOOP.

        " Create dynamic structure and table types
        DATA(lo_struct_type) = cl_abap_structdescr=>create( lt_components ).
        DATA(lo_table_type)  = cl_abap_tabledescr=>create( lo_struct_type ).

        CREATE DATA lr_table TYPE HANDLE lo_table_type.
        FIELD-SYMBOLS: <lt_result> TYPE STANDARD TABLE.
        ASSIGN lr_table->* TO <lt_result>.

        " ── Build SQL clauses ──
        DATA(lv_from) = is_sql-from_clause.
        IF is_sql-join_clause IS NOT INITIAL.
          lv_from = lv_from && ` ` && is_sql-join_clause.
        ENDIF.

        DATA(lv_fields) = is_sql-select_clause.
        DATA(lv_where)  = is_sql-where_clause.
        DATA(lv_group)  = is_sql-group_by_clause.
        DATA(lv_having) = is_sql-having_clause.
        DATA(lv_order)  = is_sql-order_by_clause.
        DATA(lv_limit)  = is_sql-row_limit.

        " ── Dynamic Open SQL execution ──
        IF lv_group IS NOT INITIAL AND lv_having IS NOT INITIAL.
          SELECT (lv_fields) FROM (lv_from)
            WHERE (lv_where)
            GROUP BY (lv_group)
            HAVING (lv_having)
            ORDER BY (lv_order)
            INTO TABLE <lt_result>
            UP TO lv_limit ROWS.
        ELSEIF lv_group IS NOT INITIAL.
          SELECT (lv_fields) FROM (lv_from)
            WHERE (lv_where)
            GROUP BY (lv_group)
            ORDER BY (lv_order)
            INTO TABLE <lt_result>
            UP TO lv_limit ROWS.
        ELSEIF lv_where IS NOT INITIAL.
          SELECT (lv_fields) FROM (lv_from)
            WHERE (lv_where)
            ORDER BY (lv_order)
            INTO TABLE <lt_result>
            UP TO lv_limit ROWS.
        ELSE.
          SELECT (lv_fields) FROM (lv_from)
            ORDER BY (lv_order)
            INTO TABLE <lt_result>
            UP TO lv_limit ROWS.
        ENDIF.

        ev_dbcnt = sy-dbcnt.

        " ── Convert results to name-value pair rows ──
        et_rows = result_to_nv_rows(
          ir_table = lr_table
          is_query = is_query ).

      CATCH cx_sy_dynamic_osql_error INTO DATA(lx_err).
        RAISE EXCEPTION TYPE zcx_dsl_parse
          EXPORTING textid        = zcx_dsl_parse=>gc_malformed_json
                    mv_error_code = 'DSL_EXEC_001'
                    mv_attr1      = lx_err->get_text( ).
    ENDTRY.
  endmethod.


  method BUILD_DYNAMIC_SELECT.
    " Assemble full SQL for logging/audit (not for execution — that uses dynamic clauses)
    rv_sql = |SELECT { is_sql-select_clause }|.
    rv_sql = rv_sql && | FROM { is_sql-from_clause }|.
    IF is_sql-join_clause IS NOT INITIAL.
      rv_sql = rv_sql && | { is_sql-join_clause }|.
    ENDIF.
    IF is_sql-where_clause IS NOT INITIAL.
      rv_sql = rv_sql && | WHERE { is_sql-where_clause }|.
    ENDIF.
    IF is_sql-group_by_clause IS NOT INITIAL.
      rv_sql = rv_sql && | GROUP BY { is_sql-group_by_clause }|.
    ENDIF.
    IF is_sql-having_clause IS NOT INITIAL.
      rv_sql = rv_sql && | HAVING { is_sql-having_clause }|.
    ENDIF.
    IF is_sql-order_by_clause IS NOT INITIAL.
      rv_sql = rv_sql && | ORDER BY { is_sql-order_by_clause }|.
    ENDIF.
    IF is_sql-row_limit > 0.
      rv_sql = rv_sql && | UP TO { is_sql-row_limit } ROWS|.
    ENDIF.
  endmethod.


  method RESULT_TO_NV_ROWS.
    " Convert a dynamic result table to name-value pair rows
    " The field names come from the query's select aliases and metric aliases
    FIELD-SYMBOLS: <lt_table> TYPE ANY TABLE.
    ASSIGN ir_table->* TO <lt_table>.
    IF sy-subrc <> 0. RETURN. ENDIF.

    " Build field name list from select + metrics
    DATA lt_names TYPE string_table.
    LOOP AT is_query-select_fields INTO DATA(ls_fld).
      IF ls_fld-alias IS NOT INITIAL.
        APPEND ls_fld-alias TO lt_names.
      ELSE.
        APPEND ls_fld-field TO lt_names.
      ENDIF.
    ENDLOOP.
    LOOP AT is_query-metrics INTO DATA(ls_met).
      APPEND ls_met-alias TO lt_names.
    ENDLOOP.

    " Iterate result rows
    DATA lv_idx TYPE i.
    LOOP AT <lt_table> ASSIGNING FIELD-SYMBOL(<ls_row>).
      DATA lt_nv TYPE zif_json_dsl_types=>ty_nv_pairs.
      CLEAR lt_nv.

      lv_idx = 1.
      LOOP AT lt_names INTO DATA(lv_name).
        DATA lv_val TYPE string.
        ASSIGN COMPONENT lv_idx OF STRUCTURE <ls_row> TO FIELD-SYMBOL(<lv_fld>).
        IF sy-subrc = 0.
          lv_val = <lv_fld>.
        ELSE.
          CLEAR lv_val.
        ENDIF.
        APPEND VALUE zif_json_dsl_types=>ty_nv_pair(
          name = lv_name value = lv_val
        ) TO lt_nv.
        lv_idx = lv_idx + 1.
      ENDLOOP.

      APPEND lt_nv TO rt_rows.
    ENDLOOP.
  endmethod.


  method APPLY_PAGINATION.
    DATA(lv_offset) = is_query-limit-offset.

    " Decode page token if present
    IF is_query-limit-page_token IS NOT INITIAL.
      lv_offset = decode_page_token( is_query-limit-page_token ).
    ENDIF.

    DATA(lv_page_size) = is_query-limit-page_size.
    IF lv_page_size <= 0.
      lv_page_size = is_query-limit-rows.
    ENDIF.
    IF lv_page_size <= 0.
      " No pagination — return all rows
      cs_meta-has_more = abap_false.
      RETURN.
    ENDIF.

    " Client-side offset: delete rows before offset
    IF lv_offset > 0 AND lv_offset < lines( ct_rows ).
      DELETE ct_rows FROM 1 TO lv_offset.
    ELSEIF lv_offset >= lines( ct_rows ).
      CLEAR ct_rows.
      cs_meta-has_more = abap_false.
      RETURN.
    ENDIF.

    " Trim to page_size
    IF lines( ct_rows ) > lv_page_size.
      cs_meta-has_more = abap_true.
      DATA(lv_new_offset) = lv_offset + lv_page_size.
      cs_meta-next_page_token = build_page_token( lv_new_offset ).
      DELETE ct_rows FROM ( lv_page_size + 1 ).
    ELSE.
      cs_meta-has_more = abap_false.
    ENDIF.

    cs_meta-row_count = lines( ct_rows ).
  endmethod.


  method BUILD_PAGE_TOKEN.
    " Simple base64-encoded offset: {"offset":50}
    DATA(lv_json) = |{ '\{' }"offset":{ iv_offset }{ '\}' }|.
    " Encode to base64
    DATA lv_xstr TYPE xstring.
    lv_xstr = cl_abap_codepage=>convert_to( lv_json ).
    CALL FUNCTION 'SCMS_BASE64_ENCODE_STR'
      EXPORTING
        input  = lv_xstr
      IMPORTING
        output = rv_token.
  endmethod.


  method DECODE_PAGE_TOKEN.
    DATA lv_xstr TYPE xstring.
    DATA lv_json TYPE string.

    TRY.
        CALL FUNCTION 'SCMS_BASE64_DECODE_STR'
          EXPORTING
            input  = iv_token
          IMPORTING
            output = lv_xstr.
        lv_json = cl_abap_codepage=>convert_from( lv_xstr ).

        " Extract offset value from {"offset":50}
        DATA(lo_parser) = NEW zcl_json_dsl_parser( ).
        DATA(lv_offset_json) = lo_parser->json_extract_member(
          iv_json = lv_json iv_key = 'offset' ).
        IF lv_offset_json IS NOT INITIAL.
          rv_offset = lv_offset_json.
        ENDIF.
      CATCH cx_root.
        rv_offset = 0.
    ENDTRY.
  endmethod.


  method WRITE_AUDIT_LOG.
    " Only write audit for Flex Mode or security events
    " For now: log all executions to ZJSON_DSL_AUDIT
    DATA ls_audit TYPE zjson_dsl_audit.

    TRY.
        ls_audit-mandt          = sy-mandt.
        ls_audit-audit_id       = cl_system_uuid=>create_uuid_c32_static( ).
        ls_audit-exec_timestamp = get_timestamp( ).
        ls_audit-caller_user    = iv_caller.
        ls_audit-query_id       = is_query-query_id.
        ls_audit-sql_generated  = build_dynamic_select( is_sql ).
        ls_audit-strategy_used  = is_sql-strategy.
        ls_audit-row_count      = is_response-meta-row_count.
        ls_audit-exec_time_ms   = iv_exec_ms.

        IF is_response-errors IS NOT INITIAL.
          ls_audit-status     = 'E'.
          READ TABLE is_response-errors INDEX 1 INTO DATA(ls_err).
          IF sy-subrc = 0.
            ls_audit-error_code = ls_err-code.
          ENDIF.
        ELSE.
          ls_audit-status = 'S'.
        ENDIF.

        INSERT zjson_dsl_audit FROM ls_audit.
        COMMIT WORK.
      CATCH cx_root.
        " Audit write failure must not break the query
    ENDTRY.
  endmethod.


  method GET_TIMESTAMP.
    GET TIME STAMP FIELD rv_ts.
  endmethod.
ENDCLASS.
