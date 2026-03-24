*&---------------------------------------------------------------------*
*& Report ZDSL_SEED_CONFIG
*& Seeds ZJSON_DSL_CONFIG with default guardrail values
*& and ZJSON_DSL_ENTITY with the user_access entity
*&---------------------------------------------------------------------*
REPORT zdsl_seed_config.

PARAMETERS: p_reset TYPE abap_bool AS CHECKBOX DEFAULT ' '.

START-OF-SELECTION.

  IF p_reset = abap_true.
    DELETE FROM zjson_dsl_config WHERE config_key IS NOT INITIAL.
    DELETE FROM zjson_dsl_entity WHERE entity_name IS NOT INITIAL.
    WRITE: / 'Existing config and entity data cleared.'.
  ENDIF.

  " ─── Seed guardrail config ───
  DATA lt_config TYPE STANDARD TABLE OF zjson_dsl_config.
  lt_config = VALUE #(
    ( mandt = sy-mandt config_key = 'MAX_ROWS_ALLOWED'      config_value = '10000'  description = 'Hard cap on limit.rows' )
    ( mandt = sy-mandt config_key = 'MAX_TIMEOUT_SEC'       config_value = '30'     description = 'Query execution time limit' )
    ( mandt = sy-mandt config_key = 'WARN_ROWS_THRESHOLD'   config_value = '5000'   description = 'Row count warning threshold' )
    ( mandt = sy-mandt config_key = 'WARN_JOINS_THRESHOLD'  config_value = '3'      description = 'Join count warning threshold' )
    ( mandt = sy-mandt config_key = 'OFFSET_LARGE_TABLE_ROWS' config_value = '100000' description = 'Large table offset warning' )
    ( mandt = sy-mandt config_key = 'TOKEN_TTL_SECONDS'     config_value = '3600'   description = 'Bearer token validity (1 hour)' )
    ( mandt = sy-mandt config_key = 'AUDIT_RETENTION_DAYS'  config_value = '90'     description = 'Audit log retention in days' )
    ( mandt = sy-mandt config_key = 'WHITELIST_MODE'        config_value = 'OPEN'   description = 'STRICT or OPEN whitelist mode' )
  ).

  MODIFY zjson_dsl_config FROM TABLE lt_config.
  WRITE: / 'Config entries seeded:', lines( lt_config ).

  " ─── Seed user_access entity ───
  DATA ls_entity TYPE zjson_dsl_entity.
  ls_entity-mandt          = sy-mandt.
  ls_entity-entity_name    = 'user_access'.
  ls_entity-entity_version = '1.0'.
  ls_entity-description    = 'User master with role and auth object assignments'.
  ls_entity-active         = abap_true.
  ls_entity-entity_json    =
    '{"sources":[{"table":"USR02","alias":"u"}],' &&
    '"joins":[' &&
      '{"type":"left","target":{"table":"AGR_USERS","alias":"ru"},' &&
       '"on":{"logic":"AND","conditions":[' &&
         '{"left":"u.BNAME","op":"=","right":"ru.UNAME"},' &&
         '{"left":"u.MANDT","op":"=","right":"ru.MANDT"}]}},' &&
      '{"type":"left","target":{"table":"AGR_1251","alias":"auth"},' &&
       '"on":{"logic":"AND","conditions":[' &&
         '{"left":"ru.AGR_NAME","op":"=","right":"auth.ROLE"},' &&
         '{"left":"ru.MANDT","op":"=","right":"auth.MANDT"}]}}' &&
    '],' &&
    '"fields":[' &&
      '{"alias":"user","field":"u.BNAME","type":"STRING"},' &&
      '{"alias":"user_type","field":"u.USTYP","type":"STRING"},' &&
      '{"alias":"role","field":"ru.AGR_NAME","type":"STRING"},' &&
      '{"alias":"valid_from","field":"ru.FROM_DAT","type":"DATE"},' &&
      '{"alias":"valid_to","field":"ru.TO_DAT","type":"DATE"},' &&
      '{"alias":"auth_object","field":"auth.OBJECT","type":"STRING"}' &&
    ']}'.

  MODIFY zjson_dsl_entity FROM ls_entity.
  WRITE: / 'Entity "user_access" seeded.'.

  COMMIT WORK.
  WRITE: / 'Seed complete.'.
