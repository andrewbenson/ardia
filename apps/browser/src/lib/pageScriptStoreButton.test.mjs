import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const script = readFileSync(new URL("../../../../packages/ardiacore/ios/page_script.js", import.meta.url), "utf8");
const start = script.indexOf("  const isWebStorePage = ");
const end = script.indexOf("  const StoreObserver = ", start);
assert.ok(start > 0 && end > start, "page_script.js has the Web Store button block");
const renameStoreButtonFor = new Function(`${script.slice(start, end)}return renameStoreButtonFor;`)();

const STORE = "https://chromewebstore.google.com/detail/jam/iohjgamcilhbgmhbnllfolmkmmekfmci";

class Text {
  constructor(value) {
    this.nodeValue = value;
    this.childNodes = [];
    this.parentElement = null;
  }
  get nodeType() {
    return 3;
  }
  get textContent() {
    return this.nodeValue;
  }
}

class Element {
  constructor(tag, children = []) {
    this.tag = tag;
    this.childNodes = [];
    this.parentElement = null;
    for (const child of children) this.append(child);
  }
  get nodeType() {
    return 1;
  }
  append(child) {
    const node = typeof child === "string" ? new Text(child) : child;
    node.parentElement = this;
    this.childNodes.push(node);
    return node;
  }
  replaceChildren(...children) {
    this.childNodes = [];
    for (const child of children) this.append(child);
  }
  get textContent() {
    return this.childNodes.map((c) => c.textContent).join("");
  }
  descendants() {
    return this.childNodes.filter((c) => c.nodeType === 1).flatMap((c) => [c, ...c.descendants()]);
  }
  querySelectorAll(selector) {
    const chain = selector.split(/\s+/);
    const matches = (el, i) => {
      if (el.tag !== chain[i]) return false;
      if (i === 0) return true;
      for (let up = el.parentElement; up; up = up.parentElement) if (matches(up, i - 1)) return true;
      return false;
    };
    return this.descendants().filter((el) => matches(el, chain.length - 1));
  }
}

const el = (tag, ...children) => new Element(tag, children);

function storePage(label) {
  const button = el("button", el("span", label));
  const other = el("p", "Ardia works with Chrome extensions.");
  const section = el("section", el("div", el("div", el("h1", "Jam")), el("div", button)), other);
  const doc = el("#document", el("main", section));
  return { doc, button, other, section };
}

class FakeObserver {
  static made = [];
  constructor(callback) {
    this.callback = callback;
    FakeObserver.made.push(this);
  }
  observe(target, options) {
    this.target = target;
    this.options = options;
  }
  fire() {
    this.callback([]);
  }
}

test("on the Web Store, a fork's name replaces the Ardia the engine put on the install button", () => {
  const { doc, button, other } = storePage("Add to Ardia");
  const observer = renameStoreButtonFor("Solara", STORE, true, doc, FakeObserver);
  assert.ok(observer);
  assert.equal(button.textContent, "Add to Solara");
  assert.equal(other.textContent, "Ardia works with Chrome extensions.");
  assert.equal(observer.target, doc);
  assert.deepEqual(observer.options, { childList: true, characterData: true, subtree: true });
});

test("the store's re-render of the button, or a new extension page, is renamed too", () => {
  const { doc, button, section } = storePage("Add to Ardia");
  const observer = renameStoreButtonFor("Solara", STORE, true, doc, FakeObserver);
  button.replaceChildren(el("span", "Remove from Ardia"));
  observer.fire();
  assert.equal(button.textContent, "Remove from Solara");
  const next = el("button", "Add to Ardia");
  section.childNodes[0].childNodes[1].replaceChildren(next);
  observer.fire();
  assert.equal(next.textContent, "Add to Solara");
  observer.fire();
  assert.equal(next.textContent, "Add to Solara");
});

test("upstream Ardia, another site, a subframe or no name leaves the page alone and adds no observer", () => {
  const made = FakeObserver.made.length;
  const cases = [
    ["Ardia", STORE, true],
    ["Solara", "https://example.com/detail/jam", true],
    ["Solara", "https://chromewebstore.google.com.evil.example/detail/x", true],
    ["Solara", "https://chrome.google.com/search", true],
    ["Solara", STORE, false],
    [undefined, STORE, true],
    ["", STORE, true],
  ];
  for (const [product, href, top] of cases) {
    const { doc, button } = storePage("Add to Ardia");
    assert.equal(renameStoreButtonFor(product, href, top, doc, FakeObserver), null, `${product} ${href} ${top}`);
    assert.equal(button.textContent, "Add to Ardia");
  }
  assert.equal(FakeObserver.made.length, made);
});

test("the old store at chrome.google.com/webstore counts as the store", () => {
  const { doc, button } = storePage("Add to Ardia");
  assert.ok(renameStoreButtonFor("Solara", "https://chrome.google.com/webstore/detail/x", true, doc, FakeObserver));
  assert.equal(button.textContent, "Add to Solara");
});
