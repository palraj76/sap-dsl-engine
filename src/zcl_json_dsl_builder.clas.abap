class ZCL_JSON_DSL_BUILDER definition
  public
  final
  create public .

  public section.

    types:
      BEGIN OF ty_branch_sql,
        " Space-separated field list — OLD Open SQL syntax, consumed by the
        " in-memory branch executor.
        select_clause     TYPE string,
        " Comma-separated field list — NEW (strict) Open SQL syntax, consumed by
        " the CTE path. The CTE outer SELECT uses INTO @lv_count, which puts the
        " whole statement in strict mode, and a strict-mode dynamic column list
        " must be comma-separated. Keeping both forms means neither path has to
        " compromise the other's syntax requirements.
        select_clause_csv TYPE string,
        from_clause       TYPE string,
        where_clause      TYPE string,
      END OF ty_branch_sql .
    types ty_branch_sqls TYPE STANDARD TABLE OF ty_branch_sql WITH DEFAULT KEY .

    types:
      BEGIN OF ty_sql_result,
        select_clause    TYPE string,
        from_clause      TYPE string,
        join_clause      TYPE string,
        where_clause     TYPE string,
        group_by_clause  TYPE string,
        having_clause    TYPE string,
        order_by_clause  TYPE string,
        row_limit        TYPE i,
        strategy         TYPE string,
        needs_new_sql    TYPE abap_bool,
        " Union path
        is_union         TYPE abap_bool,
        union_distinct   TYPE abap_bool,
        union_branches   TYPE ty_branch_sqls,
        union_count_only TYPE abap_bool,
      END OF ty_sql_result .

    methods BUILD
      importing
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY
      returning
        value(RS_SQL) type TY_SQL_RESULT .

  private section.

    methods BUILD_SELECT_CLAUSE
      importing
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY
      returning
        value(RV_CLAUSE) type STRING .

    methods BUILD_FROM_CLAUSE
      importing
        !IT_SOURCES type ZIF_JSON_DSL_TYPES=>TY_SOURCES
      returning
        value(RV_CLAUSE) type STRING .

    methods BUILD_JOIN_CLAUSE
      importing
        !IT_JOINS type ZIF_JSON_DSL_TYPES=>TY_JOINS
      returning
        value(RV_CLAUSE) type STRING .

    methods BUILD_WHERE_CLAUSE
      importing
        !IT_NODES type ZIF_JSON_DSL_TYPES=>TY_COND_NODES
        !IT_PARAMS type ZIF_JSON_DSL_TYPES=>TY_PARAMS
      returning
        value(RV_CLAUSE) type STRING .

    methods BUILD_CONDITION_SQL
      importing
        !IT_NODES type ZIF_JSON_DSL_TYPES=>TY_COND_NODES
        !IV_NODE_ID type I
        !IT_PARAMS type ZIF_JSON_DSL_TYPES=>TY_PARAMS
      returning
        value(RV_SQL) type STRING .

    methods BUILD_LEAF_SQL
      importing
        !IS_NODE type ZIF_JSON_DSL_TYPES=>TY_COND_NODE
        !IT_PARAMS type ZIF_JSON_DSL_TYPES=>TY_PARAMS
      returning
        value(RV_SQL) type STRING .

    methods BUILD_GROUP_BY_CLAUSE
      importing
        !IT_GROUP_BY type STRING_TABLE
      returning
        value(RV_CLAUSE) type STRING .

    methods BUILD_HAVING_CLAUSE
      importing
        !IT_HAVING type ZIF_JSON_DSL_TYPES=>TY_HAVINGS
        !IT_METRICS type ZIF_JSON_DSL_TYPES=>TY_METRICS
      returning
        value(RV_CLAUSE) type STRING .

    methods BUILD_ORDER_BY_CLAUSE
      importing
        !IT_ORDER_BY type ZIF_JSON_DSL_TYPES=>TY_ORDER_BYS
        !IT_METRICS type ZIF_JSON_DSL_TYPES=>TY_METRICS
      returning
        value(RV_CLAUSE) type STRING .

    methods DETERMINE_STRATEGY
      importing
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY
      returning
        value(RV_STRATEGY) type STRING .

    methods TO_SQL_FIELD
      importing
        !IV_FIELD type STRING
      returning
        value(RV_SQL) type STRING .

    methods ESCAPE_VALUE
      importing
        !IV_VALUE type STRING
      returning
        value(RV_ESCAPED) type STRING .

    methods RESOLVE_PARAM
      importing
        !IV_PARAM type STRING
        !IT_PARAMS type ZIF_JSON_DSL_TYPES=>TY_PARAMS
      returning
        value(RV_VALUE) type STRING .

    methods BUILD_METRIC_EXPR
      importing
        !IS_METRIC type ZIF_JSON_DSL_TYPES=>TY_METRIC
      returning
        value(RV_EXPR) type STRING .

    methods BUILD_SUBQUERY_SQL
      importing
        !IV_JSON type STRING
      returning
        value(RV_SQL) type STRING .

    methods BUILD_UNION
      importing
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY
      changing
        !CS_SQL type TY_SQL_RESULT .
ENDCLASS.



CLASS ZCL_JSON_DSL_BUILDER IMPLEMENTATION.


  method BUILD.
    " Union path is exclusive — when set, top-level select/from/where are not
    " produced (they are left initial). Existing non-union queries keep their
    " current code path untouched.
    IF is_query-union-is_set = abap_true.
      build_union( EXPORTING is_query = is_query CHANGING cs_sql = rs_sql ).
      RETURN.
    ENDIF.

    rs_sql-strategy = determine_strategy( is_query ).

    " Detect if new SQL syntax is required:
    " - Presence of JOINs → new syntax
    " - Presence of subquery in filters → new syntax
    " - Mix of regular select fields + metrics → new syntax (needs commas)
    rs_sql-needs_new_sql = abap_false.
    IF is_query-joins IS NOT INITIAL.
      rs_sql-needs_new_sql = abap_true.
    ENDIF.
    IF is_query-select_fields IS NOT INITIAL AND is_query-metrics IS NOT INITIAL.
      rs_sql-needs_new_sql = abap_true.
    ENDIF.
    LOOP AT is_query-filter_nodes INTO DATA(ls_chk_node)
      WHERE subquery_json IS NOT INITIAL.
      rs_sql-needs_new_sql = abap_true.
      EXIT.
    ENDLOOP.

    rs_sql-select_clause = build_select_clause( is_query ).
    rs_sql-from_clause   = build_from_clause( is_query-sources ).
    rs_sql-join_clause   = build_join_clause( is_query-joins ).

    rs_sql-where_clause = build_where_clause(
      it_nodes  = is_query-filter_nodes
      it_params = is_query-params ).

    rs_sql-group_by_clause = build_group_by_clause( is_query-group_by ).

    rs_sql-having_clause = build_having_clause(
      it_having  = is_query-having
      it_metrics = is_query-metrics ).

    rs_sql-order_by_clause = build_order_by_clause(
      it_order_by = is_query-order_by
      it_metrics  = is_query-metrics ).

    " Row limit: use page_size if set, otherwise rows
    IF is_query-limit-page_size > 0.
      rs_sql-row_limit = is_query-limit-offset + is_query-limit-page_size.
    ELSEIF is_query-limit-rows > 0.
      rs_sql-row_limit = is_query-limit-rows.
    ENDIF.
  endmethod.


  method BUILD_SELECT_CLAUSE.
    DATA lt_parts TYPE string_table.

    " Regular fields — no AS alias; ABAP maps by position to target structure
    LOOP AT is_query-select_fields INTO DATA(ls_fld).
      IF ls_fld-field IS NOT INITIAL.
        APPEND to_sql_field( ls_fld-field ) TO lt_parts.
      ENDIF.
    ENDLOOP.

    " Metrics — no AS alias
    LOOP AT is_query-metrics INTO DATA(ls_met).
      DATA(lv_expr) = build_metric_expr( ls_met ).
      IF lv_expr IS NOT INITIAL.
        APPEND lv_expr TO lt_parts.
      ENDIF.
    ENDLOOP.

    " Separator: commas when JOINs, subqueries, OR mixed fields+metrics (new syntax)
    DATA(lv_needs_commas) = abap_false.
    IF is_query-joins IS NOT INITIAL.
      lv_needs_commas = abap_true.
    ELSEIF is_query-select_fields IS NOT INITIAL AND is_query-metrics IS NOT INITIAL.
      lv_needs_commas = abap_true.
    ELSE.
      LOOP AT is_query-filter_nodes INTO DATA(ls_chk)
        WHERE subquery_json IS NOT INITIAL.
        lv_needs_commas = abap_true.
        EXIT.
      ENDLOOP.
    ENDIF.

    IF lv_needs_commas = abap_true.
      rv_clause = concat_lines_of( table = lt_parts sep = `, ` ).
    ELSE.
      rv_clause = concat_lines_of( table = lt_parts sep = ` ` ).
    ENDIF.
  endmethod.


  method BUILD_METRIC_EXPR.
    CASE is_metric-type.
      WHEN 'count'.
        IF is_metric-field = '*'.
          rv_expr = 'COUNT( * )'.
        ELSE.
          rv_expr = |COUNT( { to_sql_field( is_metric-field ) } )|.
        ENDIF.
      WHEN 'count_distinct'.
        rv_expr = |COUNT( DISTINCT { to_sql_field( is_metric-field ) } )|.
      WHEN 'sum'.
        rv_expr = |SUM( { to_sql_field( is_metric-field ) } )|.
      WHEN 'avg'.
        rv_expr = |AVG( { to_sql_field( is_metric-field ) } )|.
      WHEN 'min'.
        rv_expr = |MIN( { to_sql_field( is_metric-field ) } )|.
      WHEN 'max'.
        rv_expr = |MAX( { to_sql_field( is_metric-field ) } )|.
    ENDCASE.
  endmethod.


  method BUILD_FROM_CLAUSE.
    IF it_sources IS INITIAL. RETURN. ENDIF.
    " First source is the base table
    READ TABLE it_sources INDEX 1 INTO DATA(ls_base).
    rv_clause = |{ ls_base-table } AS { ls_base-alias }|.
  endmethod.


  method BUILD_JOIN_CLAUSE.
    DATA lt_parts TYPE string_table.

    LOOP AT it_joins INTO DATA(ls_join).
      DATA lv_type TYPE string.
      CASE ls_join-type.
        WHEN 'inner'. lv_type = 'INNER JOIN'.
        WHEN 'left'.  lv_type = 'LEFT OUTER JOIN'.
        WHEN OTHERS.  lv_type = 'INNER JOIN'.
      ENDCASE.

      " Filter out MANDT conditions — SAP handles client automatically in new syntax
      DATA lt_on_nodes TYPE zif_json_dsl_types=>ty_cond_nodes.
      lt_on_nodes = ls_join-on_nodes.
      DELETE lt_on_nodes WHERE node_type = 'L'
        AND ( left_field CS 'MANDT' OR right_field CS 'MANDT' ).

      DATA(lv_on_sql) = build_where_clause(
        it_nodes  = lt_on_nodes
        it_params = VALUE zif_json_dsl_types=>ty_params( ) ).

      APPEND |{ lv_type } { ls_join-target_table } AS { ls_join-target_alias } ON { lv_on_sql }|
        TO lt_parts.
    ENDLOOP.

    rv_clause = concat_lines_of( table = lt_parts sep = ` ` ).
  endmethod.


  method BUILD_WHERE_CLAUSE.
    IF it_nodes IS INITIAL. RETURN. ENDIF.

    " Find root node (parent_id = 0)
    READ TABLE it_nodes INTO DATA(ls_root)
      WITH KEY parent_id = 0.
    IF sy-subrc <> 0. RETURN. ENDIF.

    rv_clause = build_condition_sql(
      it_nodes   = it_nodes
      iv_node_id = ls_root-node_id
      it_params  = it_params ).
  endmethod.


  method BUILD_CONDITION_SQL.
    " Find the node
    READ TABLE it_nodes INTO DATA(ls_node)
      WITH KEY node_id = iv_node_id.
    IF sy-subrc <> 0. RETURN. ENDIF.

    IF ls_node-node_type = 'L'.
      " Leaf node
      rv_sql = build_leaf_sql( is_node = ls_node it_params = it_params ).
    ELSE.
      " Group node — collect children
      DATA lt_child_sql TYPE string_table.
      LOOP AT it_nodes INTO DATA(ls_child)
        WHERE parent_id = iv_node_id.
        DATA(lv_child) = build_condition_sql(
          it_nodes   = it_nodes
          iv_node_id = ls_child-node_id
          it_params  = it_params ).
        IF lv_child IS NOT INITIAL.
          APPEND lv_child TO lt_child_sql.
        ENDIF.
      ENDLOOP.

      IF lines( lt_child_sql ) = 1.
        READ TABLE lt_child_sql INDEX 1 INTO rv_sql.
      ELSEIF lines( lt_child_sql ) > 1.
        DATA(lv_sep) = | { ls_node-logic } |.
        rv_sql = |( { concat_lines_of( table = lt_child_sql sep = lv_sep ) } )|.
      ENDIF.
    ENDIF.
  endmethod.


  method BUILD_LEAF_SQL.
    DATA lv_rhs TYPE string.

    " Join leaf: left op right (field-to-field comparison)
    IF is_node-left_field IS NOT INITIAL AND is_node-right_field IS NOT INITIAL.
      rv_sql = |{ to_sql_field( is_node-left_field ) } { is_node-op } { to_sql_field( is_node-right_field ) }|.
      RETURN.
    ENDIF.

    " Filter leaf — be lenient: if 'field' is missing but 'left' is set,
    " treat 'left' as the field (common when mixing join + value conditions)
    DATA lv_src_field TYPE string.
    IF is_node-field IS NOT INITIAL.
      lv_src_field = is_node-field.
    ELSEIF is_node-left_field IS NOT INITIAL.
      lv_src_field = is_node-left_field.
    ENDIF.
    DATA(lv_field) = to_sql_field( lv_src_field ).

    CASE is_node-op.
      WHEN 'IS NULL'.
        rv_sql = |{ lv_field } IS NULL|.
        RETURN.
      WHEN 'IS NOT NULL'.
        rv_sql = |{ lv_field } IS NOT NULL|.
        RETURN.
    ENDCASE.

    " Resolve value: from param or literal
    IF is_node-param IS NOT INITIAL.
      lv_rhs = |'{ escape_value( resolve_param( iv_param = is_node-param it_params = it_params ) ) }'|.
    ENDIF.

    CASE is_node-op.
      WHEN 'IN' OR 'NOT IN'.
        " Subquery form: IN ( SELECT ... FROM ... )
        IF is_node-subquery_json IS NOT INITIAL.
          DATA(lv_subq) = build_subquery_sql( is_node-subquery_json ).
          rv_sql = |{ lv_field } { is_node-op } ( { lv_subq } )|.
        ELSE.
          " Literal value list: IN ( 'A', 'B' )
          DATA lt_vals TYPE string_table.
          IF is_node-values IS NOT INITIAL.
            LOOP AT is_node-values INTO DATA(lv_v).
              APPEND |'{ escape_value( lv_v ) }'| TO lt_vals.
            ENDLOOP.
          ELSEIF is_node-value IS NOT INITIAL.
            APPEND |'{ escape_value( is_node-value ) }'| TO lt_vals.
          ENDIF.
          DATA(lv_list) = concat_lines_of( table = lt_vals sep = `, ` ).
          rv_sql = |{ lv_field } { is_node-op } ( { lv_list } )|.
        ENDIF.

      WHEN 'BETWEEN'.
        " Expects two values in values table
        IF lines( is_node-values ) >= 2.
          DATA(lv_lo) = escape_value( is_node-values[ 1 ] ).
          DATA(lv_hi) = escape_value( is_node-values[ 2 ] ).
          rv_sql = |{ lv_field } BETWEEN '{ lv_lo }' AND '{ lv_hi }'|.
        ENDIF.

      WHEN OTHERS.
        " Simple comparison: =, !=, >, <, >=, <=
        IF is_node-param IS NOT INITIAL.
          rv_sql = |{ lv_field } { is_node-op } '{ escape_value( resolve_param( iv_param = is_node-param it_params = it_params ) ) }'|.
        ELSE.
          rv_sql = |{ lv_field } { is_node-op } '{ escape_value( is_node-value ) }'|.
        ENDIF.
    ENDCASE.
  endmethod.


  method BUILD_GROUP_BY_CLAUSE.
    DATA lt_sql_fields TYPE string_table.
    IF it_group_by IS INITIAL. RETURN. ENDIF.
    LOOP AT it_group_by INTO DATA(lv_fld).
      APPEND to_sql_field( lv_fld ) TO lt_sql_fields.
    ENDLOOP.
    rv_clause = concat_lines_of( table = lt_sql_fields sep = `, ` ).
  endmethod.


  method BUILD_HAVING_CLAUSE.
    DATA lt_parts TYPE string_table.
    IF it_having IS INITIAL. RETURN. ENDIF.

    LOOP AT it_having INTO DATA(ls_hav).
      " Resolve metric alias to its aggregate expression
      READ TABLE it_metrics INTO DATA(ls_met)
        WITH KEY alias = ls_hav-metric.
      IF sy-subrc = 0.
        DATA(lv_expr) = build_metric_expr( ls_met ).
        APPEND |{ lv_expr } { ls_hav-op } { ls_hav-value }| TO lt_parts.
      ENDIF.
    ENDLOOP.

    rv_clause = concat_lines_of( table = lt_parts sep = ` AND ` ).
  endmethod.


  method BUILD_ORDER_BY_CLAUSE.
    DATA lt_parts TYPE string_table.
    IF it_order_by IS INITIAL. RETURN. ENDIF.

    LOOP AT it_order_by INTO DATA(ls_ob).
      DATA lv_dir TYPE string.
      IF ls_ob-direction = 'desc'.
        lv_dir = 'DESCENDING'.
      ELSE.
        lv_dir = 'ASCENDING'.
      ENDIF.

      " Check if field is a metric alias
      READ TABLE it_metrics INTO DATA(ls_met)
        WITH KEY alias = ls_ob-field.
      IF sy-subrc = 0.
        DATA(lv_expr) = build_metric_expr( ls_met ).
        APPEND |{ lv_expr } { lv_dir }| TO lt_parts.
      ELSE.
        APPEND |{ to_sql_field( ls_ob-field ) } { lv_dir }| TO lt_parts.
      ENDIF.
    ENDLOOP.

    rv_clause = concat_lines_of( table = lt_parts sep = `, ` ).
  endmethod.


  method DETERMINE_STRATEGY.
    " Default to Open SQL
    rv_strategy = 'OPEN_SQL'.

    " Check for conditions that require AMDP or Native SQL (§8.1)
    " Priority 4: offset pagination on older system
    IF is_query-limit-offset > 0.
      IF sy-saprl < '740'.
        rv_strategy = 'NATIVE_SQL'.
      ENDIF.
    ENDIF.

    " Priority 6: heavy aggregation
    IF lines( is_query-metrics ) >= 3
       AND lines( is_query-group_by ) >= 2.
      rv_strategy = 'AMDP'.
    ENDIF.
  endmethod.


  method TO_SQL_FIELD.
    " Convert DSL dot notation (u.BNAME) to ABAP Open SQL tilde (u~BNAME)
    rv_sql = iv_field.
    REPLACE ALL OCCURRENCES OF '.' IN rv_sql WITH '~'.
  endmethod.


  method ESCAPE_VALUE.
    " Escape single quotes for SQL injection prevention
    rv_escaped = iv_value.
    REPLACE ALL OCCURRENCES OF `'` IN rv_escaped WITH `''`.
  endmethod.


  method RESOLVE_PARAM.
    " Look up param value by key
    READ TABLE it_params INTO DATA(ls_param)
      WITH KEY key = iv_param.
    IF sy-subrc = 0.
      rv_value = ls_param-value.
    ENDIF.
  endmethod.


  method BUILD_UNION.
    " Build per-branch SQL fragments. Each branch reuses the existing builder
    " helpers, so the per-branch SQL is identical to what a standalone query
    " against the same tables/fields/filters would produce.
    cs_sql-is_union       = abap_true.
    cs_sql-union_distinct = is_query-union-distinct.

    LOOP AT is_query-union-branches INTO DATA(ls_br).
      DATA ls_branch_sql TYPE ty_branch_sql.
      CLEAR ls_branch_sql.

      " v1: each branch is single-source. Strip alias prefix from select/where so
      " the dynamic CTE inner SELECT works — when a CTE has dynamic specs, the
      " parser does not accept "TABLE AS alias" in its FROM token reliably, and
      " bare table+field references avoid that issue entirely. This is also fine
      " for the in-memory path (no JOIN inside the branch → no ambiguity).
      " NOTE: ABAP DATA declarations are method-scoped, not block-scoped, so
      " every variable below survives across loop iterations. Each one must be
      " cleared explicitly or branch N inherits branch N-1's content.
      DATA lv_table_only TYPE string.
      CLEAR lv_table_only.
      READ TABLE ls_br-sources INTO DATA(ls_src) INDEX 1.
      IF sy-subrc = 0.
        lv_table_only = ls_src-table.
      ENDIF.
      ls_branch_sql-from_clause = lv_table_only.

      " SELECT: bare field names (strip "alias." prefix). Space-separated to
      " match the OLD Open SQL syntax used by the in-memory branch executor.
      " (Old syntax SELECT (f1 f2) FROM ... is more lenient about RTTI work
      " area type compatibility than the strict @-form.)
      DATA lt_parts TYPE string_table.
      CLEAR lt_parts.
      LOOP AT ls_br-select_fields INTO DATA(ls_fld).
        IF ls_fld-field IS NOT INITIAL.
          DATA lv_field TYPE string.
          lv_field = ls_fld-field.
          IF lv_field CS '.'.
            SPLIT lv_field AT '.' INTO DATA(lv_a) DATA(lv_f).
            lv_field = lv_f.
          ENDIF.
          APPEND lv_field TO lt_parts.
        ENDIF.
      ENDLOOP.
      " Both separators are produced from the same field list so the two
      " execution paths can never drift apart again.
      ls_branch_sql-select_clause     = concat_lines_of( table = lt_parts sep = ` ` ).
      ls_branch_sql-select_clause_csv = concat_lines_of( table = lt_parts sep = `, ` ).

      " WHERE: build from a copy of filter_nodes with alias prefixes stripped
      DATA lt_nodes TYPE zif_json_dsl_types=>ty_cond_nodes.
      lt_nodes = ls_br-filter_nodes.
      LOOP AT lt_nodes ASSIGNING FIELD-SYMBOL(<ls_n>).
        IF <ls_n>-field CS '.'.
          SPLIT <ls_n>-field AT '.' INTO DATA(lv_fa) DATA(lv_ff).
          <ls_n>-field = lv_ff.
        ENDIF.
        IF <ls_n>-left_field CS '.'.
          SPLIT <ls_n>-left_field AT '.' INTO DATA(lv_la) DATA(lv_lf).
          <ls_n>-left_field = lv_lf.
        ENDIF.
        IF <ls_n>-right_field CS '.'.
          SPLIT <ls_n>-right_field AT '.' INTO DATA(lv_ra) DATA(lv_rf).
          <ls_n>-right_field = lv_rf.
        ENDIF.
      ENDLOOP.
      ls_branch_sql-where_clause = build_where_clause(
        it_nodes  = lt_nodes
        it_params = ls_br-params ).

      APPEND ls_branch_sql TO cs_sql-union_branches.
    ENDLOOP.

    " Detect "single COUNT(*) at top level" — that's the case the CTE path
    " optimizes for. Anything else falls through to in-memory at execution time.
    cs_sql-union_count_only = abap_false.
    IF lines( is_query-metrics ) = 1
       AND is_query-select_fields IS INITIAL
       AND is_query-group_by IS INITIAL.
      READ TABLE is_query-metrics INTO DATA(ls_m) INDEX 1.
      IF sy-subrc = 0 AND ls_m-type = 'count' AND ls_m-field = '*'.
        cs_sql-union_count_only = abap_true.
      ENDIF.
    ENDIF.

    " Strategy is decided by the executor (CTE vs INMEMORY) based on capability
    " probe. Set a placeholder for audit log.
    cs_sql-strategy      = 'UNION'.
    cs_sql-needs_new_sql = abap_true.

    " Pagination row_limit still honoured for in-memory row-list mode.
    IF is_query-limit-page_size > 0.
      cs_sql-row_limit = is_query-limit-offset + is_query-limit-page_size.
    ELSEIF is_query-limit-rows > 0.
      cs_sql-row_limit = is_query-limit-rows.
    ENDIF.
  endmethod.


  method BUILD_SUBQUERY_SQL.
    " Parse the subquery JSON (auto-inject version if missing) and build its SQL
    DATA lv_json TYPE string.
    lv_json = iv_json.

    " Auto-inject version so parse() accepts it
    DATA(lo_parser_check) = NEW zcl_json_dsl_parser( ).
    DATA(lv_has_version) = lo_parser_check->json_extract_member(
      iv_json = lv_json iv_key = 'version' ).
    IF lv_has_version IS INITIAL.
      REPLACE FIRST OCCURRENCE OF '{' IN lv_json
        WITH '{"version":"1.3",'.
    ENDIF.

    " Parse subquery as a full DSL query
    TRY.
        DATA(lo_parser) = NEW zcl_json_dsl_parser( ).
        DATA(ls_sub) = lo_parser->parse( lv_json ).
      CATCH zcx_dsl_parse.
        rv_sql = `/* invalid subquery */`.
        RETURN.
    ENDTRY.

    " Build the subquery SQL using this same builder (recursive)
    DATA(ls_sql) = build( ls_sub ).

    " Assemble: SELECT <fields> FROM <source> [JOIN ...] [WHERE ...] [GROUP BY ...]
    rv_sql = |SELECT { ls_sql-select_clause } FROM { ls_sql-from_clause }|.
    IF ls_sql-join_clause IS NOT INITIAL.
      rv_sql = rv_sql && | { ls_sql-join_clause }|.
    ENDIF.
    IF ls_sql-where_clause IS NOT INITIAL.
      rv_sql = rv_sql && | WHERE { ls_sql-where_clause }|.
    ENDIF.
    IF ls_sql-group_by_clause IS NOT INITIAL.
      rv_sql = rv_sql && | GROUP BY { ls_sql-group_by_clause }|.
    ENDIF.
  endmethod.
ENDCLASS.
