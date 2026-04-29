class ZCL_JSON_DSL_CAPABILITY definition
  public
  final
  create public .

  public section.

    " Returns abap_true if the database supports
    "   WITH +cte AS ( SELECT ... UNION DISTINCT SELECT ... )
    "   SELECT COUNT(*) FROM +cte
    " in Open SQL. Result is cached at class-data level for the lifetime of
    " the work process. The user can override the probe via ZJSON_DSL_CONFIG row
    " CTE_UNION_MODE = AUTO | FORCE_ON | FORCE_OFF (default AUTO).
    class-methods IS_CTE_UNION_SUPPORTED
      returning
        value(RV_SUPPORTED) type ABAP_BOOL .

    " Reset the cache — primarily for unit tests.
    class-methods RESET_CACHE .

  private section.

    class-data GV_RESOLVED type ABAP_BOOL .
    class-data GV_SUPPORTED type ABAP_BOOL .

    class-methods PROBE
      returning
        value(RV_SUPPORTED) type ABAP_BOOL .

    class-methods GET_CONFIG_MODE
      returning
        value(RV_MODE) type STRING .
ENDCLASS.



CLASS ZCL_JSON_DSL_CAPABILITY IMPLEMENTATION.


  method IS_CTE_UNION_SUPPORTED.
    " Cached result?
    IF gv_resolved = abap_true.
      rv_supported = gv_supported.
      RETURN.
    ENDIF.

    " Honour explicit override from config table.
    DATA(lv_mode) = get_config_mode( ).
    CASE lv_mode.
      WHEN 'FORCE_ON'.
        gv_supported = abap_true.
      WHEN 'FORCE_OFF'.
        gv_supported = abap_false.
      WHEN OTHERS.
        " AUTO (or missing/unknown) — actually probe the DB.
        gv_supported = probe( ).
    ENDCASE.

    gv_resolved  = abap_true.
    rv_supported = gv_supported.
  endmethod.


  method RESET_CACHE.
    CLEAR: gv_resolved, gv_supported.
  endmethod.


  method PROBE.
    " Run a tiny CTE+UNION query against T000 (a system table that exists on
    " every SAP installation). If the DB / kernel rejects the syntax, treat
    " CTE+UNION as unsupported and the executor will fall back to in-memory.
    DATA lv_dummy TYPE i.

    TRY.
        WITH +probe AS (
          SELECT mandt FROM t000
          UNION DISTINCT
          SELECT mandt FROM t000 )
          SELECT COUNT(*) FROM +probe INTO @lv_dummy.

        rv_supported = abap_true.
      CATCH cx_sy_open_sql_db cx_sy_dynamic_osql_syntax cx_root.
        rv_supported = abap_false.
    ENDTRY.
  endmethod.


  method GET_CONFIG_MODE.
    DATA lv_val TYPE zjson_dsl_config-config_value.
    SELECT SINGLE config_value INTO lv_val
      FROM zjson_dsl_config
      WHERE config_key = 'CTE_UNION_MODE'.
    IF sy-subrc = 0.
      rv_mode = to_upper( lv_val ).
    ELSE.
      rv_mode = 'AUTO'.
    ENDIF.
  endmethod.
ENDCLASS.
