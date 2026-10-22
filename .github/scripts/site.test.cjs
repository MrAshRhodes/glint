const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.resolve(__dirname, "../../site");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
const script = fs.readFileSync(path.join(root, "site.js"), "utf8");
const pages = ["index.html", "guide.html", "404.html"];

function attributes(tag) {
  return Object.fromEntries([...tag.matchAll(/([\w-]+)(?:="([^"]*)")?/g)].map((match) => [match[1], match[2] ?? ""]));
}

test("every local HTML asset and fragment resolves under the Pages project path", () => {
  for (const page of pages) {
    const source = fs.readFileSync(path.join(root, page), "utf8");
    const ids = [...source.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
    assert.equal(new Set(ids).size, ids.length, `${page}: duplicate IDs`);
    for (const match of source.matchAll(/\b(?:src|href)="([^"]+)"/g)) {
      const url = new URL(match[1], `https://example.test/glint/${page}`);
      if (url.origin !== "https://example.test") continue;
      assert.ok(url.pathname.startsWith("/glint/"), `${page}: link escaped project prefix: ${url}`);
      const filename = path.join(root, decodeURIComponent(url.pathname.slice("/glint/".length)) || "index.html");
      assert.ok(fs.existsSync(filename), `${page}: missing ${filename}`);
      if (url.hash) {
        const target = fs.readFileSync(filename, "utf8");
        assert.ok(target.includes(`id="${decodeURIComponent(url.hash.slice(1))}"`), `${page}: missing target ${url}`);
      }
    }
  }
  const css = fs.readFileSync(path.join(root, "styles.css"), "utf8");
  for (const match of css.matchAll(/url\("([^"]+)"\)/g)) {
    assert.ok(fs.existsSync(path.join(root, match[1])), `missing stylesheet asset: ${match[1]}`);
  }
});

test("all two subjects by five views have real WebP assets", () => {
  for (const sample of ["terminal", "dashboard"]) {
    for (const preset of ["raw", "default", "clean", "social", "transparent"]) {
      const image = fs.readFileSync(path.join(root, `assets/${sample}-${preset}.webp`));
      assert.equal(image.toString("ascii", 0, 4), "RIFF");
      assert.equal(image.toString("ascii", 8, 12), "WEBP");
    }
  }
});

test("the static page has a useful default and hides unenhanced controls", () => {
  assert.match(html, /id="demo-image" src="assets\/terminal-default.webp" width="1712" height="1052"/);
  assert.match(html, /<noscript>[\s\S]*interactive sample controls require JavaScript/);
  for (const tag of html.matchAll(/<[^>]+data-preview-controls[^>]*>/g)) assert.match(tag[0], /\bhidden\b/);
  assert.match(html, /data-copy="install-command"[^>]*hidden/);
});

function element(attrs = {}, hidden = false) {
  const values = new Map(Object.entries(attrs));
  return {
    dataset: Object.fromEntries(Object.entries(attrs).filter(([key]) => key.startsWith("data-")).map(([key, value]) => [key.slice(5), value])),
    hidden,
    textContent: "",
    listeners: new Map(),
    getAttribute: (name) => values.get(name) ?? null,
    setAttribute: (name, value) => values.set(name, String(value)),
    removeAttribute: (name) => values.delete(name),
    toggleAttribute: (name, force) => force ? values.set(name, "") : values.delete(name),
    addEventListener(name, listener) { this.listeners.set(name, listener); },
    click() { return this.listeners.get("click")(); },
  };
}

function storage(initial = {}, broken = false) {
  const values = new Map(Object.entries(initial));
  const guard = () => { if (broken) throw new Error("SecurityError: storage is disabled"); };
  return {
    values,
    getItem: (key) => { guard(); return values.get(key) ?? null; },
    setItem: (key, value) => { guard(); values.set(key, String(value)); },
    removeItem: (key) => { guard(); values.delete(key); },
  };
}

function browser({ empty = false, clipboardError = false, page = html, stored = {}, storageError = false } = {}) {
  const elements = new Map();
  const buttons = [];
  const controls = [];
  const metas = [];
  if (!empty) {
    for (const match of page.matchAll(/<([a-z][a-z0-9-]*)\b([^>]*)>/g)) {
      const attrs = attributes(match[2]);
      const item = element(attrs, /\bhidden\b/.test(match[2]));
      if (attrs.id) elements.set(attrs.id, item);
      if (match[1] === "button") buttons.push(item);
      if (match[1] === "meta") metas.push(item);
      if (match[2].includes("data-preview-controls")) controls.push(item);
    }
    if (elements.has("demo-image")) {
      elements.get("demo-image").src = "assets/terminal-default.webp";
      elements.get("install-command").textContent = "brew install --cask MrAshRhodes/tap/glint";
    }
  }
  const root = element();
  const localStorage = storage(stored, storageError);
  const windowListeners = new Map();
  const pending = [];
  const errors = [];
  const copied = [];
  const timers = new Set();
  const selected = [];
  const document = {
    documentElement: root,
    getElementById: (id) => elements.get(id) ?? null,
    querySelectorAll: (selector) => {
      if (selector === "[data-preview-controls]") return controls;
      if (selector === 'meta[name="theme-color"]') return metas.filter((meta) => meta.getAttribute("name") === "theme-color");
      const key = selector.match(/^\[data-([\w-]+)\]$/)?.[1];
      return key ? buttons.filter((button) => key in button.dataset) : [];
    },
    createRange: () => ({ selectNodeContents: (node) => selected.push(node) }),
  };
  class Image {
    decode() {
      return new Promise((resolve, reject) => {
        pending.push({
          image: this,
          resolve: (width = 1408, height = 928) => {
            this.naturalWidth = width;
            this.naturalHeight = height;
            resolve();
          },
          reject: () => reject(new Error("Image unavailable")),
        });
      });
    }
  }
  vm.runInNewContext(script, {
    document, Image, localStorage,
    navigator: { clipboard: { writeText: async (text) => {
      if (clipboardError) throw new Error("Permission denied");
      copied.push(text);
    } } },
    window: {
      getSelection: () => ({ removeAllRanges() {}, addRange() {} }),
      addEventListener: (name, listener) => windowListeners.set(name, listener),
    },
    console: { error: (...args) => errors.push(args) },
    setTimeout: (callback) => { timers.add(callback); return callback; },
    clearTimeout: (callback) => timers.delete(callback),
  });
  const button = (key, value) => buttons.find((item) => item.dataset[key] === value);
  return {
    elements, controls, pending, errors, copied, timers, selected, button, root, metas, localStorage,
    themeToggle: () => buttons.find((item) => "theme-toggle" in item.dataset),
    dispatch: (name, event) => windowListeners.get(name)(event),
    click: (key, value) => button(key, value).click(),
    async load(key, value, width, height) {
      const result = button(key, value).click();
      pending.at(-1).resolve(width, height);
      await result;
    },
    pressed(key, value) {
      assert.equal(button(key, value).getAttribute("aria-pressed"), "true");
      assert.equal(buttons.filter((item) => key in item.dataset && item.getAttribute("aria-pressed") === "true").length, 1);
    },
  };
}

test("enhancement reveals working controls and is safe on pages without a demo", () => {
  const ui = browser();
  assert.ok(ui.controls.every((control) => !control.hidden));
  assert.equal(ui.button("copy", "install-command").hidden, false);
  assert.doesNotThrow(() => browser({ empty: true }));
});

test("changing a finish commits the image, actual dimensions and control state together", async () => {
  const ui = browser();
  const done = ui.click("preset", "clean");
  assert.equal(ui.elements.get("preview-surface").getAttribute("aria-busy"), "true");
  assert.equal(ui.elements.get("demo-image").src, "assets/terminal-default.webp");
  ui.pressed("preset", "default");
  ui.pending[0].resolve(1648, 988);
  await done;
  assert.equal(ui.elements.get("demo-image").src, "assets/terminal-clean.webp");
  assert.equal(ui.elements.get("demo-image").width, 1648);
  assert.equal(ui.elements.get("demo-image").height, 988);
  assert.equal(ui.elements.get("demo-size").textContent, "Terminal · Clean · 1648 × 988");
  assert.equal(ui.elements.get("preview-surface").getAttribute("aria-busy"), "false");
  ui.pressed("preset", "clean");
});

test("each subject supports every finish and original/finished comparison", async () => {
  const ui = browser();
  for (const sample of ["terminal", "dashboard"]) {
    await ui.load("sample", sample);
    ui.pressed("sample", sample);
    for (const preset of ["default", "clean", "social", "transparent"]) {
      await ui.load("preset", preset);
      assert.equal(ui.elements.get("demo-image").src, `assets/${sample}-${preset}.webp`);
      ui.pressed("preset", preset);
      await ui.load("view", "original");
      assert.equal(ui.elements.get("demo-image").src, `assets/${sample}-raw.webp`);
      assert.match(ui.elements.get("demo-image").alt, /before styling/);
      assert.equal(ui.elements.get("preview-surface").getAttribute("data-checker"), null);
      ui.pressed("view", "original");
      await ui.load("view", "finished");
      assert.equal(ui.elements.get("demo-image").src, `assets/${sample}-${preset}.webp`);
      assert.equal(ui.elements.get("preview-surface").getAttribute("data-checker"), preset === "transparent" ? "" : null);
      ui.pressed("view", "finished");
    }
  }
});

test("choosing a finish from Original shows the finished result; changing subjects preserves the view", async () => {
  const ui = browser();
  await ui.load("view", "original");
  await ui.load("sample", "dashboard");
  assert.equal(ui.elements.get("demo-image").src, "assets/dashboard-raw.webp");
  await ui.load("preset", "social", 1878, 1056);
  assert.equal(ui.elements.get("demo-image").src, "assets/dashboard-social.webp");
  ui.pressed("view", "finished");
  assert.equal(ui.elements.get("sample-label").textContent, "Sample 02 / dashboard.png");
});

test("rapid requests combine the latest intent and an older decode cannot overwrite it", async () => {
  const ui = browser();
  const first = ui.click("sample", "dashboard");
  const second = ui.click("preset", "transparent");
  assert.equal(ui.pending[1].image.src, "assets/dashboard-transparent.webp");
  ui.pending[1].resolve(1440, 960);
  await second;
  ui.pending[0].resolve();
  await first;
  assert.equal(ui.elements.get("demo-image").src, "assets/dashboard-transparent.webp");
  ui.pressed("sample", "dashboard");
  ui.pressed("preset", "transparent");
});

test("a failed decode keeps the previous image and controls, then allows a retry", async () => {
  const ui = browser();
  const failed = ui.click("sample", "dashboard");
  ui.pending[0].reject();
  await failed;
  assert.equal(ui.elements.get("demo-image").src, "assets/terminal-default.webp");
  ui.pressed("sample", "terminal");
  assert.match(ui.elements.get("demo-error").textContent, /previous preview is still shown/);
  assert.equal(ui.elements.get("preview-surface").getAttribute("aria-busy"), "false");
  assert.equal(ui.errors.length, 1);
  await ui.load("preset", "clean");
  assert.equal(ui.elements.get("demo-image").src, "assets/terminal-clean.webp");
  assert.equal(ui.elements.get("demo-error").textContent, "");
  await ui.load("sample", "dashboard");
  ui.pressed("sample", "dashboard");
});

test("an obsolete failure cannot clear a newer request's busy state or show an error", async () => {
  const ui = browser();
  const first = ui.click("sample", "dashboard");
  const second = ui.click("preset", "clean");
  ui.pending[0].reject();
  await first;
  assert.equal(ui.elements.get("demo-error").textContent, "");
  assert.equal(ui.elements.get("preview-surface").getAttribute("aria-busy"), "true");
  ui.pending[1].resolve();
  await second;
  assert.equal(ui.errors.length, 0);
});

test("copying reports success and resets without leaving stale feedback", async () => {
  const ui = browser();
  await ui.click("copy", "install-command");
  assert.deepEqual(ui.copied, ["brew install --cask MrAshRhodes/tap/glint"]);
  assert.equal(ui.button("copy", "install-command").getAttribute("aria-label"), "Command copied");
  assert.equal(ui.elements.get("copy-status").textContent, "Command copied to clipboard.");
  await ui.click("copy", "install-command");
  assert.equal(ui.timers.size, 1);
  for (const callback of ui.timers) callback();
  assert.equal(ui.button("copy", "install-command").getAttribute("data-copied"), null);
  assert.equal(ui.button("copy", "install-command").getAttribute("aria-label"), "Copy install command");
  assert.equal(ui.elements.get("copy-status").textContent, "");
});

test("clipboard denial exposes manual-copy instructions and selects the command", async () => {
  const ui = browser({ clipboardError: true });
  await ui.click("copy", "install-command");
  assert.equal(ui.copied.length, 0);
  assert.match(ui.elements.get("copy-status").textContent, /copy it manually/);
  assert.deepEqual(ui.selected, [ui.elements.get("install-command")]);
  assert.equal(ui.errors.length, 1);
  assert.equal(ui.button("copy", "install-command").getAttribute("data-copied"), null);
});

function pageSource(page) {
  return fs.readFileSync(path.join(root, page), "utf8");
}

function themeBootstrap(page) {
  const head = pageSource(page).match(/<head>([\s\S]*?)<\/head>/)[1];
  const inline = [...head.matchAll(/<script>([\s\S]*?)<\/script>/g)];
  assert.equal(inline.length, 1, `${page}: expected one inline theme bootstrap`);
  assert.ok(inline[0].index < head.search(/<link rel="stylesheet"/), `${page}: theme bootstrap must run before the stylesheet`);
  return inline[0][1];
}

test("every page has one hidden, enhanceable theme toggle and scheme-aware metadata", () => {
  for (const page of pages) {
    const source = pageSource(page);
    const toggles = [...source.matchAll(/<button\b[^>]*\bdata-theme-toggle\b[^>]*>/g)];
    assert.equal(toggles.length, 1, `${page}: expected one theme toggle`);
    assert.match(toggles[0][0], /\bhidden\b/, `${page}: theme toggle must stay hidden without JavaScript`);
    assert.match(toggles[0][0], /type="button"/);
    for (const icon of ["system", "light", "dark"]) assert.match(source, new RegExp(`class="theme-icon theme-icon-${icon}"[^>]*aria-hidden="true"`));
    assert.match(source, /<meta name="color-scheme" content="light dark">/);
    assert.match(source, /<meta name="theme-color" content="#f0f1ee" media="\(prefers-color-scheme: light\)">/);
    assert.match(source, /<meta name="theme-color" content="#[0-9a-f]{6}" media="\(prefers-color-scheme: dark\)">/);
    assert.equal(source.match(/name="theme-color"/g).length, 2, `${page}: expected light and dark theme-color metas`);
    assert.match(source, /<script src="(?:\/glint\/)?site\.js" defer><\/script>/, `${page}: theme toggle needs site.js`);
  }
});

test("the no-flash bootstrap applies only a valid stored choice and tolerates blocked storage", () => {
  const bootstraps = pages.map(themeBootstrap);
  assert.ok(bootstraps.every((source) => source === bootstraps[0]), "theme bootstraps differ between pages");
  for (const [stored, expected] of [["light", "light"], ["dark", "dark"], ["sepia", null], [undefined, null]]) {
    const root = element();
    vm.runInNewContext(bootstraps[0], { document: { documentElement: root }, localStorage: storage(stored ? { "glint-theme": stored } : {}) });
    assert.equal(root.getAttribute("data-theme"), expected);
  }
  const root = element();
  assert.doesNotThrow(() => vm.runInNewContext(bootstraps[0], { document: { documentElement: root }, localStorage: storage({}, true) }));
  assert.equal(root.getAttribute("data-theme"), null);
});

test("the theme toggle cycles system, light and dark, persists the choice and updates theme-color", () => {
  for (const page of pages) {
    const ui = browser({ page: pageSource(page) });
    const toggle = ui.themeToggle();
    const colors = () => ui.metas.filter((meta) => meta.getAttribute("name") === "theme-color").map((meta) => meta.getAttribute("content"));
    const [light, dark] = colors();
    assert.equal(toggle.hidden, false, `${page}: toggle not revealed`);
    assert.equal(toggle.getAttribute("data-theme-choice"), "system");
    assert.equal(toggle.getAttribute("aria-label"), "Theme: system (switch to light)");
    assert.equal(ui.root.getAttribute("data-theme"), null);
    toggle.click();
    assert.equal(ui.root.getAttribute("data-theme"), "light");
    assert.equal(ui.localStorage.values.get("glint-theme"), "light");
    assert.equal(toggle.getAttribute("aria-label"), "Theme: light (switch to dark)");
    assert.equal(toggle.getAttribute("title"), "Theme: light (switch to dark)");
    assert.deepEqual(colors(), [light, light]);
    toggle.click();
    assert.equal(ui.root.getAttribute("data-theme"), "dark");
    assert.equal(ui.localStorage.values.get("glint-theme"), "dark");
    assert.equal(toggle.getAttribute("data-theme-choice"), "dark");
    assert.equal(toggle.getAttribute("aria-label"), "Theme: dark (switch to system)");
    assert.deepEqual(colors(), [dark, dark]);
    toggle.click();
    assert.equal(ui.root.getAttribute("data-theme"), null);
    assert.equal(ui.localStorage.values.has("glint-theme"), false);
    assert.equal(toggle.getAttribute("data-theme-choice"), "system");
    assert.deepEqual(colors(), [light, dark]);
  }
});

test("a stored theme is restored, other tabs stay in sync and blocked storage still toggles", () => {
  const ui = browser({ stored: { "glint-theme": "dark" } });
  assert.equal(ui.themeToggle().getAttribute("data-theme-choice"), "dark");
  assert.equal(ui.root.getAttribute("data-theme"), "dark");
  ui.localStorage.values.set("glint-theme", "light");
  ui.dispatch("storage", { key: "glint-theme" });
  assert.equal(ui.root.getAttribute("data-theme"), "light");
  ui.localStorage.values.set("unrelated", "x");
  ui.localStorage.values.delete("glint-theme");
  ui.dispatch("storage", { key: "unrelated" });
  assert.equal(ui.root.getAttribute("data-theme"), "light");
  ui.dispatch("storage", { key: null });
  assert.equal(ui.root.getAttribute("data-theme"), null);
  assert.equal(ui.themeToggle().getAttribute("data-theme-choice"), "system");

  const blocked = browser({ storageError: true });
  assert.equal(blocked.themeToggle().getAttribute("data-theme-choice"), "system");
  assert.doesNotThrow(() => blocked.themeToggle().click());
  assert.equal(blocked.root.getAttribute("data-theme"), "light");
  blocked.themeToggle().click();
  assert.equal(blocked.root.getAttribute("data-theme"), "dark");
  assert.equal(blocked.errors.length, 0);
});
