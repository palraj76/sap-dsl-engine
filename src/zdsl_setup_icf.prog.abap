*&---------------------------------------------------------------------*
*& Report ZDSL_SETUP_ICF
*& Registers ICF services for the DSL Engine
*&   /sap/zdsl/auth    → ZCL_HTTP_DSL_AUTH
*&   /sap/zdsl/query   → ZCL_HTTP_DSL_HANDLER
*&   /sap/zdsl/console → ZCL_HTTP_DSL_CONSOLE  (optional, see P_CONS)
*& Nodes that already exist are left untouched. New nodes are created with
*& CL_ICF_TREE=>INSERT_NODE, active, in package ZDL_JSON_DSL; the method asks
*& for a transport request.
*&---------------------------------------------------------------------*
REPORT zdsl_setup_icf.

PARAMETERS: p_unreg TYPE abap_bool AS CHECKBOX DEFAULT ' ',
            " Query console for logged-on users. Leave it off on systems where
            " people should not run ad-hoc queries.
            p_cons  TYPE abap_bool AS CHECKBOX DEFAULT 'X'.

CONSTANTS gc_package TYPE devclass VALUE 'ZDL_JSON_DSL'.

START-OF-SELECTION.

  IF p_unreg = abap_true.
    " Deleting ICF nodes is left to SICF on purpose: it is rare, needs a
    " transport, and SICF shows exactly what is removed.
    WRITE: / 'To remove the DSL services, open SICF → default_host/sap/zdsl'.
    WRITE: / 'and delete CONSOLE, QUERY and AUTH (then ZDSL) with right-click → Delete Service.'.
    RETURN.
  ENDIF.

  " ─── Step 1: Find the /sap/ parent node (root → DEFAULT_HOST → SAP) ───
  DATA lv_sap_guid TYPE icfnodguid.
  PERFORM get_sap_node CHANGING lv_sap_guid.
  IF lv_sap_guid IS INITIAL.
    WRITE: / 'ERROR: /sap/ ICF node not found under DEFAULT_HOST. Check SICF.'.
    RETURN.
  ENDIF.
  WRITE: / 'Found /sap/ node:', lv_sap_guid.

  " ─── Step 2: /sap/zdsl/ (container node, no handler) ───
  DATA lv_zdsl_guid TYPE icfnodguid.
  PERFORM create_service USING lv_sap_guid 'ZDSL' '' 'DSL Engine Root Service'
                         CHANGING lv_zdsl_guid.
  IF lv_zdsl_guid IS INITIAL.
    WRITE: / 'ERROR: /sap/zdsl/ could not be created - stopping.'.
    RETURN.
  ENDIF.

  " ─── Steps 3-5: services under /sap/zdsl/ ───
  DATA lv_guid TYPE icfnodguid.
  PERFORM create_service USING lv_zdsl_guid 'AUTH' 'ZCL_HTTP_DSL_AUTH'
    'DSL Token Authentication Endpoint' CHANGING lv_guid.
  PERFORM create_service USING lv_zdsl_guid 'QUERY' 'ZCL_HTTP_DSL_HANDLER'
    'DSL Query Execution Endpoint' CHANGING lv_guid.

  " Created without logon data, so the standard SAP logon applies and every
  " query runs as the person who opened the page.
  IF p_cons = abap_true.
    PERFORM create_service USING lv_zdsl_guid 'CONSOLE' 'ZCL_HTTP_DSL_CONSOLE'
      'DSL Query Console (logged-on users)' CHANGING lv_guid.
  ENDIF.

  WRITE: / ''.
  WRITE: / 'ICF setup finished. Verify in SICF:'.
  WRITE: / '  /sap/zdsl/auth    → ZCL_HTTP_DSL_AUTH'.
  WRITE: / '  /sap/zdsl/query   → ZCL_HTTP_DSL_HANDLER'.
  IF p_cons = abap_true.
    WRITE: / '  /sap/zdsl/console → ZCL_HTTP_DSL_CONSOLE (must NOT have fixed logon data)'.
  ENDIF.
  WRITE: / ''.
  WRITE: / 'Test: https://<host>:<port>/sap/zdsl/auth should return 405 (POST only)'.

*&---------------------------------------------------------------------*
*& Create one ICF node under IV_PARENT unless it already exists.
*& CV_GUID returns the node's GUID (existing or new), initial on failure.
*&---------------------------------------------------------------------*
FORM create_service USING    iv_parent  TYPE icfnodguid
                             iv_name    TYPE clike
                             iv_handler TYPE clike
                             iv_docu    TYPE clike
                    CHANGING cv_guid    TYPE icfnodguid.

  DATA: lv_name     TYPE icfname,
        lv_parent   TYPE icfparguid,
        ls_docu     TYPE icfdocu,
        lt_handlers TYPE icfhndlist,
        lv_trkorr   TYPE trkorr.
  FIELD-SYMBOLS: <ls_handler> TYPE any,
                 <lv_handler> TYPE any.

  CLEAR cv_guid.
  lv_name   = iv_name.
  lv_parent = iv_parent.
  ls_docu-icf_docu = iv_docu.

  SELECT SINGLE icfnodguid FROM icfservice
    INTO cv_guid
    WHERE icf_name   = lv_name
      AND icfparguid = lv_parent.
  IF sy-subrc = 0.
    WRITE: / |  { lv_name } already exists ({ cv_guid }) - left unchanged|.
    RETURN.
  ENDIF.

  " Handler list. Works whether a line of ICFHNDLIST is the handler name
  " itself or a structure with component ICFHANDLER.
  IF iv_handler IS NOT INITIAL.
    APPEND INITIAL LINE TO lt_handlers ASSIGNING <ls_handler>.
    ASSIGN COMPONENT 'ICFHANDLER' OF STRUCTURE <ls_handler> TO <lv_handler>.
    IF sy-subrc = 0.
      <lv_handler> = iv_handler.
    ELSE.
      <ls_handler> = iv_handler.
    ENDIF.
  ENDIF.

  cl_icf_tree=>insert_node(
    EXPORTING
      icf_name    = lv_name
      icfparguid  = lv_parent
      icfdocu     = ls_docu
      icfhandlst  = lt_handlers
      icfactive   = 'X'
      package     = gc_package
      application = space
    IMPORTING
      icfnodguid  = cv_guid
    CHANGING
      transport   = lv_trkorr
    EXCEPTIONS
      OTHERS      = 1 ).

  IF sy-subrc = 0 AND cv_guid IS NOT INITIAL.
    WRITE: / |  Created { lv_name } ({ cv_guid }), transport { lv_trkorr }|.
  ELSE.
    WRITE: / |  ERROR creating { lv_name } (INSERT_NODE sy-subrc { sy-subrc }).|,
           / |  Create it in SICF instead: right-click the parent → New Sub-Element.|.
    CLEAR cv_guid.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& The ICF tree is root → DEFAULT_HOST → SAP → ZDSL. The root GUID is the
*& parent of DEFAULT_HOST, not of SAP, so /sap/ must be found in two steps.
*&---------------------------------------------------------------------*
FORM get_sap_node CHANGING cv_guid TYPE icfnodguid.

  DATA lv_host TYPE icfnodguid.

  CLEAR cv_guid.
  SELECT SINGLE icfnodguid FROM icfservice
    INTO lv_host
    WHERE icf_name   = 'DEFAULT_HOST'
      AND icfparguid = cl_icf_tree=>if_icf_tree~co_rootguid.
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  SELECT SINGLE icfnodguid FROM icfservice
    INTO cv_guid
    WHERE icf_name   = 'SAP'
      AND icfparguid = lv_host.
ENDFORM.
