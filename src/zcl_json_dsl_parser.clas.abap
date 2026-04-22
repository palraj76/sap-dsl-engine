class ZCL_JSON_DSL_PARSER definition
  public
  final
  create public .

  public section.

    methods PARSE
      importing
        !IV_JSON type STRING
      returning
        value(RS_QUERY) type ZIF_JSON_DSL_TYPES=>TY_QUERY
      raising
        ZCX_DSL_PARSE .

    " Exposed for entity resolver reuse
    methods JSON_EXTRACT_MEMBER
      importing
        !IV_JSON type STRING
        !IV_KEY type STRING
      returning
        value(RV_JSON) type STRING .

    methods PARSE_SOURCES
      importing
        !IV_JSON type STRING
      returning
        value(RT_SOURCES) type ZIF_JSON_DSL_TYPES=>TY_SOURCES
      raising
        ZCX_DSL_PARSE .

    methods PARSE_JOINS
      importing
        !IV_JSON type STRING
      returning
        value(RT_JOINS) type ZIF_JSON_DSL_TYPES=>TY_JOINS
      raising
        ZCX_DSL_PARSE .

    methods PARSE_SELECT
      importing
        !IV_JSON type STRING
      returning
        value(RT_SELECT) type ZIF_JSON_DSL_TYPES=>TY_SELECT_FIELDS .

    methods JSON_EXTRACT_STRING
      importing
        !IV_JSON type STRING
      returning
        value(RV_VALUE) type STRING .

  private section.

    data MV_NEXT_NODE_ID type I value 1 ##NO_TEXT.

    " ─── JSON low-level navigation ───
    methods SKIP_WS
      importing
        !IV_JSON type STRING
      changing
        !CV_POS type I .

    methods READ_STRING
      importing
        !IV_JSON type STRING
      exporting
        !EV_VALUE type STRING
      changing
        !CV_POS type I .

    methods SKIP_VALUE
      importing
        !IV_JSON type STRING
      changing
        !CV_POS type I .

    methods SKIP_BALANCED
      importing
        !IV_JSON type STRING
        !IV_OPEN type C
        !IV_CLOSE type C
      changing
        !CV_POS type I .

    methods READ_VALUE
      importing
        !IV_JSON type STRING
      exporting
        !EV_VALUE type STRING
      changing
        !CV_POS type I .

    " ─── JSON high-level helpers ───
    methods JSON_SPLIT_ARRAY
      importing
        !IV_JSON type STRING
      returning
        value(RT_ELEMENTS) type STRING_TABLE .

    methods JSON_EXTRACT_INTEGER
      importing
        !IV_JSON type STRING
      returning
        value(RV_VALUE) type I .

    methods JSON_EXTRACT_BOOLEAN
      importing
        !IV_JSON type STRING
      returning
        value(RV_VALUE) type ABAP_BOOL .

    methods JSON_IS_OBJECT
      importing
        !IV_JSON type STRING
      returning
        value(RV_IS) type ABAP_BOOL .

    methods JSON_IS_ARRAY
      importing
        !IV_JSON type STRING
      returning
        value(RV_IS) type ABAP_BOOL .

    methods JSON_IS_NULL
      importing
        !IV_JSON type STRING
      returning
        value(RV_IS) type ABAP_BOOL .

    methods JSON_GET_KEYS
      importing
        !IV_JSON type STRING
      returning
        value(RT_KEYS) type STRING_TABLE .

    " ─── Section parsers (private) ───
    methods PARSE_CONDITION_TREE
      importing
        !IV_JSON type STRING
        !IV_PARENT_ID type I default 0
      changing
        !CT_NODES type ZIF_JSON_DSL_TYPES=>TY_COND_NODES
      raising
        ZCX_DSL_PARSE .

    methods PARSE_CONDITION_LEAF
      importing
        !IV_JSON type STRING
        !IV_PARENT_ID type I
      changing
        !CT_NODES type ZIF_JSON_DSL_TYPES=>TY_COND_NODES .

    methods PARSE_GROUP_BY
      importing
        !IV_JSON type STRING
      returning
        value(RT_GROUP_BY) type STRING_TABLE .

    methods PARSE_METRICS
      importing
        !IV_JSON type STRING
      returning
        value(RT_METRICS) type ZIF_JSON_DSL_TYPES=>TY_METRICS .

    methods PARSE_HAVING
      importing
        !IV_JSON type STRING
      returning
        value(RT_HAVING) type ZIF_JSON_DSL_TYPES=>TY_HAVINGS .

    methods PARSE_ORDER_BY
      importing
        !IV_JSON type STRING
      returning
        value(RT_ORDER_BY) type ZIF_JSON_DSL_TYPES=>TY_ORDER_BYS .

    methods PARSE_LIMIT
      importing
        !IV_JSON type STRING
      returning
        value(RS_LIMIT) type ZIF_JSON_DSL_TYPES=>TY_LIMIT .

    methods PARSE_PARAMS
      importing
        !IV_JSON type STRING
      returning
        value(RT_PARAMS) type ZIF_JSON_DSL_TYPES=>TY_PARAMS .

    methods PARSE_OUTPUT
      importing
        !IV_JSON type STRING
      returning
        value(RS_OUTPUT) type ZIF_JSON_DSL_TYPES=>TY_OUTPUT .
ENDCLASS.



CLASS ZCL_JSON_DSL_PARSER IMPLEMENTATION.


  method PARSE.
    DATA lv_wrapped TYPE string.

    mv_next_node_id = 1.

    " 1. Basic JSON check
    DATA(lv_json) = iv_json.
    SHIFT lv_json LEFT DELETING LEADING ` `.
    IF strlen( lv_json ) < 2 OR lv_json+0(1) <> '{'.
      RAISE EXCEPTION TYPE zcx_dsl_parse
        EXPORTING textid        = zcx_dsl_parse=>gc_malformed_json
                  mv_error_code = 'DSL_PARSE_001'
                  mv_attr1      = 'Expected JSON object'.
    ENDIF.

    " 2. Version check
    DATA(lv_version_json) = json_extract_member( iv_json = lv_json iv_key = 'version' ).
    IF lv_version_json IS INITIAL.
      RAISE EXCEPTION TYPE zcx_dsl_parse
        EXPORTING textid        = zcx_dsl_parse=>gc_missing_field
                  mv_error_code = 'DSL_PARSE_003'
                  mv_attr1      = 'version'.
    ENDIF.
    DATA(lv_version) = json_extract_string( lv_version_json ).
    IF lv_version <> '1.2' AND lv_version <> '1.3'.
      RAISE EXCEPTION TYPE zcx_dsl_parse
        EXPORTING textid        = zcx_dsl_parse=>gc_unsupported_version
                  mv_error_code = 'DSL_PARSE_002'
                  mv_attr1      = lv_version.
    ENDIF.
    rs_query-version = lv_version.

    " 3. Unknown top-level keys
    DATA(lt_allowed) = VALUE string_table(
      ( `version` ) ( `query_id` ) ( `entity` ) ( `sources` ) ( `joins` )
      ( `select` ) ( `filters` ) ( `group_by` ) ( `metrics` ) ( `having` )
      ( `order_by` ) ( `limit` ) ( `params` ) ( `output` )
      " Metadata fields — passed through for tracing/logging
      ( `metricName` ) ( `metricId` ) ( `priority` ) ( `description` ) ( `module` )
    ).
    DATA(lt_keys) = json_get_keys( lv_json ).
    LOOP AT lt_keys INTO DATA(lv_key).
      IF lv_key IS INITIAL. CONTINUE. ENDIF.
      READ TABLE lt_allowed WITH KEY table_line = lv_key TRANSPORTING NO FIELDS.
      IF sy-subrc <> 0.
        RAISE EXCEPTION TYPE zcx_dsl_parse
          EXPORTING textid        = zcx_dsl_parse=>gc_unknown_key
                    mv_error_code = 'DSL_PARSE_004'
                    mv_attr1      = lv_key.
      ENDIF.
    ENDLOOP.

    " 4. query_id and metadata
    DATA(lv_qid_json) = json_extract_member( iv_json = lv_json iv_key = 'query_id' ).
    IF lv_qid_json IS NOT INITIAL.
      rs_query-query_id = json_extract_string( lv_qid_json ).
    ENDIF.

    " Metadata — pass through for tracing
    DATA(lv_mn) = json_extract_member( iv_json = lv_json iv_key = 'metricName' ).
    IF lv_mn IS NOT INITIAL. rs_query-metric_name = json_extract_string( lv_mn ). ENDIF.
    DATA(lv_mi) = json_extract_member( iv_json = lv_json iv_key = 'metricId' ).
    IF lv_mi IS NOT INITIAL. rs_query-metric_id = json_extract_string( lv_mi ). ENDIF.
    DATA(lv_pr) = json_extract_member( iv_json = lv_json iv_key = 'priority' ).
    IF lv_pr IS NOT INITIAL. rs_query-priority = json_extract_string( lv_pr ). ENDIF.
    DATA(lv_ds) = json_extract_member( iv_json = lv_json iv_key = 'description' ).
    IF lv_ds IS NOT INITIAL. rs_query-description = json_extract_string( lv_ds ). ENDIF.
    DATA(lv_mo) = json_extract_member( iv_json = lv_json iv_key = 'module' ).
    IF lv_mo IS NOT INITIAL. rs_query-module = json_extract_string( lv_mo ). ENDIF.

    " Use metricId as query_id if query_id not provided
    IF rs_query-query_id IS INITIAL AND rs_query-metric_id IS NOT INITIAL.
      rs_query-query_id = rs_query-metric_id.
    ENDIF.

    " 5. Entity vs sources mutual exclusivity
    DATA(lv_entity_json) = json_extract_member( iv_json = lv_json iv_key = 'entity' ).
    DATA(lv_sources_json) = json_extract_member( iv_json = lv_json iv_key = 'sources' ).
    DATA(lv_joins_json) = json_extract_member( iv_json = lv_json iv_key = 'joins' ).

    IF lv_entity_json IS NOT INITIAL AND NOT json_is_null( lv_entity_json )
       AND ( lv_sources_json IS NOT INITIAL OR lv_joins_json IS NOT INITIAL ).
      RAISE EXCEPTION TYPE zcx_dsl_parse
        EXPORTING textid        = zcx_dsl_parse=>gc_entity_sources_conflict
                  mv_error_code = 'DSL_PARSE_005'.
    ENDIF.

    " 6. Entity
    IF lv_entity_json IS NOT INITIAL AND NOT json_is_null( lv_entity_json ).
      rs_query-entity = json_extract_string( lv_entity_json ).
    ENDIF.

    " 7. Sources
    IF lv_sources_json IS NOT INITIAL.
      rs_query-sources = parse_sources( lv_sources_json ).
    ENDIF.

    " 8. Joins
    IF lv_joins_json IS NOT INITIAL.
      rs_query-joins = parse_joins( lv_joins_json ).
    ENDIF.

    " 9. Select (mandatory)
    DATA(lv_select_json) = json_extract_member( iv_json = lv_json iv_key = 'select' ).
    IF lv_select_json IS INITIAL OR json_is_null( lv_select_json ).
      RAISE EXCEPTION TYPE zcx_dsl_parse
        EXPORTING textid        = zcx_dsl_parse=>gc_missing_field
                  mv_error_code = 'DSL_PARSE_003'
                  mv_attr1      = 'select'.
    ENDIF.
    rs_query-select_fields = parse_select( lv_select_json ).

    " 10. Filters
    DATA(lv_filters_json) = json_extract_member( iv_json = lv_json iv_key = 'filters' ).
    IF lv_filters_json IS NOT INITIAL AND NOT json_is_null( lv_filters_json ).
      IF json_is_array( lv_filters_json ).
        APPEND VALUE zst_dsl_error(
          code     = 'DSL_DEPR_001'
          severity = 'WARNING'
          message  = 'Flat filter array deprecated - use condition tree'
        ) TO rs_query-warnings.
        lv_wrapped = `{"logic":"AND","conditions":` && lv_filters_json && `}`.
        parse_condition_tree(
          EXPORTING iv_json = lv_wrapped iv_parent_id = 0
          CHANGING ct_nodes = rs_query-filter_nodes ).
      ELSE.
        parse_condition_tree(
          EXPORTING iv_json = lv_filters_json iv_parent_id = 0
          CHANGING ct_nodes = rs_query-filter_nodes ).
      ENDIF.
    ENDIF.

    " 11. Group by
    DATA(lv_gb_json) = json_extract_member( iv_json = lv_json iv_key = 'group_by' ).
    IF lv_gb_json IS NOT INITIAL.
      rs_query-group_by = parse_group_by( lv_gb_json ).
    ENDIF.

    " 12. Metrics
    DATA(lv_met_json) = json_extract_member( iv_json = lv_json iv_key = 'metrics' ).
    IF lv_met_json IS NOT INITIAL.
      rs_query-metrics = parse_metrics( lv_met_json ).
    ENDIF.

    " 13. Having
    DATA(lv_hav_json) = json_extract_member( iv_json = lv_json iv_key = 'having' ).
    IF lv_hav_json IS NOT INITIAL.
      rs_query-having = parse_having( lv_hav_json ).
    ENDIF.

    " 14. Order by
    DATA(lv_ob_json) = json_extract_member( iv_json = lv_json iv_key = 'order_by' ).
    IF lv_ob_json IS NOT INITIAL.
      rs_query-order_by = parse_order_by( lv_ob_json ).
    ENDIF.

    " 15. Limit
    DATA(lv_lim_json) = json_extract_member( iv_json = lv_json iv_key = 'limit' ).
    IF lv_lim_json IS NOT INITIAL.
      rs_query-limit = parse_limit( lv_lim_json ).
    ENDIF.

    " 16. Params
    DATA(lv_par_json) = json_extract_member( iv_json = lv_json iv_key = 'params' ).
    IF lv_par_json IS NOT INITIAL.
      rs_query-params = parse_params( lv_par_json ).
    ENDIF.

    " 17. Output
    DATA(lv_out_json) = json_extract_member( iv_json = lv_json iv_key = 'output' ).
    IF lv_out_json IS NOT INITIAL.
      rs_query-output = parse_output( lv_out_json ).
    ELSE.
      rs_query-output-include_rows       = abap_true.
      rs_query-output-include_aggregates = abap_true.
      rs_query-output-include_summary    = abap_false.
    ENDIF.

    " 18. Must have entity OR sources
    IF rs_query-entity IS INITIAL AND rs_query-sources IS INITIAL.
      RAISE EXCEPTION TYPE zcx_dsl_parse
        EXPORTING textid        = zcx_dsl_parse=>gc_missing_field
                  mv_error_code = 'DSL_PARSE_003'
                  mv_attr1      = 'entity or sources'.
    ENDIF.
  endmethod.


  method SKIP_WS.
    DATA lv_code TYPE i.
    DATA lv_char TYPE c LENGTH 1.
    DATA(lv_len) = strlen( iv_json ).
    WHILE cv_pos < lv_len.
      lv_char = iv_json+cv_pos(1).
      lv_code = cl_abap_conv_out_ce=>uccp( lv_char ).
      " 32=space, 9=tab, 10=LF, 13=CR
      IF lv_code = 32 OR lv_code = 9 OR lv_code = 10 OR lv_code = 13.
        cv_pos = cv_pos + 1.
      ELSE.
        EXIT.
      ENDIF.
    ENDWHILE.
  endmethod.


  method READ_STRING.
    DATA lv_ch TYPE c LENGTH 1.
    DATA(lv_len) = strlen( iv_json ).
    CLEAR ev_value.

    IF cv_pos >= lv_len OR iv_json+cv_pos(1) <> '"'.
      RETURN.
    ENDIF.
    cv_pos = cv_pos + 1.

    DATA(lv_start) = cv_pos.
    WHILE cv_pos < lv_len.
      lv_ch = iv_json+cv_pos(1).
      IF lv_ch = '\'.
        cv_pos = cv_pos + 2.
        CONTINUE.
      ENDIF.
      IF lv_ch = '"'.
        DATA(lv_slen) = cv_pos - lv_start.
        IF lv_slen > 0.
          ev_value = iv_json+lv_start(lv_slen).
        ENDIF.
        cv_pos = cv_pos + 1.
        REPLACE ALL OCCURRENCES OF '\"' IN ev_value WITH '"'.
        REPLACE ALL OCCURRENCES OF '\\' IN ev_value WITH '\'.
        REPLACE ALL OCCURRENCES OF '\/' IN ev_value WITH '/'.
        RETURN.
      ENDIF.
      cv_pos = cv_pos + 1.
    ENDWHILE.
  endmethod.


  method SKIP_BALANCED.
    DATA lv_ch TYPE c LENGTH 1.
    DATA lv_depth TYPE i VALUE 0.
    DATA lv_in_str TYPE abap_bool VALUE abap_false.
    DATA(lv_len) = strlen( iv_json ).

    WHILE cv_pos < lv_len.
      lv_ch = iv_json+cv_pos(1).

      IF lv_in_str = abap_true.
        IF lv_ch = '\'.
          cv_pos = cv_pos + 2.
          CONTINUE.
        ENDIF.
        IF lv_ch = '"'.
          lv_in_str = abap_false.
        ENDIF.
      ELSE.
        IF lv_ch = '"'.
          lv_in_str = abap_true.
        ELSEIF lv_ch = iv_open.
          lv_depth = lv_depth + 1.
        ELSEIF lv_ch = iv_close.
          lv_depth = lv_depth - 1.
          IF lv_depth = 0.
            cv_pos = cv_pos + 1.
            RETURN.
          ENDIF.
        ENDIF.
      ENDIF.

      cv_pos = cv_pos + 1.
    ENDWHILE.
  endmethod.


  method SKIP_VALUE.
    DATA(lv_len) = strlen( iv_json ).
    IF cv_pos >= lv_len. RETURN. ENDIF.

    DATA(lv_ch) = iv_json+cv_pos(1).
    CASE lv_ch.
      WHEN '"'.
        DATA lv_dummy TYPE string.
        read_string( EXPORTING iv_json = iv_json IMPORTING ev_value = lv_dummy CHANGING cv_pos = cv_pos ).
      WHEN '{'.
        skip_balanced( EXPORTING iv_json = iv_json iv_open = '{' iv_close = '}' CHANGING cv_pos = cv_pos ).
      WHEN '['.
        skip_balanced( EXPORTING iv_json = iv_json iv_open = '[' iv_close = ']' CHANGING cv_pos = cv_pos ).
      WHEN OTHERS.
        " Number, boolean, null — stop at delimiter or whitespace
        WHILE cv_pos < lv_len.
          DATA lv_c TYPE c LENGTH 1.
          DATA lv_cc TYPE i.
          lv_c = iv_json+cv_pos(1).
          IF lv_c = ',' OR lv_c = '}' OR lv_c = ']'.
            EXIT.
          ENDIF.
          lv_cc = cl_abap_conv_out_ce=>uccp( lv_c ).
          IF lv_cc = 32 OR lv_cc = 9 OR lv_cc = 10 OR lv_cc = 13.
            EXIT.
          ENDIF.
          cv_pos = cv_pos + 1.
        ENDWHILE.
    ENDCASE.
  endmethod.


  method READ_VALUE.
    DATA(lv_start) = cv_pos.
    skip_value( EXPORTING iv_json = iv_json CHANGING cv_pos = cv_pos ).
    DATA(lv_vlen) = cv_pos - lv_start.
    IF lv_vlen > 0.
      ev_value = iv_json+lv_start(lv_vlen).
    ELSE.
      CLEAR ev_value.
    ENDIF.
  endmethod.


  method JSON_EXTRACT_MEMBER.
    DATA lv_cur_key TYPE string.
    DATA lv_pos TYPE i VALUE 0.
    DATA(lv_len) = strlen( iv_json ).

    skip_ws( EXPORTING iv_json = iv_json CHANGING cv_pos = lv_pos ).
    IF lv_pos >= lv_len OR iv_json+lv_pos(1) <> '{'. RETURN. ENDIF.
    lv_pos = lv_pos + 1.

    WHILE lv_pos < lv_len.
      skip_ws( EXPORTING iv_json = iv_json CHANGING cv_pos = lv_pos ).
      IF lv_pos >= lv_len OR iv_json+lv_pos(1) = '}'. RETURN. ENDIF.
      IF iv_json+lv_pos(1) = ','.
        lv_pos = lv_pos + 1.
        CONTINUE.
      ENDIF.

      read_string( EXPORTING iv_json = iv_json IMPORTING ev_value = lv_cur_key CHANGING cv_pos = lv_pos ).

      skip_ws( EXPORTING iv_json = iv_json CHANGING cv_pos = lv_pos ).
      IF lv_pos < lv_len AND iv_json+lv_pos(1) = ':'.
        lv_pos = lv_pos + 1.
      ENDIF.
      skip_ws( EXPORTING iv_json = iv_json CHANGING cv_pos = lv_pos ).

      IF lv_cur_key = iv_key.
        read_value( EXPORTING iv_json = iv_json IMPORTING ev_value = rv_json CHANGING cv_pos = lv_pos ).
        RETURN.
      ELSE.
        skip_value( EXPORTING iv_json = iv_json CHANGING cv_pos = lv_pos ).
      ENDIF.
    ENDWHILE.
  endmethod.


  method JSON_SPLIT_ARRAY.
    DATA lv_element TYPE string.
    DATA lv_pos TYPE i VALUE 0.
    DATA(lv_len) = strlen( iv_json ).

    skip_ws( EXPORTING iv_json = iv_json CHANGING cv_pos = lv_pos ).
    IF lv_pos >= lv_len OR iv_json+lv_pos(1) <> '['. RETURN. ENDIF.
    lv_pos = lv_pos + 1.

    WHILE lv_pos < lv_len.
      skip_ws( EXPORTING iv_json = iv_json CHANGING cv_pos = lv_pos ).
      IF lv_pos >= lv_len OR iv_json+lv_pos(1) = ']'. EXIT. ENDIF.
      IF iv_json+lv_pos(1) = ','.
        lv_pos = lv_pos + 1.
        CONTINUE.
      ENDIF.

      read_value( EXPORTING iv_json = iv_json IMPORTING ev_value = lv_element CHANGING cv_pos = lv_pos ).
      APPEND lv_element TO rt_elements.
    ENDWHILE.
  endmethod.


  method JSON_EXTRACT_STRING.
    DATA lv_pos TYPE i VALUE 0.
    skip_ws( EXPORTING iv_json = iv_json CHANGING cv_pos = lv_pos ).
    IF lv_pos < strlen( iv_json ) AND iv_json+lv_pos(1) = '"'.
      read_string( EXPORTING iv_json = iv_json IMPORTING ev_value = rv_value CHANGING cv_pos = lv_pos ).
    ELSE.
      rv_value = condense( val = iv_json ).
    ENDIF.
  endmethod.


  method JSON_EXTRACT_INTEGER.
    DATA(lv_str) = condense( val = iv_json ).
    TRY.
        rv_value = lv_str.
      CATCH cx_root.
        rv_value = 0.
    ENDTRY.
  endmethod.


  method JSON_EXTRACT_BOOLEAN.
    DATA(lv_str) = to_lower( condense( val = iv_json ) ).
    IF lv_str = 'true'.
      rv_value = abap_true.
    ELSE.
      rv_value = abap_false.
    ENDIF.
  endmethod.


  method JSON_IS_OBJECT.
    DATA lv_pos TYPE i VALUE 0.
    skip_ws( EXPORTING iv_json = iv_json CHANGING cv_pos = lv_pos ).
    rv_is = boolc( lv_pos < strlen( iv_json ) AND iv_json+lv_pos(1) = '{' ).
  endmethod.


  method JSON_IS_ARRAY.
    DATA lv_pos TYPE i VALUE 0.
    skip_ws( EXPORTING iv_json = iv_json CHANGING cv_pos = lv_pos ).
    rv_is = boolc( lv_pos < strlen( iv_json ) AND iv_json+lv_pos(1) = '[' ).
  endmethod.


  method JSON_IS_NULL.
    DATA(lv_str) = to_lower( condense( val = iv_json ) ).
    rv_is = boolc( lv_str = 'null' OR lv_str IS INITIAL ).
  endmethod.


  method JSON_GET_KEYS.
    DATA lv_cur_key TYPE string.
    DATA lv_pos TYPE i VALUE 0.
    DATA(lv_len) = strlen( iv_json ).

    skip_ws( EXPORTING iv_json = iv_json CHANGING cv_pos = lv_pos ).
    IF lv_pos >= lv_len OR iv_json+lv_pos(1) <> '{'. RETURN. ENDIF.
    lv_pos = lv_pos + 1.

    WHILE lv_pos < lv_len.
      skip_ws( EXPORTING iv_json = iv_json CHANGING cv_pos = lv_pos ).
      IF lv_pos >= lv_len OR iv_json+lv_pos(1) = '}'. EXIT. ENDIF.
      IF iv_json+lv_pos(1) = ','.
        lv_pos = lv_pos + 1.
        CONTINUE.
      ENDIF.

      read_string( EXPORTING iv_json = iv_json IMPORTING ev_value = lv_cur_key CHANGING cv_pos = lv_pos ).
      APPEND lv_cur_key TO rt_keys.

      skip_ws( EXPORTING iv_json = iv_json CHANGING cv_pos = lv_pos ).
      IF lv_pos < lv_len AND iv_json+lv_pos(1) = ':'.
        lv_pos = lv_pos + 1.
      ENDIF.
      skip_ws( EXPORTING iv_json = iv_json CHANGING cv_pos = lv_pos ).
      skip_value( EXPORTING iv_json = iv_json CHANGING cv_pos = lv_pos ).
    ENDWHILE.
  endmethod.


  method PARSE_SOURCES.
    DATA(lt_elems) = json_split_array( iv_json ).
    LOOP AT lt_elems INTO DATA(lv_e).
      APPEND VALUE zif_json_dsl_types=>ty_source(
        table = json_extract_string( json_extract_member( iv_json = lv_e iv_key = 'table' ) )
        alias = json_extract_string( json_extract_member( iv_json = lv_e iv_key = 'alias' ) )
      ) TO rt_sources.
    ENDLOOP.
  endmethod.


  method PARSE_JOINS.
    DATA ls_join TYPE zif_json_dsl_types=>ty_join.
    DATA lv_wrapped TYPE string.

    DATA(lt_elems) = json_split_array( iv_json ).
    LOOP AT lt_elems INTO DATA(lv_e).
      CLEAR ls_join.

      ls_join-type = to_lower( json_extract_string( json_extract_member( iv_json = lv_e iv_key = 'type' ) ) ).

      DATA(lv_tgt) = json_extract_member( iv_json = lv_e iv_key = 'target' ).
      IF lv_tgt IS NOT INITIAL.
        ls_join-target_table = json_extract_string( json_extract_member( iv_json = lv_tgt iv_key = 'table' ) ).
        ls_join-target_alias = json_extract_string( json_extract_member( iv_json = lv_tgt iv_key = 'alias' ) ).
      ENDIF.

      DATA(lv_on) = json_extract_member( iv_json = lv_e iv_key = 'on' ).
      IF lv_on IS NOT INITIAL.
        IF json_is_array( lv_on ).
          lv_wrapped = `{"logic":"AND","conditions":` && lv_on && `}`.
          parse_condition_tree(
            EXPORTING iv_json = lv_wrapped iv_parent_id = 0
            CHANGING ct_nodes = ls_join-on_nodes ).
        ELSE.
          parse_condition_tree(
            EXPORTING iv_json = lv_on iv_parent_id = 0
            CHANGING ct_nodes = ls_join-on_nodes ).
        ENDIF.
      ENDIF.

      APPEND ls_join TO rt_joins.
    ENDLOOP.
  endmethod.


  method PARSE_CONDITION_TREE.
    DATA(lv_logic_json) = json_extract_member( iv_json = iv_json iv_key = 'logic' ).
    DATA(lv_conds_json) = json_extract_member( iv_json = iv_json iv_key = 'conditions' ).

    IF lv_logic_json IS INITIAL.
      RAISE EXCEPTION TYPE zcx_dsl_parse
        EXPORTING textid        = zcx_dsl_parse=>gc_missing_logic
                  mv_error_code = 'DSL_PARSE_006'.
    ENDIF.

    DATA(lv_node_id) = mv_next_node_id.
    mv_next_node_id = mv_next_node_id + 1.

    APPEND VALUE zif_json_dsl_types=>ty_cond_node(
      node_id   = lv_node_id
      parent_id = iv_parent_id
      node_type = 'G'
      logic     = to_upper( json_extract_string( lv_logic_json ) )
    ) TO ct_nodes.

    IF lv_conds_json IS NOT INITIAL.
      DATA(lt_children) = json_split_array( lv_conds_json ).
      LOOP AT lt_children INTO DATA(lv_child).
        DATA(lv_child_logic) = json_extract_member( iv_json = lv_child iv_key = 'logic' ).
        IF lv_child_logic IS NOT INITIAL.
          parse_condition_tree(
            EXPORTING iv_json = lv_child iv_parent_id = lv_node_id
            CHANGING ct_nodes = ct_nodes ).
        ELSE.
          parse_condition_leaf(
            EXPORTING iv_json = lv_child iv_parent_id = lv_node_id
            CHANGING ct_nodes = ct_nodes ).
        ENDIF.
      ENDLOOP.
    ENDIF.
  endmethod.


  method PARSE_CONDITION_LEAF.
    DATA ls_node TYPE zif_json_dsl_types=>ty_cond_node.

    ls_node-node_id   = mv_next_node_id.
    mv_next_node_id   = mv_next_node_id + 1.
    ls_node-parent_id = iv_parent_id.
    ls_node-node_type = 'L'.

    " Join leaf: left / right
    DATA(lv_left) = json_extract_member( iv_json = iv_json iv_key = 'left' ).
    IF lv_left IS NOT INITIAL.
      ls_node-left_field = json_extract_string( lv_left ).
    ENDIF.
    DATA(lv_right) = json_extract_member( iv_json = iv_json iv_key = 'right' ).
    IF lv_right IS NOT INITIAL.
      ls_node-right_field = json_extract_string( lv_right ).
    ENDIF.

    " Filter leaf: field
    DATA(lv_field) = json_extract_member( iv_json = iv_json iv_key = 'field' ).
    IF lv_field IS NOT INITIAL.
      ls_node-field = json_extract_string( lv_field ).
    ENDIF.

    " Operator
    DATA(lv_op) = json_extract_member( iv_json = iv_json iv_key = 'op' ).
    IF lv_op IS NOT INITIAL.
      ls_node-op = to_upper( json_extract_string( lv_op ) ).
    ENDIF.

    " Value — scalar or array
    DATA(lv_val) = json_extract_member( iv_json = iv_json iv_key = 'value' ).
    IF lv_val IS NOT INITIAL AND json_is_null( lv_val ) = abap_false.
      IF json_is_array( lv_val ).
        DATA(lt_vals) = json_split_array( lv_val ).
        LOOP AT lt_vals INTO DATA(lv_v).
          APPEND json_extract_string( lv_v ) TO ls_node-values.
        ENDLOOP.
      ELSE.
        ls_node-value = json_extract_string( lv_val ).
      ENDIF.
    ENDIF.

    " Param reference
    DATA(lv_param) = json_extract_member( iv_json = iv_json iv_key = 'param' ).
    IF lv_param IS NOT INITIAL.
      ls_node-param = json_extract_string( lv_param ).
    ENDIF.

    " Subquery — raw JSON captured for recursive build
    DATA(lv_sub) = json_extract_member( iv_json = iv_json iv_key = 'subquery' ).
    IF lv_sub IS NOT INITIAL AND json_is_null( lv_sub ) = abap_false.
      ls_node-subquery_json = lv_sub.
    ENDIF.

    APPEND ls_node TO ct_nodes.
  endmethod.


  method PARSE_SELECT.
    DATA ls_fld TYPE zif_json_dsl_types=>ty_select_field.

    DATA(lt_elems) = json_split_array( iv_json ).
    LOOP AT lt_elems INTO DATA(lv_e).
      CLEAR ls_fld.

      DATA(lv_f) = json_extract_member( iv_json = lv_e iv_key = 'field' ).
      IF lv_f IS NOT INITIAL. ls_fld-field = json_extract_string( lv_f ). ENDIF.

      DATA(lv_a) = json_extract_member( iv_json = lv_e iv_key = 'alias' ).
      IF lv_a IS NOT INITIAL. ls_fld-alias = json_extract_string( lv_a ). ENDIF.

      DATA(lv_t) = json_extract_member( iv_json = lv_e iv_key = 'type' ).
      IF lv_t IS NOT INITIAL. ls_fld-type = to_upper( json_extract_string( lv_t ) ). ENDIF.

      DATA(lv_cf) = json_extract_member( iv_json = lv_e iv_key = 'currency_field' ).
      IF lv_cf IS NOT INITIAL. ls_fld-currency_field = json_extract_string( lv_cf ). ENDIF.

      DATA(lv_uf) = json_extract_member( iv_json = lv_e iv_key = 'unit_field' ).
      IF lv_uf IS NOT INITIAL. ls_fld-unit_field = json_extract_string( lv_uf ). ENDIF.

      APPEND ls_fld TO rt_select.
    ENDLOOP.
  endmethod.


  method PARSE_GROUP_BY.
    DATA(lt_elems) = json_split_array( iv_json ).
    LOOP AT lt_elems INTO DATA(lv_e).
      APPEND json_extract_string( lv_e ) TO rt_group_by.
    ENDLOOP.
  endmethod.


  method PARSE_METRICS.
    DATA(lt_elems) = json_split_array( iv_json ).
    LOOP AT lt_elems INTO DATA(lv_e).
      APPEND VALUE zif_json_dsl_types=>ty_metric(
        type  = to_lower( json_extract_string( json_extract_member( iv_json = lv_e iv_key = 'type' ) ) )
        field = json_extract_string( json_extract_member( iv_json = lv_e iv_key = 'field' ) )
        alias = json_extract_string( json_extract_member( iv_json = lv_e iv_key = 'alias' ) )
      ) TO rt_metrics.
    ENDLOOP.
  endmethod.


  method PARSE_HAVING.
    DATA(lt_elems) = json_split_array( iv_json ).
    LOOP AT lt_elems INTO DATA(lv_e).
      APPEND VALUE zif_json_dsl_types=>ty_having(
        metric = json_extract_string( json_extract_member( iv_json = lv_e iv_key = 'metric' ) )
        op     = to_upper( json_extract_string( json_extract_member( iv_json = lv_e iv_key = 'op' ) ) )
        value  = json_extract_string( json_extract_member( iv_json = lv_e iv_key = 'value' ) )
      ) TO rt_having.
    ENDLOOP.
  endmethod.


  method PARSE_ORDER_BY.
    DATA(lt_elems) = json_split_array( iv_json ).
    LOOP AT lt_elems INTO DATA(lv_e).
      APPEND VALUE zif_json_dsl_types=>ty_order_by(
        field     = json_extract_string( json_extract_member( iv_json = lv_e iv_key = 'field' ) )
        direction = to_lower( json_extract_string( json_extract_member( iv_json = lv_e iv_key = 'direction' ) ) )
      ) TO rt_order_by.
    ENDLOOP.
  endmethod.


  method PARSE_LIMIT.
    DATA(lv_r) = json_extract_member( iv_json = iv_json iv_key = 'rows' ).
    IF lv_r IS NOT INITIAL. rs_limit-rows = json_extract_integer( lv_r ). ENDIF.

    DATA(lv_o) = json_extract_member( iv_json = iv_json iv_key = 'offset' ).
    IF lv_o IS NOT INITIAL. rs_limit-offset = json_extract_integer( lv_o ). ENDIF.

    DATA(lv_ps) = json_extract_member( iv_json = iv_json iv_key = 'page_size' ).
    IF lv_ps IS NOT INITIAL. rs_limit-page_size = json_extract_integer( lv_ps ). ENDIF.

    DATA(lv_pt) = json_extract_member( iv_json = iv_json iv_key = 'page_token' ).
    IF lv_pt IS NOT INITIAL AND json_is_null( lv_pt ) = abap_false.
      rs_limit-page_token = json_extract_string( lv_pt ).
    ENDIF.
  endmethod.


  method PARSE_PARAMS.
    DATA(lt_keys) = json_get_keys( iv_json ).
    LOOP AT lt_keys INTO DATA(lv_k).
      DATA(lv_val) = json_extract_member( iv_json = iv_json iv_key = lv_k ).
      APPEND VALUE zif_json_dsl_types=>ty_param(
        key   = lv_k
        value = json_extract_string( lv_val )
      ) TO rt_params.
    ENDLOOP.
  endmethod.


  method PARSE_OUTPUT.
    DATA(lv_ir) = json_extract_member( iv_json = iv_json iv_key = 'include_rows' ).
    IF lv_ir IS NOT INITIAL.
      rs_output-include_rows = json_extract_boolean( lv_ir ).
    ELSE.
      rs_output-include_rows = abap_true.
    ENDIF.

    DATA(lv_ia) = json_extract_member( iv_json = iv_json iv_key = 'include_aggregates' ).
    IF lv_ia IS NOT INITIAL.
      rs_output-include_aggregates = json_extract_boolean( lv_ia ).
    ELSE.
      rs_output-include_aggregates = abap_true.
    ENDIF.

    DATA(lv_is) = json_extract_member( iv_json = iv_json iv_key = 'include_summary' ).
    IF lv_is IS NOT INITIAL.
      rs_output-include_summary = json_extract_boolean( lv_is ).
    ELSE.
      rs_output-include_summary = abap_false.
    ENDIF.
  endmethod.
ENDCLASS.
