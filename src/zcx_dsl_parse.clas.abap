class ZCX_DSL_PARSE definition
  public
  inheriting from CX_STATIC_CHECK
  final
  create public .

  public section.

    interfaces IF_T100_MESSAGE .

    constants:
      BEGIN OF gc_malformed_json,
        msgid TYPE symsgid VALUE 'ZDSL',
        msgno TYPE symsgno VALUE '001',
        attr1 TYPE scx_attrname VALUE 'MV_ATTR1',
        attr2 TYPE scx_attrname VALUE '',
        attr3 TYPE scx_attrname VALUE '',
        attr4 TYPE scx_attrname VALUE '',
      END OF gc_malformed_json .
    constants:
      BEGIN OF gc_unsupported_version,
        msgid TYPE symsgid VALUE 'ZDSL',
        msgno TYPE symsgno VALUE '002',
        attr1 TYPE scx_attrname VALUE 'MV_ATTR1',
        attr2 TYPE scx_attrname VALUE '',
        attr3 TYPE scx_attrname VALUE '',
        attr4 TYPE scx_attrname VALUE '',
      END OF gc_unsupported_version .
    constants:
      BEGIN OF gc_missing_field,
        msgid TYPE symsgid VALUE 'ZDSL',
        msgno TYPE symsgno VALUE '003',
        attr1 TYPE scx_attrname VALUE 'MV_ATTR1',
        attr2 TYPE scx_attrname VALUE '',
        attr3 TYPE scx_attrname VALUE '',
        attr4 TYPE scx_attrname VALUE '',
      END OF gc_missing_field .
    constants:
      BEGIN OF gc_unknown_key,
        msgid TYPE symsgid VALUE 'ZDSL',
        msgno TYPE symsgno VALUE '004',
        attr1 TYPE scx_attrname VALUE 'MV_ATTR1',
        attr2 TYPE scx_attrname VALUE '',
        attr3 TYPE scx_attrname VALUE '',
        attr4 TYPE scx_attrname VALUE '',
      END OF gc_unknown_key .
    constants:
      BEGIN OF gc_entity_sources_conflict,
        msgid TYPE symsgid VALUE 'ZDSL',
        msgno TYPE symsgno VALUE '005',
        attr1 TYPE scx_attrname VALUE '',
        attr2 TYPE scx_attrname VALUE '',
        attr3 TYPE scx_attrname VALUE '',
        attr4 TYPE scx_attrname VALUE '',
      END OF gc_entity_sources_conflict .
    constants:
      BEGIN OF gc_missing_logic,
        msgid TYPE symsgid VALUE 'ZDSL',
        msgno TYPE symsgno VALUE '006',
        attr1 TYPE scx_attrname VALUE '',
        attr2 TYPE scx_attrname VALUE '',
        attr3 TYPE scx_attrname VALUE '',
        attr4 TYPE scx_attrname VALUE '',
      END OF gc_missing_logic .

    data MV_ERROR_CODE type ZDSL_DE_ECODE read-only .
    data MV_ATTR1 type STRING read-only .

    methods CONSTRUCTOR
      importing
        !TEXTID like IF_T100_MESSAGE=>T100KEY optional
        !PREVIOUS like PREVIOUS optional
        !MV_ERROR_CODE type ZDSL_DE_ECODE optional
        !MV_ATTR1 type STRING optional .
  protected section.
  private section.
ENDCLASS.



CLASS ZCX_DSL_PARSE IMPLEMENTATION.


  method CONSTRUCTOR.
    CALL METHOD SUPER->CONSTRUCTOR
      EXPORTING
        PREVIOUS = PREVIOUS.
    me->MV_ERROR_CODE = MV_ERROR_CODE.
    me->MV_ATTR1 = MV_ATTR1.
    CLEAR me->textid.
    IF textid IS INITIAL.
      IF_T100_MESSAGE~T100KEY = IF_T100_MESSAGE=>DEFAULT_TEXTID.
    ELSE.
      IF_T100_MESSAGE~T100KEY = TEXTID.
    ENDIF.
  endmethod.
ENDCLASS.
