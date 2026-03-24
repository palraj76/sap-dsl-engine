class ZCL_JSON_DSL_TEST definition
  public
  final
  create public
  for testing
  duration short
  risk level harmless .

  private section.

    data MO_ENGINE type ref to ZCL_JSON_DSL_ENGINE .

    methods SETUP .

    " ─── Parser tests ───
    methods PARSE_VALID_SIMPLE for testing .
    methods PARSE_MALFORMED_JSON for testing .
    methods PARSE_UNSUPPORTED_VERSION for testing .
    methods PARSE_MISSING_VERSION for testing .
    methods PARSE_MISSING_SELECT for testing .
    methods PARSE_MISSING_SOURCES for testing .
    methods PARSE_ENTITY_SOURCES_CONFLICT for testing .
    methods PARSE_UNKNOWN_KEY for testing .
    methods PARSE_MISSING_LOGIC for testing .
    methods PARSE_FLAT_FILTER_DEPRECATED for testing .

    " ─── Semantic validation tests ───
    methods SEM_GROUP_BY_MISSING for testing .
    methods SEM_HAVING_WITHOUT_GROUP for testing .
    methods SEM_HAVING_ALIAS_INVALID for testing .
    methods SEM_PARAM_NOT_SUPPLIED for testing .
    methods SEM_DUPLICATE_ALIAS for testing .
    methods SEM_PAGINATION_NO_ORDER for testing .
    methods SEM_IS_NULL_WITH_VALUE for testing .
    methods SEM_FIELD_NOT_QUALIFIED for testing .

    " ─── Injection defense tests ───
    methods SEC_INVALID_FIELD_PATTERN for testing .
    methods SEC_INVALID_OPERATOR for testing .
    methods SEC_VALUE_TOO_LONG for testing .

    " ─── Guardrail tests ───
    methods GUARD_MAX_ROWS_EXCEEDED for testing .

    " ─── Builder tests ───
    methods BUILD_SIMPLE_SELECT for testing .
    methods BUILD_WHERE_WITH_IN for testing .
    methods BUILD_JOIN_SQL for testing .
    methods BUILD_DOT_TO_TILDE for testing .

    " ─── End to end ───
    methods E2E_SIMPLE_QUERY for testing .
    methods E2E_WITH_FILTER for testing .

    " ─── Helpers ───
    methods RUN_ENGINE
      importing
        !IV_JSON type STRING
      returning
        value(RS_RESPONSE) type ZIF_JSON_DSL_TYPES=>TY_RESPONSE .

    methods ASSERT_ERROR
      importing
        !IS_RESPONSE type ZIF_JSON_DSL_TYPES=>TY_RESPONSE
        !IV_CODE type STRING .

    methods ASSERT_NO_ERRORS
      importing
        !IS_RESPONSE type ZIF_JSON_DSL_TYPES=>TY_RESPONSE .

    methods ASSERT_WARNING
      importing
        !IS_RESPONSE type ZIF_JSON_DSL_TYPES=>TY_RESPONSE
        !IV_CODE type STRING .
ENDCLASS.



CLASS ZCL_JSON_DSL_TEST IMPLEMENTATION.


  method SETUP.
    mo_engine = NEW zcl_json_dsl_engine( ).
  endmethod.


  method RUN_ENGINE.
    rs_response = mo_engine->execute( iv_json = iv_json ).
  endmethod.


  method ASSERT_ERROR.
    READ TABLE is_response-errors WITH KEY code = iv_code TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc(
      exp = 0
      msg = |Expected error { iv_code } not found| ).
  endmethod.


  method ASSERT_NO_ERRORS.
    cl_abap_unit_assert=>assert_initial(
      act = is_response-errors
      msg = 'Expected no errors but found some' ).
  endmethod.


  method ASSERT_WARNING.
    READ TABLE is_response-warnings WITH KEY code = iv_code TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc(
      exp = 0
      msg = |Expected warning { iv_code } not found| ).
  endmethod.


  " ═══════════════════════════════════════════════════════════
  "  PARSER TESTS
  " ═══════════════════════════════════════════════════════════

  method PARSE_VALID_SIMPLE.
    DATA(lo_parser) = NEW zcl_json_dsl_parser( ).
    DATA(ls_query) = lo_parser->parse(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user","type":"STRING"}],' &&
      '"limit":{"rows":10}}' ).

    cl_abap_unit_assert=>assert_equals( exp = '1.3' act = ls_query-version ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( ls_query-sources ) ).
    cl_abap_unit_assert=>assert_equals( exp = 'USR02' act = ls_query-sources[ 1 ]-table ).
    cl_abap_unit_assert=>assert_equals( exp = 'u' act = ls_query-sources[ 1 ]-alias ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( ls_query-select_fields ) ).
    cl_abap_unit_assert=>assert_equals( exp = 'u.BNAME' act = ls_query-select_fields[ 1 ]-field ).
    cl_abap_unit_assert=>assert_equals( exp = 'user' act = ls_query-select_fields[ 1 ]-alias ).
    cl_abap_unit_assert=>assert_equals( exp = 'STRING' act = ls_query-select_fields[ 1 ]-type ).
    cl_abap_unit_assert=>assert_equals( exp = 10 act = ls_query-limit-rows ).
  endmethod.


  method PARSE_MALFORMED_JSON.
    DATA(ls_resp) = run_engine( 'this is not json' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_PARSE_001' ).
  endmethod.


  method PARSE_UNSUPPORTED_VERSION.
    DATA(ls_resp) = run_engine(
      '{"version":"9.9","sources":[{"table":"T","alias":"t"}],' &&
      '"select":[{"field":"t.F","alias":"f"}]}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_PARSE_002' ).
  endmethod.


  method PARSE_MISSING_VERSION.
    DATA(ls_resp) = run_engine(
      '{"sources":[{"table":"T","alias":"t"}],' &&
      '"select":[{"field":"t.F","alias":"f"}]}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_PARSE_003' ).
  endmethod.


  method PARSE_MISSING_SELECT.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"T","alias":"t"}]}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_PARSE_003' ).
  endmethod.


  method PARSE_MISSING_SOURCES.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","select":[{"field":"t.F","alias":"f"}]}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_PARSE_003' ).
  endmethod.


  method PARSE_ENTITY_SOURCES_CONFLICT.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","entity":"user_access",' &&
      '"sources":[{"table":"T","alias":"t"}],' &&
      '"select":[{"field":"t.F","alias":"f"}]}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_PARSE_005' ).
  endmethod.


  method PARSE_UNKNOWN_KEY.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"T","alias":"t"}],' &&
      '"select":[{"field":"t.F","alias":"f"}],"bogus":"value"}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_PARSE_004' ).
  endmethod.


  method PARSE_MISSING_LOGIC.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user"}],' &&
      '"filters":{"conditions":[{"field":"u.USTYP","op":"=","value":"A"}]}}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_PARSE_006' ).
  endmethod.


  method PARSE_FLAT_FILTER_DEPRECATED.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user"}],' &&
      '"filters":[{"field":"u.USTYP","op":"=","value":"A"}]}' ).
    assert_warning( is_response = ls_resp iv_code = 'DSL_DEPR_001' ).
  endmethod.


  " ═══════════════════════════════════════════════════════════
  "  SEMANTIC VALIDATION TESTS
  " ═══════════════════════════════════════════════════════════

  method SEM_GROUP_BY_MISSING.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user"}],' &&
      '"metrics":[{"type":"count","field":"*","alias":"cnt"}]}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_SEM_003' ).
  endmethod.


  method SEM_HAVING_WITHOUT_GROUP.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user"}],' &&
      '"having":[{"metric":"cnt","op":">","value":"5"}]}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_SEM_002' ).
  endmethod.


  method SEM_HAVING_ALIAS_INVALID.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user"}],' &&
      '"group_by":["u.BNAME"],' &&
      '"metrics":[{"type":"count","field":"*","alias":"cnt"}],' &&
      '"having":[{"metric":"bogus","op":">","value":"5"}]}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_SEM_001' ).
  endmethod.


  method SEM_PARAM_NOT_SUPPLIED.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user"}],' &&
      '"filters":{"logic":"AND","conditions":[' &&
      '{"field":"u.USTYP","op":"=","param":"myParam"}]}}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_SEM_004' ).
  endmethod.


  method SEM_DUPLICATE_ALIAS.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"dup"},{"field":"u.USTYP","alias":"dup"}]}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_SEM_005' ).
  endmethod.


  method SEM_PAGINATION_NO_ORDER.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user"}],' &&
      '"limit":{"rows":10,"offset":5}}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_SEM_009' ).
  endmethod.


  method SEM_IS_NULL_WITH_VALUE.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user"}],' &&
      '"filters":{"logic":"AND","conditions":[' &&
      '{"field":"u.USTYP","op":"IS NULL","value":"X"}]}}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_SEM_010' ).
  endmethod.


  method SEM_FIELD_NOT_QUALIFIED.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"BNAME","alias":"user"}]}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_SEM_011' ).
  endmethod.


  " ═══════════════════════════════════════════════════════════
  "  INJECTION DEFENSE TESTS
  " ═══════════════════════════════════════════════════════════

  method SEC_INVALID_FIELD_PATTERN.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME; DROP TABLE","alias":"hack"}]}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_SEC_002' ).
  endmethod.


  method SEC_INVALID_OPERATOR.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user"}],' &&
      '"filters":{"logic":"AND","conditions":[' &&
      '{"field":"u.USTYP","op":"DROP","value":"X"}]}}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_SEC_003' ).
  endmethod.


  method SEC_VALUE_TOO_LONG.
    " Build a value > 500 chars
    DATA lv_long TYPE string.
    DO 501 TIMES.
      lv_long = lv_long && 'X'.
    ENDDO.
    DATA(lv_json) =
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user"}],' &&
      '"filters":{"logic":"AND","conditions":[' &&
      '{"field":"u.USTYP","op":"=","value":"' && lv_long && '"}]}}'.
    DATA(ls_resp) = run_engine( lv_json ).
    assert_error( is_response = ls_resp iv_code = 'DSL_SEC_004' ).
  endmethod.


  " ═══════════════════════════════════════════════════════════
  "  GUARDRAIL TESTS
  " ═══════════════════════════════════════════════════════════

  method GUARD_MAX_ROWS_EXCEEDED.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user"}],' &&
      '"limit":{"rows":999999}}' ).
    assert_error( is_response = ls_resp iv_code = 'DSL_GUARD_001' ).
  endmethod.


  " ═══════════════════════════════════════════════════════════
  "  BUILDER TESTS
  " ═══════════════════════════════════════════════════════════

  method BUILD_SIMPLE_SELECT.
    DATA(lo_parser) = NEW zcl_json_dsl_parser( ).
    DATA(ls_query) = lo_parser->parse(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user"}],"limit":{"rows":5}}' ).
    DATA(lo_builder) = NEW zcl_json_dsl_builder( ).
    DATA(ls_sql) = lo_builder->build( ls_query ).

    cl_abap_unit_assert=>assert_equals( exp = 'u~BNAME AS user' act = ls_sql-select_clause ).
    cl_abap_unit_assert=>assert_equals( exp = 'USR02 AS u' act = ls_sql-from_clause ).
    cl_abap_unit_assert=>assert_equals( exp = 5 act = ls_sql-row_limit ).
    cl_abap_unit_assert=>assert_equals( exp = 'OPEN_SQL' act = ls_sql-strategy ).
  endmethod.


  method BUILD_WHERE_WITH_IN.
    DATA(lo_parser) = NEW zcl_json_dsl_parser( ).
    DATA(ls_query) = lo_parser->parse(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user"}],' &&
      '"filters":{"logic":"AND","conditions":[' &&
      '{"field":"u.USTYP","op":"IN","value":["A","B"]}]}}' ).
    DATA(lo_builder) = NEW zcl_json_dsl_builder( ).
    DATA(ls_sql) = lo_builder->build( ls_query ).

    cl_abap_unit_assert=>assert_char_cp(
      act = ls_sql-where_clause
      exp = '*u~USTYP IN*' ).
  endmethod.


  method BUILD_JOIN_SQL.
    DATA(lo_parser) = NEW zcl_json_dsl_parser( ).
    DATA(ls_query) = lo_parser->parse(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"joins":[{"type":"left","target":{"table":"AGR_USERS","alias":"ru"},' &&
      '"on":{"logic":"AND","conditions":[' &&
      '{"left":"u.BNAME","op":"=","right":"ru.UNAME"},' &&
      '{"left":"u.MANDT","op":"=","right":"ru.MANDT"}]}}],' &&
      '"select":[{"field":"u.BNAME","alias":"user"},{"field":"ru.AGR_NAME","alias":"role"}]}' ).
    DATA(lo_builder) = NEW zcl_json_dsl_builder( ).
    DATA(ls_sql) = lo_builder->build( ls_query ).

    cl_abap_unit_assert=>assert_char_cp(
      act = ls_sql-join_clause
      exp = '*LEFT OUTER JOIN AGR_USERS AS ru ON*u~BNAME*ru~UNAME*' ).
  endmethod.


  method BUILD_DOT_TO_TILDE.
    DATA(lo_parser) = NEW zcl_json_dsl_parser( ).
    DATA(ls_query) = lo_parser->parse(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user"}],"limit":{"rows":1}}' ).
    DATA(lo_builder) = NEW zcl_json_dsl_builder( ).
    DATA(ls_sql) = lo_builder->build( ls_query ).

    " Must not contain dots in SQL output
    cl_abap_unit_assert=>assert_char_not_cp( act = ls_sql-select_clause exp = '*.*' ).
    cl_abap_unit_assert=>assert_char_cp( act = ls_sql-select_clause exp = '*~*' ).
  endmethod.


  " ═══════════════════════════════════════════════════════════
  "  END-TO-END TESTS
  " ═══════════════════════════════════════════════════════════

  method E2E_SIMPLE_QUERY.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user","type":"STRING"}],' &&
      '"limit":{"rows":5}}' ).

    assert_no_errors( ls_resp ).
    cl_abap_unit_assert=>assert_equals( exp = 'OPEN_SQL' act = ls_resp-meta-strategy_used ).
    cl_abap_unit_assert=>assert_not_initial( act = ls_resp-meta-row_count ).
  endmethod.


  method E2E_WITH_FILTER.
    DATA(ls_resp) = run_engine(
      '{"version":"1.3","sources":[{"table":"USR02","alias":"u"}],' &&
      '"select":[{"field":"u.BNAME","alias":"user","type":"STRING"}],' &&
      '"filters":{"logic":"AND","conditions":[' &&
      '{"field":"u.USTYP","op":"=","value":"A"}]},' &&
      '"limit":{"rows":3}}' ).

    assert_no_errors( ls_resp ).
    cl_abap_unit_assert=>assert_number_between(
      lower = 1 upper = 3
      number = ls_resp-meta-row_count ).
  endmethod.
ENDCLASS.
