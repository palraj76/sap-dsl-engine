class ZCL_JSON_DSL_VALIDATOR definition
  public
  final
  create public .

  public section.

    methods VALIDATE
      importing
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY
        !IV_CALLER type SYUNAME default SY-UNAME
      returning
        value(RT_ERRORS) type ZTT_DSL_ERROR
      raising
        ZCX_DSL_SECURITY .

  private section.

    data MT_ERRORS type ZTT_DSL_ERROR .

    methods ADD_ERROR
      importing
        !IV_CODE type ZDSL_DE_ECODE
        !IV_SEVERITY type ZDSL_DE_SEVER default 'ERROR'
        !IV_MESSAGE type STRING
        !IV_FIELD type STRING optional
        !IV_TABLE type STRING optional
        !IV_HINT type STRING optional .

    methods VALIDATE_WHITELIST
      importing
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY
        !IV_CALLER type SYUNAME .

    methods VALIDATE_SEMANTIC
      importing
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY .

    methods VALIDATE_INJECTION
      importing
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY
      raising
        ZCX_DSL_SECURITY .

    methods VALIDATE_GUARDRAILS
      importing
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY .

    methods CHECK_FIELD_QUALIFIED
      importing
        !IV_FIELD type STRING
        !IV_CONTEXT type STRING .

    methods CHECK_FIELD_PATTERN
      importing
        !IV_VALUE type STRING
        !IV_CONTEXT type STRING
      raising
        ZCX_DSL_SECURITY .

    methods GET_CONFIG_VALUE
      importing
        !IV_KEY type STRING
      returning
        value(RV_VALUE) type STRING .

    methods RESOLVE_ALIAS_TO_TABLE
      importing
        !IV_ALIAS type STRING
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY
      returning
        value(RV_TABLE) type STRING .
ENDCLASS.



CLASS ZCL_JSON_DSL_VALIDATOR IMPLEMENTATION.


  method VALIDATE.
    CLEAR mt_errors.

    " Phase B — Whitelist
    validate_whitelist( is_query = is_query iv_caller = iv_caller ).

    " Phase B — Semantic
    validate_semantic( is_query ).

    " Phase B — Guardrails
    validate_guardrails( is_query ).

    " Phase C — Injection defense (raises ZCX_DSL_SECURITY)
    validate_injection( is_query ).

    " Merge any parser warnings
    APPEND LINES OF is_query-warnings TO mt_errors.

    rt_errors = mt_errors.
  endmethod.


  method ADD_ERROR.
    APPEND VALUE zst_dsl_error(
      code     = iv_code
      severity = iv_severity
      message  = iv_message
      field    = iv_field
      tabname  = iv_table
      hint     = iv_hint
    ) TO mt_errors.
  endmethod.


  method VALIDATE_WHITELIST.
    DATA lv_table TYPE string.
    DATA lv_field TYPE string.

    " Check WHITELIST_MODE config
    DATA(lv_mode) = get_config_value( 'WHITELIST_MODE' ).
    IF lv_mode IS INITIAL. lv_mode = 'STRICT'. ENDIF.

    " In OPEN mode, skip whitelist checks entirely
    IF lv_mode = 'OPEN'.
      RETURN.
    ENDIF.

    " STRICT mode — full whitelist enforcement

    " Collect all table references
    DATA lt_tables TYPE string_table.
    LOOP AT is_query-sources INTO DATA(ls_src).
      APPEND ls_src-table TO lt_tables.
    ENDLOOP.
    LOOP AT is_query-joins INTO DATA(ls_join).
      APPEND ls_join-target_table TO lt_tables.
    ENDLOOP.

    " Check each table is whitelisted
    LOOP AT lt_tables INTO lv_table.
      SELECT COUNT(*) FROM zjson_dsl_wl
        WHERE table_name = lv_table.
      IF sy-dbcnt = 0.
        add_error(
          iv_code    = 'DSL_WL_TABLE_001'
          iv_message = |Table { lv_table } not in whitelist|
          iv_table   = lv_table ).
      ENDIF.
    ENDLOOP.

    " Check each selected field is whitelisted (supports wildcard *)
    LOOP AT is_query-select_fields INTO DATA(ls_sel).
      IF ls_sel-field IS NOT INITIAL AND ls_sel-field CS '.'.
        SPLIT ls_sel-field AT '.' INTO DATA(lv_alias) lv_field.
        DATA(lv_tab) = resolve_alias_to_table(
          iv_alias  = lv_alias
          is_query  = is_query ).
        IF lv_tab IS NOT INITIAL.
          " Check for wildcard entry first
          SELECT COUNT(*) FROM zjson_dsl_wl
            WHERE table_name = lv_tab
              AND field_name = '*'.
          IF sy-dbcnt > 0.
            CONTINUE. " Wildcard — all fields allowed
          ENDIF.
          " Check specific field
          SELECT COUNT(*) FROM zjson_dsl_wl
            WHERE table_name = lv_tab
              AND field_name = lv_field.
          IF sy-dbcnt = 0.
            add_error(
              iv_code    = 'DSL_WL_FIELD_002'
              iv_message = |Field { lv_field } not allowed for table { lv_tab }|
              iv_field   = ls_sel-field
              iv_table   = lv_tab ).
          ENDIF.
        ENDIF.
      ENDIF.
    ENDLOOP.
  endmethod.


  method VALIDATE_SEMANTIC.
    " DSL_SEM_003: Non-aggregate select fields must be in group_by when metrics present
    IF is_query-metrics IS NOT INITIAL.
      LOOP AT is_query-select_fields INTO DATA(ls_sel).
        DATA(lv_fld) = ls_sel-field.
        IF lv_fld IS NOT INITIAL.
          READ TABLE is_query-group_by WITH KEY table_line = lv_fld
            TRANSPORTING NO FIELDS.
          IF sy-subrc <> 0.
            add_error(
              iv_code    = 'DSL_SEM_003'
              iv_message = |Non-aggregate select field { lv_fld } missing from GROUP BY|
              iv_field   = lv_fld ).
          ENDIF.
        ENDIF.
      ENDLOOP.
    ENDIF.

    " DSL_SEM_002: having without group_by
    IF is_query-having IS NOT INITIAL AND is_query-group_by IS INITIAL.
      add_error(
        iv_code    = 'DSL_SEM_002'
        iv_message = 'HAVING present without GROUP BY' ).
    ENDIF.

    " DSL_SEM_001: having alias must exist in metrics
    LOOP AT is_query-having INTO DATA(ls_hav).
      READ TABLE is_query-metrics WITH KEY alias = ls_hav-metric
        TRANSPORTING NO FIELDS.
      IF sy-subrc <> 0.
        add_error(
          iv_code    = 'DSL_SEM_001'
          iv_message = |HAVING alias { ls_hav-metric } not found in metrics|
          iv_field   = ls_hav-metric ).
      ENDIF.
    ENDLOOP.

    " DSL_SEM_004: param references must have values
    LOOP AT is_query-filter_nodes INTO DATA(ls_node)
      WHERE param IS NOT INITIAL.
      READ TABLE is_query-params WITH KEY key = ls_node-param
        TRANSPORTING NO FIELDS.
      IF sy-subrc <> 0.
        add_error(
          iv_code    = 'DSL_SEM_004'
          iv_message = |Param key { ls_node-param } not supplied in params block|
          iv_field   = ls_node-param ).
      ENDIF.
    ENDLOOP.

    " DSL_SEM_005: duplicate aliases
    DATA lt_aliases TYPE string_table.
    LOOP AT is_query-select_fields INTO DATA(ls_s).
      IF ls_s-alias IS NOT INITIAL.
        READ TABLE lt_aliases WITH KEY table_line = ls_s-alias
          TRANSPORTING NO FIELDS.
        IF sy-subrc = 0.
          add_error(
            iv_code    = 'DSL_SEM_005'
            iv_message = |Duplicate alias: { ls_s-alias }|
            iv_field   = ls_s-alias ).
        ENDIF.
        APPEND ls_s-alias TO lt_aliases.
      ENDIF.
    ENDLOOP.
    LOOP AT is_query-metrics INTO DATA(ls_m).
      READ TABLE lt_aliases WITH KEY table_line = ls_m-alias
        TRANSPORTING NO FIELDS.
      IF sy-subrc = 0.
        add_error(
          iv_code    = 'DSL_SEM_005'
          iv_message = |Duplicate alias: { ls_m-alias }|
          iv_field   = ls_m-alias ).
      ENDIF.
      APPEND ls_m-alias TO lt_aliases.
    ENDLOOP.

    " DSL_SEM_009: pagination requires order_by
    IF ( is_query-limit-offset > 0 OR is_query-limit-page_token IS NOT INITIAL )
       AND is_query-order_by IS INITIAL.
      add_error(
        iv_code    = 'DSL_SEM_009'
        iv_message = 'Pagination active but ORDER BY is absent' ).
    ENDIF.

    " DSL_SEM_010: IS NULL / IS NOT NULL must not carry value or param
    LOOP AT is_query-filter_nodes INTO DATA(ls_fn)
      WHERE op = 'IS NULL' OR op = 'IS NOT NULL'.
      IF ls_fn-value IS NOT INITIAL OR ls_fn-param IS NOT INITIAL.
        add_error(
          iv_code    = 'DSL_SEM_010'
          iv_message = 'IS NULL/IS NOT NULL must not carry value or param'
          iv_field   = ls_fn-field ).
      ENDIF.
    ENDLOOP.

    " DSL_SEM_011: field qualification check
    LOOP AT is_query-select_fields INTO DATA(ls_sf).
      IF ls_sf-field IS NOT INITIAL.
        check_field_qualified( iv_field = ls_sf-field iv_context = 'select' ).
      ENDIF.
    ENDLOOP.
    LOOP AT is_query-group_by INTO DATA(lv_gb).
      check_field_qualified( iv_field = lv_gb iv_context = 'group_by' ).
    ENDLOOP.
    LOOP AT is_query-filter_nodes INTO DATA(ls_fn2)
      WHERE node_type = 'L' AND field IS NOT INITIAL.
      check_field_qualified( iv_field = ls_fn2-field iv_context = 'filters' ).
    ENDLOOP.

    " DSL_SEM_007: MANDT check on joins
    LOOP AT is_query-joins INTO DATA(ls_j).
      DATA lv_has_mandt TYPE abap_bool VALUE abap_false.
      LOOP AT ls_j-on_nodes INTO DATA(ls_on)
        WHERE node_type = 'L'.
        IF ls_on-left_field CS 'MANDT' OR ls_on-right_field CS 'MANDT'.
          lv_has_mandt = abap_true.
          EXIT.
        ENDIF.
      ENDLOOP.
      IF lv_has_mandt = abap_false.
        add_error(
          iv_code    = 'DSL_SEM_007'
          iv_message = |JOIN on { ls_j-target_table } missing MANDT condition|
          iv_table   = ls_j-target_table ).
      ENDIF.
    ENDLOOP.
  endmethod.


  method VALIDATE_INJECTION.
    DATA(lv_field_pattern) = '^[A-Za-z][A-Za-z0-9_]*\.[A-Za-z][A-Za-z0-9_]*$'.
    DATA(lv_alias_pattern) = '^[A-Za-z][A-Za-z0-9_]*$'.

    " Check all field references
    LOOP AT is_query-select_fields INTO DATA(ls_sel).
      IF ls_sel-field IS NOT INITIAL.
        check_field_pattern( iv_value = ls_sel-field iv_context = 'select.field' ).
      ENDIF.
      IF ls_sel-alias IS NOT INITIAL.
        FIND REGEX lv_alias_pattern IN ls_sel-alias.
        IF sy-subrc <> 0.
          RAISE EXCEPTION TYPE zcx_dsl_security
            EXPORTING textid        = zcx_dsl_security=>gc_invalid_chars
                      mv_error_code = 'DSL_SEC_002'
                      mv_attr1      = ls_sel-alias.
        ENDIF.
      ENDIF.
    ENDLOOP.

    " Check metric aliases
    LOOP AT is_query-metrics INTO DATA(ls_met).
      FIND REGEX lv_alias_pattern IN ls_met-alias.
      IF sy-subrc <> 0.
        RAISE EXCEPTION TYPE zcx_dsl_security
          EXPORTING textid        = zcx_dsl_security=>gc_invalid_chars
                    mv_error_code = 'DSL_SEC_002'
                    mv_attr1      = ls_met-alias.
      ENDIF.
    ENDLOOP.

    " Check operators against allowed set
    DATA(lt_allowed_ops) = VALUE string_table(
      ( `=` ) ( `!=` ) ( `>` ) ( `<` ) ( `>=` ) ( `<=` )
      ( `IN` ) ( `NOT IN` ) ( `IS NULL` ) ( `IS NOT NULL` ) ( `BETWEEN` )
    ).
    LOOP AT is_query-filter_nodes INTO DATA(ls_fn)
      WHERE node_type = 'L' AND op IS NOT INITIAL.
      READ TABLE lt_allowed_ops WITH KEY table_line = ls_fn-op
        TRANSPORTING NO FIELDS.
      IF sy-subrc <> 0.
        RAISE EXCEPTION TYPE zcx_dsl_security
          EXPORTING textid        = zcx_dsl_security=>gc_invalid_operator
                    mv_error_code = 'DSL_SEC_003'
                    mv_attr1      = ls_fn-op.
      ENDIF.
    ENDLOOP.

    " Check string value length (DSL_SEC_004)
    LOOP AT is_query-filter_nodes INTO DATA(ls_fn2)
      WHERE node_type = 'L'.
      IF strlen( ls_fn2-value ) > 500.
        RAISE EXCEPTION TYPE zcx_dsl_security
          EXPORTING textid        = zcx_dsl_security=>gc_value_too_long
                    mv_error_code = 'DSL_SEC_004'.
      ENDIF.
      LOOP AT ls_fn2-values INTO DATA(lv_v).
        IF strlen( lv_v ) > 500.
          RAISE EXCEPTION TYPE zcx_dsl_security
            EXPORTING textid        = zcx_dsl_security=>gc_value_too_long
                      mv_error_code = 'DSL_SEC_004'.
        ENDIF.
      ENDLOOP.
    ENDLOOP.
  endmethod.


  method VALIDATE_GUARDRAILS.
    " DSL_GUARD_001: max rows
    DATA(lv_max_rows) = get_config_value( 'MAX_ROWS_ALLOWED' ).
    IF lv_max_rows IS NOT INITIAL AND is_query-limit-rows > 0.
      DATA(lv_max) = CONV i( lv_max_rows ).
      IF is_query-limit-rows > lv_max.
        add_error(
          iv_code    = 'DSL_GUARD_001'
          iv_message = |Requested rows ({ is_query-limit-rows }) exceeds system maximum ({ lv_max })|
          iv_hint    = 'Reduce limit.rows or use pagination' ).
      ENDIF.
    ENDIF.

    " DSL_GUARD_002: warning threshold
    DATA(lv_warn_rows) = get_config_value( 'WARN_ROWS_THRESHOLD' ).
    IF lv_warn_rows IS NOT INITIAL AND is_query-limit-rows > 0.
      DATA(lv_warn) = CONV i( lv_warn_rows ).
      IF is_query-limit-rows > lv_warn.
        add_error(
          iv_code    = 'DSL_GUARD_002'
          iv_severity = 'WARNING'
          iv_message = |Result set likely large - rows { is_query-limit-rows } exceeds threshold { lv_warn }| ).
      ENDIF.
    ENDIF.

    " DSL_GUARD_003: join count warning
    DATA(lv_warn_joins) = get_config_value( 'WARN_JOINS_THRESHOLD' ).
    IF lv_warn_joins IS NOT INITIAL.
      DATA(lv_jmax) = CONV i( lv_warn_joins ).
      DATA(lv_jcnt) = lines( is_query-joins ).
      IF lv_jcnt > lv_jmax.
        add_error(
          iv_code    = 'DSL_GUARD_003'
          iv_severity = 'WARNING'
          iv_message = |Query has { lv_jcnt } joins - exceeds threshold { lv_jmax }| ).
      ENDIF.
    ENDIF.
  endmethod.


  method CHECK_FIELD_QUALIFIED.
    IF iv_field IS INITIAL. RETURN. ENDIF.
    IF iv_field NS '.'.
      add_error(
        iv_code    = 'DSL_SEM_011'
        iv_message = |Field { iv_field } not qualified as alias.FIELDNAME|
        iv_field   = iv_field ).
    ENDIF.
  endmethod.


  method CHECK_FIELD_PATTERN.
    DATA(lv_pattern) = '^[A-Za-z][A-Za-z0-9_]*\.[A-Za-z][A-Za-z0-9_]*$'.
    FIND REGEX lv_pattern IN iv_value.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE zcx_dsl_security
        EXPORTING textid        = zcx_dsl_security=>gc_invalid_chars
                  mv_error_code = 'DSL_SEC_002'
                  mv_attr1      = iv_value.
    ENDIF.
  endmethod.


  method GET_CONFIG_VALUE.
    SELECT SINGLE config_value INTO rv_value
      FROM zjson_dsl_config
      WHERE config_key = iv_key.
  endmethod.


  method RESOLVE_ALIAS_TO_TABLE.
    " Find the table name for a given alias
    READ TABLE is_query-sources INTO DATA(ls_src)
      WITH KEY alias = iv_alias.
    IF sy-subrc = 0.
      rv_table = ls_src-table.
      RETURN.
    ENDIF.

    LOOP AT is_query-joins INTO DATA(ls_join).
      IF ls_join-target_alias = iv_alias.
        rv_table = ls_join-target_table.
        RETURN.
      ENDIF.
    ENDLOOP.
  endmethod.
ENDCLASS.
