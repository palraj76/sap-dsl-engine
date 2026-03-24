class ZCL_JSON_DSL_ENTITY_RESOLVER definition
  public
  final
  create public .

  public section.

    methods RESOLVE
      importing
        !IS_QUERY type ZIF_JSON_DSL_TYPES=>TY_QUERY
      returning
        value(RS_QUERY) type ZIF_JSON_DSL_TYPES=>TY_QUERY
      raising
        ZCX_DSL_PARSE .

  private section.

    methods LOAD_ENTITY
      importing
        !IV_ENTITY_NAME type STRING
      returning
        value(RV_JSON) type STRING
      raising
        ZCX_DSL_PARSE .

    methods RESOLVE_SELECT
      importing
        !IT_SELECT type ZIF_JSON_DSL_TYPES=>TY_SELECT_FIELDS
        !IT_ENTITY_FIELDS type ZIF_JSON_DSL_TYPES=>TY_SELECT_FIELDS
      returning
        value(RT_SELECT) type ZIF_JSON_DSL_TYPES=>TY_SELECT_FIELDS .
ENDCLASS.



CLASS ZCL_JSON_DSL_ENTITY_RESOLVER IMPLEMENTATION.


  method RESOLVE.
    rs_query = is_query.

    " No-op for raw mode
    IF rs_query-entity IS INITIAL.
      RETURN.
    ENDIF.

    " Load entity definition from ZJSON_DSL_ENTITY
    DATA(lv_entity_json) = load_entity( rs_query-entity ).

    " Parse entity JSON to extract sources, joins, fields
    DATA(lo_parser) = NEW zcl_json_dsl_parser( ).

    " Extract sources from entity JSON
    DATA(lv_sources_json) = lo_parser->json_extract_member(
      iv_json = lv_entity_json iv_key = 'sources' ).

    " We need a minimal parser call - build a temporary query JSON
    " to reuse the parser for sources/joins/fields extraction
    DATA(lv_entity_fields_json) = lo_parser->json_extract_member(
      iv_json = lv_entity_json iv_key = 'fields' ).
    DATA(lv_joins_json) = lo_parser->json_extract_member(
      iv_json = lv_entity_json iv_key = 'joins' ).

    " Parse sources
    IF lv_sources_json IS NOT INITIAL.
      rs_query-sources = lo_parser->parse_sources( lv_sources_json ).
    ENDIF.

    " Parse joins
    IF lv_joins_json IS NOT INITIAL.
      rs_query-joins = lo_parser->parse_joins( lv_joins_json ).
    ENDIF.

    " Parse entity field definitions
    DATA lt_entity_fields TYPE zif_json_dsl_types=>ty_select_fields.
    IF lv_entity_fields_json IS NOT INITIAL.
      lt_entity_fields = lo_parser->parse_select( lv_entity_fields_json ).
    ENDIF.

    " Resolve select: map entity aliases to physical fields
    rs_query-select_fields = resolve_select(
      it_select        = rs_query-select_fields
      it_entity_fields = lt_entity_fields ).
  endmethod.


  method LOAD_ENTITY.
    " Read entity definition from ZJSON_DSL_ENTITY table
    SELECT SINGLE entity_json INTO rv_json
      FROM zjson_dsl_entity
      WHERE entity_name = iv_entity_name
        AND active      = abap_true.

    IF sy-subrc <> 0 OR rv_json IS INITIAL.
      RAISE EXCEPTION TYPE zcx_dsl_parse
        EXPORTING textid        = zcx_dsl_parse=>gc_missing_field
                  mv_error_code = 'DSL_ENTITY_001'
                  mv_attr1      = iv_entity_name.
    ENDIF.
  endmethod.


  method RESOLVE_SELECT.
    " For each select entry from the caller:
    "   If it has only an alias (entity mode), find the matching
    "   entity field definition and expand to full field path.
    "   If it already has a field (raw mode passthrough), keep as-is.
    DATA ls_resolved TYPE zif_json_dsl_types=>ty_select_field.

    LOOP AT it_select INTO DATA(ls_sel).
      CLEAR ls_resolved.

      IF ls_sel-field IS NOT INITIAL.
        " Already has a physical field path — passthrough
        ls_resolved = ls_sel.
      ELSE.
        " Entity mode — resolve alias to physical field
        READ TABLE it_entity_fields INTO DATA(ls_entity_fld)
          WITH KEY alias = ls_sel-alias.
        IF sy-subrc = 0.
          ls_resolved-field          = ls_entity_fld-field.
          ls_resolved-alias          = ls_sel-alias.
          ls_resolved-type           = ls_entity_fld-type.
          ls_resolved-currency_field = ls_entity_fld-currency_field.
          ls_resolved-unit_field     = ls_entity_fld-unit_field.
        ELSE.
          " Unknown alias — keep as-is, validator will catch it
          ls_resolved = ls_sel.
        ENDIF.
      ENDIF.

      APPEND ls_resolved TO rt_select.
    ENDLOOP.
  endmethod.
ENDCLASS.
