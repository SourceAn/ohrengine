/**
 * SelectorMatcherOhosTest — OhosTest (hypium) unit tests for SelectorMatcher (ENG-009)
 *
 * Covers: tag/class/id matching, descendant/child combinators,
 *         attribute selectors, pseudo-classes, and non-matching cases.
 */
import { describe, it, expect } from '@ohos/hypium';
import { SelectorMatcher } from 'ohrengine-ui-render';
import { DomNode, createElementNode, createTextNode } from 'ohrengine-common';

function makeElement(tag: string): DomNode {
  return createElementNode(tag);
}

function setAttr(el: DomNode, key: string, value: string): void {
  el.attributes[key] = value;
}

function appendChild(parent: DomNode, child: DomNode): DomNode {
  child.parent = parent;
  parent.children.push(child);
  return child;
}

export default function selectorMatcherTest() {
  describe('SelectorMatcherTest', () => {
    it('matches_simple_tag', 0, () => {
      const matcher: SelectorMatcher = new SelectorMatcher();
      const p: DomNode = makeElement('p');
      expect(matcher.matches('p', p)).assertTrue();
      expect(matcher.matches('div', p)).assertFalse();
    });

    it('matches_class_selector', 0, () => {
      const matcher: SelectorMatcher = new SelectorMatcher();
      const p: DomNode = makeElement('p');
      setAttr(p, 'class', 'warning highlight');
      expect(matcher.matches('.warning', p)).assertTrue();
      expect(matcher.matches('.highlight', p)).assertTrue();
      expect(matcher.matches('.missing', p)).assertFalse();
    });

    it('matches_id_selector', 0, () => {
      const matcher: SelectorMatcher = new SelectorMatcher();
      const p: DomNode = makeElement('p');
      setAttr(p, 'id', 'main');
      expect(matcher.matches('#main', p)).assertTrue();
      expect(matcher.matches('#other', p)).assertFalse();
    });

    it('matches_descendant_combinator', 0, () => {
      const matcher: SelectorMatcher = new SelectorMatcher();
      const div: DomNode = makeElement('div');
      const span: DomNode = makeElement('span');
      appendChild(div, span);
      expect(matcher.matches('div span', span)).assertTrue();
    });

    it('does_not_match_descendant_across_sibling', 0, () => {
      const matcher: SelectorMatcher = new SelectorMatcher();
      const div: DomNode = makeElement('div');
      const sibling: DomNode = makeElement('span');
      appendChild(div, makeElement('p'));
      appendChild(div, sibling);
      // div > p then sibling span: 'div span' requires span descendant of div (it is)
      expect(matcher.matches('div span', sibling)).assertTrue();
      // 'p span' should NOT match (p is not ancestor of span)
      expect(matcher.matches('p span', sibling)).assertFalse();
    });

    it('matches_child_combinator', 0, () => {
      const matcher: SelectorMatcher = new SelectorMatcher();
      const div: DomNode = makeElement('div');
      const span: DomNode = makeElement('span');
      appendChild(div, span);
      expect(matcher.matches('div > span', span)).assertTrue();
      const nested: DomNode = makeElement('b');
      appendChild(span, nested);
      // 'div > b' must be false: b is grandchild, not direct child
      expect(matcher.matches('div > b', nested)).assertFalse();
    });

    it('matches_attribute_selectors', 0, () => {
      const matcher: SelectorMatcher = new SelectorMatcher();
      const a: DomNode = makeElement('a');
      setAttr(a, 'href', 'https://example.com');
      setAttr(a, 'target', '_blank');
      expect(matcher.matches('a[href]', a)).assertTrue();
      expect(matcher.matches('a[href="https://example.com"]', a)).assertTrue();
      expect(matcher.matches('a[href^="https"]', a)).assertTrue();
      expect(matcher.matches('a[href$=".com"]', a)).assertTrue();
      expect(matcher.matches('a[href*="example"]', a)).assertTrue();
      expect(matcher.matches('a[title]', a)).assertFalse();
    });

    it('matches_pseudo_class', 0, () => {
      const matcher: SelectorMatcher = new SelectorMatcher();
      const li: DomNode = makeElement('li');
      // :first-child — standalone element without siblings
      expect(matcher.matches('li:first-child', li)).assertTrue();
      const p: DomNode = makeElement('p');
      expect(matcher.matches('p:last-child', p)).assertTrue();
    });

    it('returns_false_for_empty_selector', 0, () => {
      const matcher: SelectorMatcher = new SelectorMatcher();
      const p: DomNode = makeElement('p');
      expect(matcher.matches('', p)).assertFalse();
      expect(matcher.matches('   ', p)).assertFalse();
    });

    it('text_node_does_not_match_element_selector', 0, () => {
      const matcher: SelectorMatcher = new SelectorMatcher();
      const text: DomNode = createTextNode('hello');
      expect(matcher.matches('p', text)).assertFalse();
    });
  });
}
