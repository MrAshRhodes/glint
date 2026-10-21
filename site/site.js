"use strict";

const presets = {
  raw: { name: "Raw", width: 1520, height: 860, description: "Original fictional terminal capture, before styling" },
  default: { name: "Default", width: 1712, height: 1052, description: "Terminal capture with Glint's Default gradient background, rounded corners and shadow" },
  social: { name: "Social 16:9", width: 1984, height: 1116, description: "Terminal capture styled for a wide 16:9 composition" },
  clean: { name: "Clean", width: 1648, height: 988, description: "Terminal capture with a minimal light background and soft shadow" },
  transparent: { name: "Transparent", width: 1680, height: 1020, description: "Terminal capture on a transparent canvas; checkerboard indicates transparency" },
};

const tabs = [...document.querySelectorAll("[data-preset]")];
const preview = document.getElementById("preset-preview");
const demo = document.getElementById("demo-image");
const size = document.getElementById("demo-size");
let selection = 0;

async function selectPreset(tab) {
  const request = ++selection;
  const key = tab.dataset.preset;
  const preset = presets[key];
  const image = new Image();
  image.src = `assets/terminal-${key}.webp`;
  try {
    await image.decode();
  } catch (error) {
    if (request !== selection) return;
    document.getElementById("demo-error").textContent = "This preview could not load. Please try again.";
    console.error("Glint preset preview failed to load:", error);
    return;
  }
  if (request !== selection) return;
  document.getElementById("demo-error").textContent = "";
  for (const item of tabs) {
    const active = item === tab;
    item.setAttribute("aria-selected", String(active));
    item.tabIndex = active ? 0 : -1;
  }
  preview.setAttribute("aria-labelledby", tab.id);
  preview.toggleAttribute("data-checker", key === "transparent");
  demo.src = image.src;
  demo.width = preset.width;
  demo.height = preset.height;
  demo.alt = preset.description;
  demo.classList.toggle("is-raw", key === "raw");
  size.textContent = `${preset.name} · ${preset.width} × ${preset.height}`;
}

if (tabs.length && preview && demo && size) {
  document.querySelector(".tabs").hidden = false;
  for (const [index, tab] of tabs.entries()) {
    tab.addEventListener("click", () => selectPreset(tab));
    tab.addEventListener("keydown", (event) => {
      let next;
      if (event.key === "ArrowRight") next = (index + 1) % tabs.length;
      else if (event.key === "ArrowLeft") next = (index + tabs.length - 1) % tabs.length;
      else if (event.key === "Home") next = 0;
      else if (event.key === "End") next = tabs.length - 1;
      else return;
      event.preventDefault();
      tabs[next].focus();
      selectPreset(tabs[next]);
    });
  }
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
  }, { rootMargin: "-90px 0px -60% 0px", threshold: 0 });
  for (const section of document.querySelectorAll(".prose section[id]")) observer.observe(section);
}
