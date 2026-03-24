class ZCX_DSL_SECURITY definition
  public
  inheriting from CX_STATIC_CHECK
  final
  create public .

  public section.

    interfaces IF_T100_MESSAGE .

    constants:
      BEGIN OF gc_sql_injection,
        msgid TYPE symsgid VALUE 'ZDSL',
        msgno TYPE symsgno VALUE '040',
        attr1 TYPE scx_attrname VALUE 'MV_ATTR1',
        attr2 TYPE scx_attrname VALUE '',
        attr3 TYPE scx_attrname VALUE '',
        attr4 TYPE scx_attrname VALUE '',
      END OF gc_sql_injection .
    constants:
      BEGIN OF gc_invalid_chars,
        msgid TYPE symsgid VALUE 'ZDSL',
        msgno TYPE symsgno VALUE '041',
        attr1 TYPE scx_attrname VALUE 'MV_ATTR1',
        attr2 TYPE scx_attrname VALUE '',
        attr3 TYPE scx_attrname VALUE '',
        attr4 TYPE scx_attrname VALUE '',
      END OF gc_invalid_chars .
    constants:
      BEGIN OF gc_invalid_operator,
        msgid TYPE symsgid VALUE 'ZDSL',
        msgno TYPE symsgno VALUE '042',
        attr1 TYPE scx_attrname VALUE 'MV_ATTR1',
        attr2 TYPE scx_attrname VALUE '',
        attr3 TYPE scx_attrname VALUE '',
        attr4 TYPE scx_attrname VALUE '',
      END OF gc_invalid_operator .
    constants:
      BEGIN OF gc_value_too_long,
        msgid TYPE symsgid VALUE 'ZDSL',
        msgno TYPE symsgno VALUE '043',
        attr1 TYPE scx_attrname VALUE '',
        attr2 TYPE scx_attrname VALUE '',
        attr3 TYPE scx_attrname VALUE '',
        attr4 TYPE scx_attrname VALUE '',
      END OF gc_value_too_long .

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



CLASS ZCX_DSL_SECURITY IMPLEMENTATION.


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
