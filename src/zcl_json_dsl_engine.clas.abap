class ZCL_JSON_DSL_ENGINE definition
  public
  final
  create public .

  public section.

    methods EXECUTE
      importing
        !IV_JSON type STRING
        !IV_CALLER type BNAME default SY-UNAME
      returning
        value(RS_RESPONSE) type ZIF_JSON_DSL_TYPES=>TY_RESPONSE .

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
        APPEND VALUE zst_dsl_error(
          code     = lx_exec->mv_error_code
          severity = 'ERROR'
          message  = lx_exec->get_text( )
        ) TO rs_response-errors.
    ENDTRY.

    " Always set query_id
    rs_response-query_id = ls_query-query_id.
  endmethod.
ENDCLASS.
