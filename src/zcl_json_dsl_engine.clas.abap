class ZCL_JSON_DSL_ENGINE definition
  public
  final
  create public .

  public section.

    methods EXECUTE
      importing
        !IV_JSON type STRING
        !IV_CALLER type SYUNAME default SY-UNAME
      returning
        value(RS_RESPONSE) type ZIF_JSON_DSL_TYPES=>TY_RESPONSE .

    methods GET_EXPECTED_FORMAT
      importing
        !IV_ERROR_CODE type ZDSL_DE_ECODE
      returning
        value(RV_HINT) type STRING .

    class-methods GET_TEMPLATE
      returning
        value(RV_JSON) type STRING .

  private section.
ENDCLASS.



CLASS ZCL_JSON_DSL_ENGINE IMPLEMENTATION.


  method EXECUTE.
    " The engine facade: parse → resolve → validate → build → execute
    " Always returns a response — never a raw exception to the caller.

    DATA ls_query TYPE zif_json_dsl_types=>ty_query.

    " ─── Step 1: Parse JSON ───
    TRY.
        DATA(lo_parser) = NEW zcl_json_dsl_parser( ).
        ls_query = lo_parser->parse( iv_json ).
      CATCH zcx_dsl_parse INTO DATA(lx_parse).
        APPEND VALUE zst_dsl_error(
          code     = lx_parse->mv_error_code
          severity = 'ERROR'
          message  = lx_parse->get_text( )
          hint     = get_expected_format( lx_parse->mv_error_code )
        ) TO rs_response-errors.
        RETURN.
    ENDTRY.

    " ─── Step 2: Entity Resolution ───
    TRY.
        DATA(lo_resolver) = NEW zcl_json_dsl_entity_resolver( ).
        ls_query = lo_resolver->resolve( ls_query ).
      CATCH zcx_dsl_parse INTO DATA(lx_entity).
        APPEND VALUE zst_dsl_error(
          code     = lx_entity->mv_error_code
          severity = 'ERROR'
          message  = lx_entity->get_text( )
        ) TO rs_response-errors.
        RETURN.
    ENDTRY.

    " ─── Step 3: Validate ───
    TRY.
        DATA(lo_validator) = NEW zcl_json_dsl_validator( ).
        DATA(lt_errors) = lo_validator->validate(
          is_query  = ls_query
          iv_caller = iv_caller ).

        " Separate errors from warnings
        LOOP AT lt_errors INTO DATA(ls_err).
          IF ls_err-severity = 'ERROR'.
            APPEND ls_err TO rs_response-errors.
          ELSE.
            APPEND ls_err TO rs_response-warnings.
          ENDIF.
        ENDLOOP.

        " If any errors, stop before execution
        IF rs_response-errors IS NOT INITIAL.
          RETURN.
        ENDIF.

      CATCH zcx_dsl_security INTO DATA(lx_sec).
        APPEND VALUE zst_dsl_error(
          code     = lx_sec->mv_error_code
          severity = 'ERROR'
          message  = lx_sec->get_text( )
        ) TO rs_response-errors.
        RETURN.
    ENDTRY.

    " ─── Step 4: Build SQL ───
    DATA(lo_builder) = NEW zcl_json_dsl_builder( ).
    DATA(ls_sql) = lo_builder->build( ls_query ).

    " ─── Step 5: Execute ───
    TRY.
        DATA(lo_executor) = NEW zcl_json_dsl_executor( ).
        rs_response = lo_executor->execute(
          is_query  = ls_query
          is_sql    = ls_sql
          iv_caller = iv_caller ).

        " Carry forward validation warnings
        LOOP AT lt_errors INTO DATA(ls_warn)
          WHERE severity = 'WARNING'.
          APPEND ls_warn TO rs_response-warnings.
        ENDLOOP.

      CATCH zcx_dsl_parse INTO DATA(lx_exec).
        " Build the SQL string for debugging
        DATA lv_sql TYPE string.
        lv_sql = |SELECT { ls_sql-select_clause } FROM { ls_sql-from_clause }|.
        IF ls_sql-join_clause IS NOT INITIAL.
          lv_sql = lv_sql && | { ls_sql-join_clause }|.
        ENDIF.
        IF ls_sql-where_clause IS NOT INITIAL.
          lv_sql = lv_sql && | WHERE { ls_sql-where_clause }|.
        ENDIF.
        IF ls_sql-group_by_clause IS NOT INITIAL.
          lv_sql = lv_sql && | GROUP BY { ls_sql-group_by_clause }|.
        ENDIF.

        APPEND VALUE zst_dsl_error(
          code     = lx_exec->mv_error_code
          severity = 'ERROR'
          message  = lx_exec->get_text( )
          hint     = lv_sql
        ) TO rs_response-errors.
    ENDTRY.

    " Always set query_id and metadata
    rs_response-query_id    = ls_query-query_id.
    rs_response-metric_name = ls_query-metric_name.
    rs_response-metric_id   = ls_query-metric_id.
    rs_response-priority    = ls_query-priority.
    rs_response-module      = ls_query-module.
  endmethod.


  method GET_EXPECTED_FORMAT.
    CASE iv_error_code.
      WHEN 'DSL_PARSE_001'.
        rv_hint = 'Request body must be a valid JSON object starting with {'.
      WHEN 'DSL_PARSE_002'.
        rv_hint = 'Supported versions: "1.2", "1.3". Set "version":"1.3"'.
      WHEN 'DSL_PARSE_003'.
        rv_hint = 'Required fields: version, select, and either sources or entity. ' &&
                  'Call GET_TEMPLATE() for the expected JSON structure.'.
      WHEN 'DSL_PARSE_004'.
        rv_hint = 'Allowed top-level keys: version, query_id, entity, sources, joins, ' &&
                  'select, filters, group_by, metrics, having, order_by, limit, params, output. ' &&
                  'Check for typos (e.g. dataSources should be sources, operator should be op, ' &&
                  'groupBy should be group_by, aggregations should be metrics).'.
      WHEN 'DSL_PARSE_005'.
        rv_hint = 'Use either "entity" (entity mode) OR "sources"/"joins" (raw mode), not both.'.
      WHEN 'DSL_PARSE_006'.
        rv_hint = 'Every condition node must have "logic":"AND" or "logic":"OR" and a "conditions" array.'.
      WHEN OTHERS.
        rv_hint = 'Call GET_TEMPLATE() for the expected JSON structure.'.
    ENDCASE.
  endmethod.


  method GET_TEMPLATE.
    " Returns a valid DSL JSON template that callers can use as reference
    rv_json =
      '{' &&
      '  "version": "1.3",' &&
      '  "query_id": "Q-001",' &&
      '  "sources": [{"table": "TABLE_NAME", "alias": "t"}],' &&
      '  "joins": [{"type": "left|inner", "target": {"table": "JOIN_TABLE", "alias": "j"},' &&
      '    "on": {"logic": "AND", "conditions": [' &&
      '      {"left": "t.KEY_FIELD", "op": "=", "right": "j.KEY_FIELD"},' &&
      '      {"left": "t.MANDT", "op": "=", "right": "j.MANDT"}' &&
      '    ]}}],' &&
      '  "select": [' &&
      '    {"field": "t.FIELD1", "alias": "output_name", "type": "STRING|DATE|NUMBER"}' &&
      '  ],' &&
      '  "metrics": [' &&
      '    {"type": "count|count_distinct|sum|avg|min|max", "field": "*", "alias": "metric_name"}' &&
      '  ],' &&
      '  "filters": {"logic": "AND", "conditions": [' &&
      '    {"field": "t.FIELD", "op": "=|!=|>|<|>=|<=|IN|NOT IN|IS NULL|IS NOT NULL|BETWEEN", "value": "X"},' &&
      '    {"field": "t.FIELD", "op": "IN", "value": ["A","B"]},' &&
      '    {"field": "t.FIELD", "op": ">=", "param": "paramKey"},' &&
      '    {"logic": "OR", "conditions": [{"field": "t.F1", "op": "=", "value": "X"}, {"field": "t.F2", "op": "=", "value": "Y"}]}' &&
      '  ]},' &&
      '  "group_by": ["t.FIELD1"],' &&
      '  "having": [{"metric": "metric_name", "op": ">", "value": "5"}],' &&
      '  "order_by": [{"field": "t.FIELD1", "direction": "asc|desc"}],' &&
      '  "limit": {"rows": 100, "page_size": 50, "offset": 0},' &&
      '  "params": {"paramKey": "value"},' &&
      '  "output": {"include_rows": true, "include_aggregates": true, "include_summary": false}' &&
      '}'.
  endmethod.
ENDCLASS.
