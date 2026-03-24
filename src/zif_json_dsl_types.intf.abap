interface ZIF_JSON_DSL_TYPES
  public .

  " ─── Source (FROM clause) ───
  types:
    BEGIN OF ty_source,
      table TYPE string,
      alias TYPE string,
    END OF ty_source .
  types ty_sources TYPE STANDARD TABLE OF ty_source WITH DEFAULT KEY .

  " ─── Condition node (recursive tree, flattened) ───
  "   G = group (AND/OR with children)
  "   L = leaf  (field comparison)
  types:
    BEGIN OF ty_cond_node,
      node_id     TYPE i,
      parent_id   TYPE i,
      node_type   TYPE c LENGTH 1,
      logic       TYPE string,
      left_field  TYPE string,
      right_field TYPE string,
      field       TYPE string,
      op          TYPE string,
      value       TYPE string,
      param       TYPE string,
      values      TYPE string_table,
    END OF ty_cond_node .
  types ty_cond_nodes TYPE STANDARD TABLE OF ty_cond_node WITH DEFAULT KEY .

  " ─── Join ───
  types:
    BEGIN OF ty_join,
      type         TYPE string,
      target_table TYPE string,
      target_alias TYPE string,
      on_nodes     TYPE ty_cond_nodes,
    END OF ty_join .
  types ty_joins TYPE STANDARD TABLE OF ty_join WITH DEFAULT KEY .

  " ─── Select field ───
  types:
    BEGIN OF ty_select_field,
      field          TYPE string,
      alias          TYPE string,
      type           TYPE string,
      currency_field TYPE string,
      unit_field     TYPE string,
    END OF ty_select_field .
  types ty_select_fields TYPE STANDARD TABLE OF ty_select_field WITH DEFAULT KEY .

  " ─── Metric ───
  types:
    BEGIN OF ty_metric,
      type  TYPE string,
      field TYPE string,
      alias TYPE string,
    END OF ty_metric .
  types ty_metrics TYPE STANDARD TABLE OF ty_metric WITH DEFAULT KEY .

  " ─── Having ───
  types:
    BEGIN OF ty_having,
      metric TYPE string,
      op     TYPE string,
      value  TYPE string,
    END OF ty_having .
  types ty_havings TYPE STANDARD TABLE OF ty_having WITH DEFAULT KEY .

  " ─── Order By ───
  types:
    BEGIN OF ty_order_by,
      field     TYPE string,
      direction TYPE string,
    END OF ty_order_by .
  types ty_order_bys TYPE STANDARD TABLE OF ty_order_by WITH DEFAULT KEY .

  " ─── Limit / Pagination ───
  types:
    BEGIN OF ty_limit,
      rows       TYPE i,
      offset     TYPE i,
      page_size  TYPE i,
      page_token TYPE string,
    END OF ty_limit .

  " ─── Parameter ───
  types:
    BEGIN OF ty_param,
      key   TYPE string,
      value TYPE string,
    END OF ty_param .
  types ty_params TYPE STANDARD TABLE OF ty_param WITH DEFAULT KEY .

  " ─── Output control ───
  types:
    BEGIN OF ty_output,
      include_rows       TYPE abap_bool,
      include_aggregates TYPE abap_bool,
      include_summary    TYPE abap_bool,
    END OF ty_output .

  " ─── Full parsed query ───
  types:
    BEGIN OF ty_query,
      version       TYPE string,
      query_id      TYPE string,
      entity        TYPE string,
      sources       TYPE ty_sources,
      joins         TYPE ty_joins,
      select_fields TYPE ty_select_fields,
      filter_nodes  TYPE ty_cond_nodes,
      group_by      TYPE string_table,
      metrics       TYPE ty_metrics,
      having        TYPE ty_havings,
      order_by      TYPE ty_order_bys,
      limit         TYPE ty_limit,
      params        TYPE ty_params,
      output        TYPE ty_output,
      warnings      TYPE ztt_dsl_error,
    END OF ty_query .

  " ─── Response types ───
  types:
    BEGIN OF ty_nv_pair,
      name  TYPE string,
      value TYPE string,
    END OF ty_nv_pair .
  types ty_nv_pairs TYPE STANDARD TABLE OF ty_nv_pair WITH DEFAULT KEY .
  types ty_result_row TYPE ty_nv_pairs .
  types ty_result_rows TYPE STANDARD TABLE OF ty_result_row WITH DEFAULT KEY .

  types:
    BEGIN OF ty_aggregate,
      alias TYPE string,
      type  TYPE string,
      value TYPE string,
    END OF ty_aggregate .
  types ty_aggregates TYPE STANDARD TABLE OF ty_aggregate WITH DEFAULT KEY .

  types:
    BEGIN OF ty_meta,
      row_count               TYPE i,
      total_count             TYPE i,
      has_more                TYPE abap_bool,
      next_page_token         TYPE string,
      execution_time_ms       TYPE i,
      strategy_used           TYPE string,
      count_distinct_fallback TYPE abap_bool,
      entity_resolved         TYPE string,
    END OF ty_meta .

  types:
    BEGIN OF ty_response,
      query_id   TYPE string,
      rows       TYPE ty_result_rows,
      aggregates TYPE ty_aggregates,
      meta       TYPE ty_meta,
      warnings   TYPE ztt_dsl_error,
      errors     TYPE ztt_dsl_error,
    END OF ty_response .

endinterface.
