/**
 * CSS 属性枚举和类型定义
 * 参考：crengine cssdef.h
 * CoolReader engine 的 CSS 子集枚举定义
 */

// ============ display 属性 ============
export enum CssDisplay {
  INHERIT = 0,
  RUBY,
  RUN_IN,
  INLINE,
  BLOCK,
  LIST_ITEM_LEGACY,
  LIST_ITEM_BLOCK,
  INLINE_BLOCK,
  INLINE_TABLE,
  TABLE,
  TABLE_ROW_GROUP,
  TABLE_HEADER_GROUP,
  TABLE_FOOTER_GROUP,
  TABLE_ROW,
  TABLE_COLUMN_GROUP,
  TABLE_COLUMN,
  TABLE_CELL,
  TABLE_CAPTION,
  FLEX,
  INLINE_FLEX,
  NONE
}

// ============ white-space 属性 ============
export enum CssWhiteSpace {
  INHERIT = 0,
  NORMAL,
  NOWRAP,
  PRE_LINE,
  PRE,
  PRE_WRAP,
  BREAK_SPACES
}

// ============ text-align 属性 ============
export enum CssTextAlign {
  INHERIT = 0,
  LEFT,
  RIGHT,
  CENTER,
  JUSTIFY,
  START,
  END,
  AUTO,
  LEFT_IF_NOT_FIRST,
  RIGHT_IF_NOT_FIRST,
  CENTER_IF_NOT_FIRST,
  JUSTIFY_IF_NOT_FIRST,
  START_IF_NOT_FIRST,
  END_IF_NOT_FIRST
}

// ============ vertical-align 属性 ============
export enum CssVerticalAlign {
  INHERIT = 0,
  BASELINE,
  SUB,
  SUPER,
  TOP,
  TEXT_TOP,
  MIDDLE,
  BOTTOM,
  TEXT_BOTTOM
}

// ============ text-decoration 属性 ============
export enum CssTextDecoration {
  INHERIT = 0,
  NONE = 1,
  UNDERLINE = 2,
  OVERLINE = 3,
  LINE_THROUGH = 4,
  BLINK = 5
}

// ============ text-transform 属性 ============
export enum CssTextTransform {
  INHERIT = 0,
  NONE = 1,
  UPPERCASE = 2,
  LOWERCASE = 3,
  CAPITALIZE = 4,
  FULL_WIDTH = 5
}

// ============ hyphenate 属性 ============
export enum CssHyphenate {
  INHERIT = 0,
  NONE = 1,
  AUTO = 2
}

// ============ font-style 属性 ============
export enum CssFontStyle {
  INHERIT = 0,
  NORMAL,
  ITALIC,
  OBLIQUE
}

// ============ font-weight 属性 ============
export enum CssFontWeight {
  INHERIT = 0,
  NORMAL,
  BOLD,
  BOLDER,
  LIGHTER,
  W_100,
  W_200,
  W_300,
  W_400,
  W_500,
  W_600,
  W_700,
  W_800,
  W_900
}

// ============ font-family 属性 ============
export enum CssFontFamily {
  INHERIT = 0,
  SERIF,
  SANS_SERIF,
  CURSIVE,
  FANTASY,
  MONOSPACE
}

// ============ page-break 属性 ============
export enum CssPageBreak {
  INHERIT = 0,
  AUTO,
  AVOID,
  ALWAYS,
  LEFT,
  RIGHT,
  PAGE,
  RECTO,
  VERSO
}

// ============ list-style-type 属性 ============
export enum CssListStyleType {
  INHERIT = 0,
  DISC,
  CIRCLE,
  SQUARE,
  DECIMAL,
  LOWER_ROMAN,
  UPPER_ROMAN,
  LOWER_ALPHA,
  UPPER_ALPHA,
  NONE
}

// ============ list-style-position 属性 ============
export enum CssListStylePosition {
  INHERIT = 0,
  INSIDE,
  OUTSIDE
}

// ============ CSS 长度值类型 ============
export enum CssValueType {
  INHERITED = 0,
  UNSPECIFIED,
  PX,
  IN,
  CM,
  MM,
  PT,
  PC,
  EM,
  EX,
  CH,
  REM,
  VW,
  VH,
  VMIN,
  VMAX,
  PERCENT,
  SCREEN_PX,
  COLOR
}

// ============ border-style 属性 ============
export enum CssBorderStyle {
  SOLID = 0,
  DOTTED,
  DASHED,
  DOUBLE,
  GROOVE,
  RIDGE,
  INSET,
  OUTSET,
  NONE
}

// ============ background-repeat 属性 ============
export enum CssBackgroundRepeat {
  REPEAT = 0,
  REPEAT_X,
  REPEAT_Y,
  NO_REPEAT,
  INITIAL,
  INHERIT,
  NONE
}

// ============ background-position 属性 ============
export enum CssBackgroundPosition {
  LEFT_TOP = 0,
  LEFT_CENTER,
  LEFT_BOTTOM,
  RIGHT_TOP,
  RIGHT_CENTER,
  RIGHT_BOTTOM,
  CENTER_TOP,
  CENTER_CENTER,
  CENTER_BOTTOM,
  INITIAL,
  INHERIT,
  NONE
}

// ============ border-collapse 属性 ============
export enum CssBorderCollapse {
  SEPARATE = 0,
  COLLAPSE,
  INITIAL,
  INHERIT,
  NONE
}

// ============ float 属性 ============
export enum CssFloat {
  INHERIT = 0,
  NONE,
  LEFT,
  RIGHT
}

// ============ clear 属性 ============
export enum CssClear {
  INHERIT = 0,
  NONE,
  LEFT,
  RIGHT,
  BOTH
}

// ============ direction 属性 ============
export enum CssDirection {
  INHERIT = 0,
  UNSET,
  LTR,
  RTL
}

// ============ visibility 属性 ============
export enum CssVisibility {
  INHERIT = 0,
  VISIBLE,
  HIDDEN,
  COLLAPSE
}

// ============ line-break 属性 ============
export enum CssLineBreak {
  INHERIT = 0,
  AUTO,
  NORMAL,
  LOOSE,
  STRICT,
  ANYWHERE
}

// ============ word-break 属性 ============
export enum CssWordBreak {
  INHERIT = 0,
  NORMAL,
  BREAK_WORD,
  BREAK_ALL,
  KEEP_ALL
}

// ============ 通用特殊值 ============
export enum CssGenericValue {
  AUTO = -1,
  NORMAL = -2,
  TRANSPARENT = -3,
  CURRENTCOLOR = -4,
  CONTAIN = -5,
  COVER = -6,
  NONE = -7
}

// ============ CSS 长度值结构 ============
export interface CssLength {
  type: CssValueType;
  value: number; // 值 * 256（允许小数 px 和 %），除 css_val_screen_px 外
}

export function createCssLength(type: CssValueType, value: number): CssLength {
  return { type: type, value: value };
}

export function createCssLengthPx(pxValue: number): CssLength {
  return { type: CssValueType.SCREEN_PX, value: pxValue };
}

// ============ CSS 属性集合 ============
export interface CssStyleSet {
  display: CssDisplay;
  whiteSpace: CssWhiteSpace;
  textAlign: CssTextAlign;
  verticalAlign: CssVerticalAlign;
  textDecoration: CssTextDecoration;
  textTransform: CssTextTransform;
  hyphenate: CssHyphenate;
  fontStyle: CssFontStyle;
  fontWeight: CssFontWeight;
  fontFamily: CssFontFamily;
  fontSize: CssLength;
  lineHeight: CssLength;
  color: string | undefined;
  backgroundColor: string | undefined;
  marginTop: CssLength;
  marginRight: CssLength;
  marginBottom: CssLength;
  marginLeft: CssLength;
  paddingTop: CssLength;
  paddingRight: CssLength;
  paddingBottom: CssLength;
  paddingLeft: CssLength;
  borderTopWidth: CssLength;
  borderRightWidth: CssLength;
  borderBottomWidth: CssLength;
  borderLeftWidth: CssLength;
  borderTopStyle: CssBorderStyle;
  borderRightStyle: CssBorderStyle;
  borderBottomStyle: CssBorderStyle;
  borderLeftStyle: CssBorderStyle;
  borderTopColor: string | undefined;
  borderRightColor: string | undefined;
  borderBottomColor: string | undefined;
  borderLeftColor: string | undefined;
  pageBreakBefore: CssPageBreak;
  pageBreakAfter: CssPageBreak;
  pageBreakInside: CssPageBreak;
  float: CssFloat;
  clear: CssClear;
  direction: CssDirection;
  visibility: CssVisibility;
  lineBreak: CssLineBreak;
  wordBreak: CssWordBreak;
  orphans: number | undefined;
  widows: number | undefined;
  textIndent: CssLength;
  width: CssLength;
  height: CssLength;
  minWidth: CssLength;
  maxWidth: CssLength;
  minHeight: CssLength;
  maxHeight: CssLength;
  opacity: number;
  textOverflow: string;
  overflow: string;
  rubyPosition?: string;  // 'over' | 'under'
  rubyAlign?: string;     // 'auto' | 'start' | 'center' | 'space-between'
  fontSynthesis?: string; // 'none' | 'weight' | 'style' | 'weight style'
  counterReset?: string;      // counter-reset: chapter 0 section 0
  counterIncrement?: string;  // counter-increment: section
  listStyleImage?: string;    // list-style-image: url(...)
  listStyleType?: string;     // list-style-type: disc | circle | square | decimal | ...
  markerFontSize?: string;    // ::marker { font-size } — CSS value string
  markerColor?: string;       // ::marker { color }
}

export function createDefaultCssStyleSet(): CssStyleSet {
  return {
    display: CssDisplay.INLINE,
    whiteSpace: CssWhiteSpace.NORMAL,
    textAlign: CssTextAlign.INHERIT,
    verticalAlign: CssVerticalAlign.BASELINE,
    textDecoration: CssTextDecoration.NONE,
    textTransform: CssTextTransform.NONE,
    hyphenate: CssHyphenate.AUTO,
    fontStyle: CssFontStyle.NORMAL,
    fontWeight: CssFontWeight.NORMAL,
    fontFamily: CssFontFamily.SERIF,
    fontSize: createCssLength(CssValueType.PT, 12 * 256),
    lineHeight: createCssLength(CssValueType.UNSPECIFIED, CssGenericValue.NORMAL),
    color: undefined,
    backgroundColor: undefined,
    marginTop: createCssLengthPx(0),
    marginRight: createCssLengthPx(0),
    marginBottom: createCssLengthPx(0),
    marginLeft: createCssLengthPx(0),
    paddingTop: createCssLengthPx(0),
    paddingRight: createCssLengthPx(0),
    paddingBottom: createCssLengthPx(0),
    paddingLeft: createCssLengthPx(0),
    borderTopWidth: createCssLengthPx(0),
    borderRightWidth: createCssLengthPx(0),
    borderBottomWidth: createCssLengthPx(0),
    borderLeftWidth: createCssLengthPx(0),
    borderTopStyle: CssBorderStyle.NONE,
    borderRightStyle: CssBorderStyle.NONE,
    borderBottomStyle: CssBorderStyle.NONE,
    borderLeftStyle: CssBorderStyle.NONE,
    borderTopColor: undefined,
    borderRightColor: undefined,
    borderBottomColor: undefined,
    borderLeftColor: undefined,
    pageBreakBefore: CssPageBreak.AUTO,
    pageBreakAfter: CssPageBreak.AUTO,
    pageBreakInside: CssPageBreak.AUTO,
    float: CssFloat.NONE,
    clear: CssClear.NONE,
    direction: CssDirection.LTR,
    visibility: CssVisibility.VISIBLE,
    lineBreak: CssLineBreak.AUTO,
    wordBreak: CssWordBreak.NORMAL,
    orphans: undefined,
    widows: undefined,
    textIndent: createCssLengthPx(0),
    width: createCssLength(CssValueType.UNSPECIFIED, 0),
    height: createCssLength(CssValueType.UNSPECIFIED, 0),
    minWidth: createCssLength(CssValueType.UNSPECIFIED, 0),
    maxWidth: createCssLength(CssValueType.UNSPECIFIED, 0),
    minHeight: createCssLength(CssValueType.UNSPECIFIED, 0),
    maxHeight: createCssLength(CssValueType.UNSPECIFIED, 0),
    opacity: 1.0,
    textOverflow: 'clip',
    overflow: 'visible',
    rubyPosition: undefined,
    rubyAlign: undefined,
    fontSynthesis: 'weight style',
    counterReset: undefined,
    counterIncrement: undefined,
    listStyleImage: undefined,
    listStyleType: undefined,
    markerFontSize: undefined,
    markerColor: undefined
  };
}
