class ZCL_HTTP_DSL_AUTH definition
  public
  final
  create public .

  public section.

    interfaces IF_HTTP_EXTENSION .

  private section.

    methods HANDLE_TOKEN_REQUEST
      importing
        !IO_SERVER type ref to IF_HTTP_SERVER .

    methods VALIDATE_CREDENTIALS
      importing
        !IV_CLIENT_ID type STRING
        !IV_SECRET type STRING
      exporting
        !EV_VALID type ABAP_BOOL
        !EV_SVC_USER type BNAME .

    methods GENERATE_TOKEN
      importing
        !IV_CLIENT_ID type STRING
        !IV_SVC_USER type BNAME
      returning
        value(RV_TOKEN) type STRING .

    methods GET_TOKEN_TTL
      returning
        value(RV_SECONDS) type I .

    methods HASH_SECRET
      importing
        !IV_SECRET type STRING
      returning
        value(RV_HASH) type STRING .

    methods SEND_JSON_RESPONSE
      importing
        !IO_SERVER type ref to IF_HTTP_SERVER
        !IV_STATUS type I
        !IV_JSON type STRING .
ENDCLASS.



CLASS ZCL_HTTP_DSL_AUTH IMPLEMENTATION.


  method IF_HTTP_EXTENSION~HANDLE_REQUEST.
    DATA(lv_method) = server->request->get_header_field( name = '~request_method' ).

    IF lv_method <> 'POST'.
      send_json_response(
        io_server = server
        iv_status = 405
        iv_json   = '{"errors":[{"code":"DSL_AUTH_001","message":"Method not allowed - use POST"}]}' ).
      RETURN.
    ENDIF.

    handle_token_request( server ).
  endmethod.


  method HANDLE_TOKEN_REQUEST.
    DATA lv_valid    TYPE abap_bool.
    DATA lv_svc_user TYPE syuname.

    " Read request body
    DATA(lv_body) = io_server->request->get_cdata( ).

    " Parse client_id and client_secret from JSON body
    DATA(lo_parser) = NEW zcl_json_dsl_parser( ).
    DATA(lv_cid_json) = lo_parser->json_extract_member( iv_json = lv_body iv_key = 'client_id' ).
    DATA(lv_sec_json) = lo_parser->json_extract_member( iv_json = lv_body iv_key = 'client_secret' ).
    " Strip surrounding quotes from JSON string values
    DATA(lv_client_id) = lv_cid_json.
    DATA(lv_secret)    = lv_sec_json.
    REPLACE ALL OCCURRENCES OF '"' IN lv_client_id WITH ''.
    REPLACE ALL OCCURRENCES OF '"' IN lv_secret WITH ''.

    IF lv_client_id IS INITIAL OR lv_secret IS INITIAL.
      send_json_response(
        io_server = io_server
        iv_status = 400
        iv_json   = '{"errors":[{"code":"DSL_AUTH_002","message":"Missing client_id or client_secret"}]}' ).
      RETURN.
    ENDIF.

    " Validate credentials against ZJSON_DSL_CLNT
    validate_credentials(
      EXPORTING iv_client_id = lv_client_id iv_secret = lv_secret
      IMPORTING ev_valid = lv_valid ev_svc_user = lv_svc_user ).

    IF lv_valid = abap_false.
      send_json_response(
        io_server = io_server
        iv_status = 401
        iv_json   = '{"errors":[{"code":"DSL_AUTH_003","message":"Invalid client_id or client_secret"}]}' ).
      RETURN.
    ENDIF.

    " Generate token
    DATA(lv_token) = generate_token( iv_client_id = lv_client_id iv_svc_user = lv_svc_user ).
    DATA(lv_ttl) = get_token_ttl( ).

    " Return token response
    DATA(lv_resp) = '{"access_token":"' && lv_token
                 && '","token_type":"Bearer","expires_in":'
                 && lv_ttl && '}'.
    send_json_response(
      io_server = io_server
      iv_status = 200
      iv_json   = lv_resp ).
  endmethod.


  method VALIDATE_CREDENTIALS.
    ev_valid = abap_false.
    CLEAR ev_svc_user.

    DATA(lv_hash) = hash_secret( iv_secret ).

    SELECT SINGLE svc_user INTO ev_svc_user
      FROM zjson_dsl_clnt
      WHERE client_id   = iv_client_id
        AND secret_hash = lv_hash
        AND active      = abap_true
        AND valid_to   >= sy-datum.

    IF sy-subrc = 0.
      ev_valid = abap_true.
    ENDIF.
  endmethod.


  method GENERATE_TOKEN.
    " Build a simple signed token: base64({ client_id, svc_user, issued_at, expires_at })
    " In production, use a proper JWT library or SAP's token service
    DATA lv_ts TYPE timestamp.
    GET TIME STAMP FIELD lv_ts.

    DATA(lv_ttl) = get_token_ttl( ).
    DATA(lv_payload) = '{"client_id":"' && iv_client_id
                    && '","svc_user":"' && iv_svc_user
                    && '","issued_at":' && lv_ts
                    && ',"ttl":' && lv_ttl && '}'.

    DATA lv_xstr TYPE xstring.
    lv_xstr = cl_abap_codepage=>convert_to( lv_payload ).

    CALL FUNCTION 'SCMS_BASE64_ENCODE_STR'
      EXPORTING
        input  = lv_xstr
      IMPORTING
        output = rv_token.
  endmethod.


  method GET_TOKEN_TTL.
    DATA lv_val TYPE zdsl_de_cfval.
    SELECT SINGLE config_value INTO lv_val
      FROM zjson_dsl_config
      WHERE config_key = 'TOKEN_TTL_SECONDS'.

    IF sy-subrc = 0 AND lv_val IS NOT INITIAL.
      rv_seconds = lv_val.
    ELSE.
      rv_seconds = 3600. " default 1 hour
    ENDIF.
  endmethod.


  method HASH_SECRET.
    " SHA-256 hash of the secret
    DATA lv_xstr TYPE xstring.
    lv_xstr = cl_abap_codepage=>convert_to( iv_secret ).

    TRY.
        cl_abap_message_digest=>calculate_hash_for_raw(
          EXPORTING
            if_algorithm = 'SHA256'
            if_data      = lv_xstr
          IMPORTING
            ef_hashstring = rv_hash ).
      CATCH cx_abap_message_digest.
        CLEAR rv_hash.
    ENDTRY.
  endmethod.


  method SEND_JSON_RESPONSE.
    io_server->response->set_status( code = iv_status reason = '' ).
    io_server->response->set_header_field(
      name  = 'Content-Type'
      value = 'application/json' ).
    io_server->response->set_cdata( data = iv_json ).
  endmethod.
ENDCLASS.
