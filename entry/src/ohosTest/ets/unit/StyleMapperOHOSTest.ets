/**
 * StyleMapperOhosTest — OhosTest (hypium) unit tests for StyleMapper
 *
 * Verifies computeStyle returns correct defaults per tag from UA stylesheet.
 */
import { describe, it, expect } from '@ohos/hypium';
import { StyleMapper } from 'ohrengine-ui-render';
import {
  CssStyleSet, CssDisplay, CssFontStyle, CssFontWeight, CssTextDecoration,
  createDefaultCssStyleSet
} from 'ohrengine-common';
import {
  DomNode, createElementNode, createTextNode
} from 'ohrengine-common';

export default function styleMapperTest() {
  describe('StyleMapperTest', () => {
    it('p_tag_has_block_display', 0, () => {
      const mapper: StyleMapper = new StyleMapper();
      const element: DomNode = createElementNode('p');
      const style: CssStyleSet = mapper.computeStyle(element, undefined, 'p');
      expect(style.display).assertEqual(CssDisplay.BLOCK);
    });

    it('h1_tag_has_block_display', 0, () => {
      const mapper: StyleMapper = new StyleMapper();
      const element: DomNode = createElementNode('h1');
      const style: CssStyleSet = mapper.computeStyle(element, undefined, 'h1');
      expect(style.display).assertEqual(CssDisplay.BLOCK);
    });

    it('em_tag_has_italic_font_style', 0, () => {
      const mapper: StyleMapper = new StyleMapper();
      const element: DomNode = createElementNode('em');
      const style: CssStyleSet = mapper.computeStyle(element, undefined, 'em');
      expect(style.fontStyle).assertEqual(CssFontStyle.ITALIC);
    });

    it('strong_tag_has_bold_font_weight', 0, () => {
      const mapper: StyleMapper = new StyleMapper();
      const element: DomNode = createElementNode('strong');
      const style: CssStyleSet = mapper.computeStyle(element, undefined, 'strong');
      expect(style.fontWeight).assertEqual(CssFontWeight.BOLD);
    });

    it('a_tag_has_underline_decoration', 0, () => {
      const mapper: StyleMapper = new StyleMapper();
      const element: DomNode = createElementNode('a');
      const style: CssStyleSet = mapper.computeStyle(element, undefined, 'a');
      expect(style.textDecoration).assertEqual(CssTextDecoration.UNDERLINE);
    });

    it('text_node_inherits_from_parent', 0, () => {
      const mapper: StyleMapper = new StyleMapper();
      const parentStyle: CssStyleSet = createDefaultCssStyleSet();
      const textNode: DomNode = createTextNode('hello');
      const style: CssStyleSet = mapper.computeStyle(textNode, parentStyle, '#text');
      expect(style.display).assertEqual(CssDisplay.INLINE);
    });

    it('body_accepts_undefined_parent', 0, () => {
      const mapper: StyleMapper = new StyleMapper();
      const element: DomNode = createElementNode('body');
      const style: CssStyleSet = mapper.computeStyle(element, undefined, 'body');
      expect(style.display).assertEqual(CssDisplay.BLOCK);
    });

    it('multiple_tags_all_return_valid_styles', 0, () => {
      const mapper: StyleMapper = new StyleMapper();
      const parentStyle: CssStyleSet = createDefaultCssStyleSet();
      const tags: string[] = ['p', 'div', 'h1', 'h2', 'span', 'a', 'em', 'strong', 'i', 'b', 'u', 'pre', 'blockquote'];
      for (let i = 0; i < tags.length; i++) {
        const element: DomNode = createElementNode(tags[i]);
        const style: CssStyleSet = mapper.computeStyle(element, parentStyle, tags[i]);
        expect(style !== null).assertTrue();
      }
    });

    it('author_style_overrides_user_agent', 0, () => {
      const mapper: StyleMapper = new StyleMapper();
      mapper.loadAuthorStyleSheet('p { display: inline; }');
      const element: DomNode = createElementNode('p');
      const style: CssStyleSet = mapper.computeStyle(element, undefined, 'p');
      expect(style.display).assertEqual(CssDisplay.INLINE);
    });

    it('class_specificity_beats_tag_specificity', 0, () => {
      const mapper: StyleMapper = new StyleMapper();
      mapper.loadAuthorStyleSheet('p { color: red; } .special { color: blue; }');
      const element: DomNode = createElementNode('p');
      element.attributes['class'] = 'special';
      const style: CssStyleSet = mapper.computeStyle(element, undefined, 'p');
      expect(style.color).assertEqual('blue');
    });

    it('important_declaration_wins', 0, () => {
      const mapper: StyleMapper = new StyleMapper();
      mapper.loadAuthorStyleSheet('.special { color: blue !important; } p { color: red; }');
      const element: DomNode = createElementNode('p');
      element.attributes['class'] = 'special';
      const style: CssStyleSet = mapper.computeStyle(element, undefined, 'p');
      expect(style.color).assertEqual('blue');
    });

    it('inherited_style_propagates_to_child', 0, () => {
      const mapper: StyleMapper = new StyleMapper();
      mapper.loadAuthorStyleSheet('div { color: green; }');
      const parent: DomNode = createElementNode('div');
      const parentStyle: CssStyleSet = mapper.computeStyle(parent, undefined, 'div');
      const child: DomNode = createElementNode('span');
      const childStyle: CssStyleSet = mapper.computeStyle(child, parentStyle, 'span');
      expect(childStyle.color).assertEqual('green');
    });

    it('later_source_order_wins_on_equal_specificity', 0, () => {
      const mapper: StyleMapper = new StyleMapper();
      mapper.loadAuthorStyleSheet('.a { color: red; } .b { color: blue; }');
      const element: DomNode = createElementNode('p');
      element.attributes['class'] = 'a b';
      const style: CssStyleSet = mapper.computeStyle(element, undefined, 'p');
      // .b 声明在后 → 同特异性时后者覆盖前者
      expect(style.color).assertEqual('blue');
    });
  });
}
