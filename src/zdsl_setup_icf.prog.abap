*&---------------------------------------------------------------------*
*& Report ZDSL_SETUP_ICF
*& Registers ICF services for the DSL Engine
*&   /sap/zdsl/auth  → ZCL_HTTP_DSL_AUTH
*&   /sap/zdsl/query → ZCL_HTTP_DSL_HANDLER
*&---------------------------------------------------------------------*
REPORT zdsl_setup_icf.

PARAMETERS: p_unreg TYPE abap_bool AS CHECKBOX DEFAULT ' '.

DATA: ls_icf_serv  TYPE icfservice,
      ls_icf_docu  TYPE icfdocu,
      lv_parent    TYPE icfparguid,
      lv_nodeguid  TYPE icfnodguid,
      lv_icf_name  TYPE icfname,
      lt_handlertab TYPE icfhandtbl,
      ls_handler   LIKE LINE OF lt_handlertab,
      lv_url       TYPE string.

START-OF-SELECTION.

  IF p_unreg = abap_true.
    " ─── Unregister ───
    PERFORM unregister_service USING 'QUERY' 'ZDSL'.
    PERFORM unregister_service USING 'AUTH'  'ZDSL'.
    PERFORM unregister_service USING 'ZDSL'  'SAP'.
    WRITE: / 'ICF services unregistered. Deactivate manually in SICF if needed.'.
    RETURN.
  ENDIF.

  " ─── Step 1: Find the /sap/ parent node ───
  SELECT SINGLE icf_name icfnodguid FROM icfservice
    INTO (lv_icf_name, lv_parent)
    WHERE icf_name = 'SAP'
      AND icfparguid = cl_icf_tree=>icfguid_root.

  IF sy-subrc <> 0.
    WRITE: / 'ERROR: /sap/ ICF node not found. Check SICF.'.
    RETURN.
  ENDIF.
  WRITE: / 'Found /sap/ node:', lv_parent.

  " ─── Step 2: Create /sap/zdsl/ node ───
  DATA lv_zdsl_guid TYPE icfnodguid.

  SELECT SINGLE icfnodguid FROM icfservice
    INTO lv_zdsl_guid
    WHERE icf_name = 'ZDSL'
      AND icfparguid = lv_parent.

  IF sy-subrc <> 0.
    " Create the zdsl node
    CLEAR: ls_icf_serv, ls_icf_docu.
    ls_icf_serv-icf_name     = 'ZDSL'.
    ls_icf_serv-icfparguid   = lv_parent.
    ls_icf_serv-icf_cclnt    = 0.
    ls_icf_serv-icf_mclnt    = sy-mandt.
    ls_icf_docu-icf_docu     = 'DSL Engine Root Service'.

    CLEAR lt_handlertab.

    CALL FUNCTION 'ICFSERVICE_CREATE'
      EXPORTING
        icf_service   = ls_icf_serv
        icfdocu       = ls_icf_docu
        handlertable  = lt_handlertab
        icfactive     = 'X'
        package       = 'ZDL_JSON_DSL'
      IMPORTING
        icfnodeguid   = lv_zdsl_guid
      EXCEPTIONS
        already_exists = 1
        OTHERS         = 2.

    IF sy-subrc = 0.
      WRITE: / 'Created /sap/zdsl/ node:', lv_zdsl_guid.
    ELSEIF sy-subrc = 1.
      " Already exists, try to retrieve it
      SELECT SINGLE icfnodguid FROM icfservice
        INTO lv_zdsl_guid
        WHERE icf_name = 'ZDSL'
          AND icfparguid = lv_parent.
      WRITE: / '/sap/zdsl/ already exists:', lv_zdsl_guid.
    ELSE.
      WRITE: / 'ERROR creating /sap/zdsl/ node. RC:', sy-subrc.
      RETURN.
    ENDIF.
  ELSE.
    WRITE: / '/sap/zdsl/ already exists:', lv_zdsl_guid.
  ENDIF.

  " ─── Step 3: Create /sap/zdsl/auth ───
  PERFORM create_service USING lv_zdsl_guid 'AUTH' 'ZCL_HTTP_DSL_AUTH'
    'DSL Token Authentication Endpoint'.

  " ─── Step 4: Create /sap/zdsl/query ───
  PERFORM create_service USING lv_zdsl_guid 'QUERY' 'ZCL_HTTP_DSL_HANDLER'
    'DSL Query Execution Endpoint'.

  COMMIT WORK.
  WRITE: / ''.
  WRITE: / 'ICF setup complete. Verify in SICF:'.
  WRITE: / '  /sap/zdsl/auth  → ZCL_HTTP_DSL_AUTH'.
  WRITE: / '  /sap/zdsl/query → ZCL_HTTP_DSL_HANDLER'.
  WRITE: / ''.
  WRITE: / 'Test: https://<host>:<port>/sap/zdsl/auth should return 405 (POST only)'.

*&---------------------------------------------------------------------*
FORM create_service USING iv_parent    TYPE icfnodguid
                          iv_name      TYPE clike
                          iv_handler   TYPE clike
                          iv_docu      TYPE clike.

  DATA: ls_serv     TYPE icfservice,
        ls_docu     TYPE icfdocu,
        lt_handlers TYPE icfhandtbl,
        ls_handler  LIKE LINE OF lt_handlers,
        lv_guid     TYPE icfnodguid.

  " Check if already exists
  SELECT SINGLE icfnodguid FROM icfservice
    INTO lv_guid
    WHERE icf_name  = iv_name
      AND icfparguid = iv_parent.

  IF sy-subrc = 0.
    WRITE: / |  /sap/zdsl/{ to_lower( iv_name ) } already exists: { lv_guid }|.
    RETURN.
  ENDIF.

  CLEAR: ls_serv, ls_docu.
  ls_serv-icf_name    = iv_name.
  ls_serv-icfparguid  = iv_parent.
  ls_serv-icf_cclnt   = 0.
  ls_serv-icf_mclnt   = sy-mandt.
  ls_docu-icf_docu    = iv_docu.

  " Handler entry
  CLEAR ls_handler.
  ls_handler-icfhandler = iv_handler.
  APPEND ls_handler TO lt_handlers.

  CALL FUNCTION 'ICFSERVICE_CREATE'
    EXPORTING
      icf_service   = ls_serv
      icfdocu       = ls_docu
      handlertable  = lt_handlers
      icfactive     = 'X'
      package       = 'ZDL_JSON_DSL'
    IMPORTING
      icfnodeguid   = lv_guid
    EXCEPTIONS
      already_exists = 1
      OTHERS         = 2.

  IF sy-subrc = 0.
    WRITE: / |  Created /sap/zdsl/{ to_lower( iv_name ) }: { lv_guid }|.
  ELSEIF sy-subrc = 1.
    WRITE: / |  /sap/zdsl/{ to_lower( iv_name ) } already exists|.
  ELSE.
    WRITE: / |  ERROR creating /sap/zdsl/{ to_lower( iv_name ) }. RC: { sy-subrc }|.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
FORM unregister_service USING iv_name TYPE clike
                              iv_parent_name TYPE clike.

  DATA: lv_parent TYPE icfnodguid,
        lv_guid   TYPE icfnodguid.

  " Find parent
  IF iv_parent_name = 'SAP'.
    SELECT SINGLE icfnodguid FROM icfservice
      INTO lv_parent
      WHERE icf_name = 'SAP'
        AND icfparguid = cl_icf_tree=>icfguid_root.
  ELSE.
    SELECT SINGLE icfnodguid FROM icfservice
      INTO lv_parent
      WHERE icf_name = iv_parent_name.
  ENDIF.

  IF sy-subrc <> 0. RETURN. ENDIF.

  SELECT SINGLE icfnodguid FROM icfservice
    INTO lv_guid
    WHERE icf_name  = iv_name
      AND icfparguid = lv_parent.

  IF sy-subrc = 0.
    CALL FUNCTION 'ICFSERVICE_DELETE'
      EXPORTING
        icf_name    = CONV icfname( iv_name )
        icfparguid  = lv_parent
      EXCEPTIONS
        OTHERS      = 1.

    IF sy-subrc = 0.
      WRITE: / |  Deleted { iv_name }|.
    ENDIF.
  ENDIF.
ENDFORM.
