"use strict";

const presets = {
  default: { name: "Default", description: "A gradient backdrop, rounded corners and a soft shadow. The Default preset, straight from Glint." },
  clean: { name: "Clean", description: "A quiet background and a little breathing room. The image does the talking." },
  social: { name: "Social 16:9", description: "A wide composition with room around the edges. Ready for a post, a slide or a launch." },
  transparent: { name: "Transparent", description: "Keep the rounded corners and shadow. Lose the background. The checkerboard shows transparency." },
};
const samples = {
  terminal: { name: "Terminal", number: "01" },
  dashboard: { name: "Dashboard", number: "02" },
};

const demo = document.getElementById("demo-image");
const surface = document.getElementById("preview-surface");
const size = document.getElementById("demo-size");
const presetButtons = [...document.querySelectorAll("[data-preset]")];
const sampleButtons = [...document.querySelectorAll("[data-sample]")];
const viewButtons = [...document.querySelectorAll("[data-view]")];
let requested = { sample: "terminal", preset: "default", original: false };
let displayed = requested;
let selection = 0;

async function updatePreview(change) {
  const request = ++selection;
  const next = { ...requested, ...change };
  requested = next;
  const preset = presets[next.preset];
  const sample = samples[next.sample];
  const image = new Image();
  surface.setAttribute("aria-busy", "true");
  image.src = `assets/${next.sample}-${next.original ? "raw" : next.preset}.webp`;
  try {
    await image.decode();
  } catch (error) {
    if (request !== selection) return;
    requested = displayed;
    surface.setAttribute("aria-busy", "false");
    document.getElementById("demo-error").textContent = "This sample could not load. Your previous preview is still shown. Please try again.";
    console.error("Glint preview failed to load:", error);
    return;
  }
  // Only the latest request may replace the image or its selected controls.
  if (request !== selection) return;
  displayed = next;
  document.getElementById("demo-error").textContent = "";
  for (const button of presetButtons) button.setAttribute("aria-pressed", String(button.dataset.preset === next.preset));
  for (const button of sampleButtons) button.setAttribute("aria-pressed", String(button.dataset.sample === next.sample));
  for (const button of viewButtons) button.setAttribute("aria-pressed", String((button.dataset.view === "original") === next.original));
  surface.toggleAttribute("data-original", next.original);
  surface.toggleAttribute("data-checker", !next.original && next.preset === "transparent");
  demo.src = image.src;
  demo.width = image.naturalWidth;
  demo.height = image.naturalHeight;
  demo.alt = next.original
    ? `Original fictional ${sample.name.toLowerCase()} artwork, before styling`
    : `Original sample ${sample.name.toLowerCase()} artwork rendered by Glint with the ${preset.name} preset${next.preset === "transparent" ? "; checkerboard indicates transparency" : ""}`;
  document.getElementById("sample-label").textContent = `Sample ${sample.number} / ${next.sample}.png`;
  document.getElementById("finish-description").textContent = next.original
    ? "The untouched sample, before Glint. Switch to Finished or choose a preset to see the difference."
    : preset.description;
  size.textContent = `${sample.name} · ${next.original ? "Original" : preset.name} · ${image.naturalWidth} × ${image.naturalHeight}`;
  surface.setAttribute("aria-busy", "false");
}

if (demo && surface && size) {
  for (const controls of document.querySelectorAll("[data-preview-controls]")) controls.hidden = false;
  for (const button of presetButtons) button.addEventListener("click", () => updatePreview({ preset: button.dataset.preset, original: false }));
  for (const button of sampleButtons) button.addEventListener("click", () => updatePreview({ sample: button.dataset.sample }));
  for (const button of viewButtons) button.addEventListener("click", () => updatePreview({ original: button.dataset.view === "original" }));
}

for (const button of document.querySelectorAll("[data-copy]")) {
  button.hidden = false;
  let reset;
  const label = button.getAttribute("aria-label");
  button.addEventListener("click", async () => {
    const status = document.getElementById("copy-status");
    const command = document.getElementById(button.dataset.copy);
    clearTimeout(reset);
    button.removeAttribute("data-copied");
    try {
      await navigator.clipboard.writeText(command.textContent.trim());
      button.setAttribute("data-copied", "");
      button.setAttribute("aria-label", "Command copied");
      status.textContent = "Command copied to clipboard.";
      reset = setTimeout(() => {
        button.removeAttribute("data-copied");
        button.setAttribute("aria-label", label);
        status.textContent = "";
      }, 2400);
    } catch (error) {
      button.setAttribute("aria-label", label);
      status.textContent = "Could not copy. Select the command and copy it manually.";
      const range = document.createRange();
      range.selectNodeContents(command);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      console.error("Clipboard access failed:", error);
    }
  });
}

const themeKey = "glint-theme";
const themes = ["system", "light", "dark"];
const themeToggles = [...document.querySelectorAll("[data-theme-toggle]")];
const themeMetas = [...document.querySelectorAll('meta[name="theme-color"]')].map((meta) => ({
  meta,
  content: meta.getAttribute("content"),
  scheme: /dark/.test(meta.getAttribute("media") ?? "") ? "dark" : "light",
}));

function storedTheme() {
  try {
    const value = localStorage.getItem(themeKey);
    return value === "light" || value === "dark" ? value : "system";
  } catch {
    return "system";
  }
}

function applyTheme(theme) {
  if (theme === "system") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", theme);
  // An explicit choice overrides the system scheme, so every theme-color meta follows it.
  const color = themeMetas.find((item) => item.scheme === theme)?.content;
  for (const item of themeMetas) item.meta.setAttribute("content", color ?? item.content);
  const label = `Theme: ${theme} (switch to ${themes[(themes.indexOf(theme) + 1) % themes.length]})`;
  for (const button of themeToggles) {
    button.setAttribute("data-theme-choice", theme);
    button.setAttribute("aria-label", label);
    button.setAttribute("title", label);
  }
}

if (themeToggles.length) {
  let theme = storedTheme();
  applyTheme(theme);
  for (const button of themeToggles) {
    button.hidden = false;
    button.addEventListener("click", () => {
      theme = themes[(themes.indexOf(theme) + 1) % themes.length];
      applyTheme(theme);
      try {
        if (theme === "system") localStorage.removeItem(themeKey);
        else localStorage.setItem(themeKey, theme);
      } catch {
        // Storage may be blocked; the choice still applies until the page is left.
      }
    });
  }
  window.addEventListener("storage", (event) => {
    if (event.key !== themeKey && event.key !== null) return;
    theme = storedTheme();
    applyTheme(theme);
  });
}

const tocLinks = [...document.querySelectorAll(".toc a")];
if (tocLinks.length && "IntersectionObserver" in window) {
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      for (const link of tocLinks) {
        if (link.hash === `#${entry.target.id}`) link.setAttribute("aria-current", "true");
        else link.removeAttribute("aria-current");
      }
    }
  }, { rootMargin: "-100px 0px -60% 0px", threshold: 0 });
  for (const section of document.querySelectorAll(".prose section[id]")) observer.observe(section);
}
