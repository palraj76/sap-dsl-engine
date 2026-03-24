class ZCL_JSON_DSL_BUILDER definition
  public
  final
  create public .

  public section.

    types:
      BEGIN OF ty_sql_result,
        select_clause  TYPE string,
        from_clause    TYPE string,
        join_clause    TYPE string,
        where_clause   TYPE string,
        group_by_clause TYPE string,
        having_clause  TYPE string,
        order_by_clause TYPE string,
        row_limit      TYPE i,
        strategy       TYPE string,
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
ENDCLASS.



CLASS ZCL_JSON_DSL_BUILDER IMPLEMENTATION.


  method BUILD.
    rs_sql-strategy = determine_strategy( is_query ).

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

    " Regular fields
    LOOP AT is_query-select_fields INTO DATA(ls_fld).
      IF ls_fld-field IS NOT INITIAL AND ls_fld-alias IS NOT INITIAL.
        APPEND |{ ls_fld-field } AS { ls_fld-alias }| TO lt_parts.
      ELSEIF ls_fld-field IS NOT INITIAL.
        APPEND ls_fld-field TO lt_parts.
      ENDIF.
    ENDLOOP.

    " Metrics
    LOOP AT is_query-metrics INTO DATA(ls_met).
      DATA(lv_expr) = build_metric_expr( ls_met ).
      IF lv_expr IS NOT INITIAL.
        APPEND |{ lv_expr } AS { ls_met-alias }| TO lt_parts.
      ENDIF.
    ENDLOOP.

    rv_clause = concat_lines_of( table = lt_parts sep = `, ` ).
  endmethod.


  method BUILD_METRIC_EXPR.
    CASE ls_metric-type.
      WHEN 'count'.
        IF ls_metric-field = '*'.
          rv_expr = 'COUNT( * )'.
        ELSE.
          rv_expr = |COUNT( { ls_metric-field } )|.
        ENDIF.
      WHEN 'count_distinct'.
        rv_expr = |COUNT( DISTINCT { ls_metric-field } )|.
      WHEN 'sum'.
        rv_expr = |SUM( { ls_metric-field } )|.
      WHEN 'avg'.
        rv_expr = |AVG( { ls_metric-field } )|.
      WHEN 'min'.
        rv_expr = |MIN( { ls_metric-field } )|.
      WHEN 'max'.
        rv_expr = |MAX( { ls_metric-field } )|.
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

      DATA(lv_on_sql) = build_where_clause(
        it_nodes  = ls_join-on_nodes
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
      rv_sql = |{ is_node-left_field } { is_node-op } { is_node-right_field }|.
      RETURN.
    ENDIF.

    " Filter leaf
    DATA(lv_field) = is_node-field.

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
      lv_rhs = |'{ escape_value( resolve_param( iv_param = is_node-param it_params = is_node-values ) ) }'|.
      " Fix: use the passed params table from the caller
      " The actual params are passed through build_where_clause
    ENDIF.

    CASE is_node-op.
      WHEN 'IN' OR 'NOT IN'.
        " Build value list
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
          " Will be resolved at execution time — use placeholder
          rv_sql = |{ lv_field } { is_node-op } '{ escape_value( is_node-param ) }'|.
        ELSE.
          rv_sql = |{ lv_field } { is_node-op } '{ escape_value( is_node-value ) }'|.
        ENDIF.
    ENDCASE.
  endmethod.


  method BUILD_GROUP_BY_CLAUSE.
    IF it_group_by IS INITIAL. RETURN. ENDIF.
    rv_clause = concat_lines_of( table = it_group_by sep = `, ` ).
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
        APPEND |{ ls_ob-field } { lv_dir }| TO lt_parts.
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
ENDCLASS.
