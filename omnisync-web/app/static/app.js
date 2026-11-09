// Chart tooltips (any element with data-tip) and the theme switch.
(function () {
  const tip = document.querySelector(".tip");
  let current = null;

  function show(el, x, y) {
    tip.textContent = el.getAttribute("data-tip");
    tip.hidden = false;
    const w = tip.offsetWidth, h = tip.offsetHeight;
    let left = x + 12, top = y - h - 10;
    if (left + w > window.innerWidth - 8) left = x - w - 12;
    if (top < 8) top = y + 16;
    tip.style.left = left + "px";
    tip.style.top = top + "px";
  }

  document.addEventListener("pointermove", (e) => {
    const el = e.target.closest && e.target.closest("[data-tip]");
    if (el) { current = el; show(el, e.clientX, e.clientY); }
    else if (current) { current = null; tip.hidden = true; }
  });
  document.addEventListener("pointerleave", () => { tip.hidden = true; });
  window.addEventListener("scroll", () => { tip.hidden = true; }, { passive: true });

  // SVG titles duplicate the tooltip for screen readers; hide the browser's own tooltip.
  document.querySelectorAll("svg [data-tip] > title").forEach((t) => {
    t.parentNode.setAttribute("aria-label", t.textContent);
    t.remove();
  });

  // Calendars open on the latest weeks when they don't fit.
  document.querySelectorAll(".chart-wrap").forEach((w) => {
    if (w.querySelector(".calendar")) w.scrollLeft = w.scrollWidth;
  });

  const toggle = document.querySelector("[data-theme-toggle]");
  if (toggle) toggle.addEventListener("click", () => {
    const root = document.documentElement;
    const dark = root.dataset.theme ? root.dataset.theme === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
    root.dataset.theme = dark ? "light" : "dark";
    try { localStorage.setItem("theme", root.dataset.theme); } catch (e) {}
  });
})();
