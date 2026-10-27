// Renders one home-screen icon set per theme (icons/<theme>/) plus a manifest for each (manifest-<theme>.webmanifest).
// Midnight is the original set in icons/ and manifest.webmanifest. Run with: node tools/icons.js
const fs = require('fs'), path = require('path'), { chromium } = require('playwright');
const root = path.resolve(__dirname, '..');
const THEMES = { graphite: ['#111315', '#5B8CFF'], oled: ['#000000', '#3CCB9A'], forest: ['#0C1410', '#E2B53E'], espresso: ['#16100D', '#FF7A45'], chalk: ['#F2F3F5', '#2F6BFF'] };
const glyph = (fg, bg) => `<g transform="rotate(-40 32 32)"><g fill="${fg}"><rect x="9" y="15.5" width="46" height="9" rx="4.5"/><rect x="9" y="27.5" width="46" height="9" rx="4.5"/><rect x="9" y="39.5" width="46" height="9" rx="4.5"/></g><g stroke="${bg}" stroke-width="1.8" stroke-linecap="round" opacity=".5">${[17.5, 29.5, 41.5].map(y => [17, 23, 29, 35, 41, 47].map(x => `<path d="M${x} ${y}v5"/>`).join('')).join('')}</g></g>`;
// any: rounded tile on transparent; maskable: full bleed with the glyph inside the safe zone; apple: full bleed square.
const svg = (bg, fg, kind) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" ${kind === 'any' ? 'rx="15"' : ''} fill="${bg}"/>${kind === 'maskable' ? `<g transform="translate(32 32) scale(.86) translate(-32 -32)">${glyph(fg, bg)}</g>` : glyph(fg, bg)}</svg>`;
(async () => {
  const browser = await chromium.launch(), page = await browser.newPage();
  const base = JSON.parse(fs.readFileSync(path.join(root, 'manifest.webmanifest'), 'utf8'));
  for (const [id, [bg, fg]] of Object.entries(THEMES)) {
    const dir = path.join(root, 'icons', id); fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'icon.svg'), svg(bg, fg, 'any'));
    for (const [file, size, kind] of [['icon-192.png', 192, 'any'], ['icon-512.png', 512, 'any'], ['maskable-512.png', 512, 'maskable'], ['apple-touch-icon.png', 180, 'apple']]) {
      await page.setViewportSize({ width: size, height: size });
      await page.setContent(`<html><body style="margin:0;background:transparent">${svg(bg, fg, kind).replace('<svg ', `<svg width="${size}" height="${size}" `)}</body></html>`);
      await page.screenshot({ path: path.join(dir, file), omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
    }
    const m = { ...base, background_color: bg, theme_color: bg, icons: base.icons.map(i => ({ ...i, src: i.src.replace('icons/', `icons/${id}/`) })), shortcuts: base.shortcuts.map(s => ({ ...s, icons: s.icons.map(i => ({ ...i, src: i.src.replace('icons/', `icons/${id}/`) })) })) };
    fs.writeFileSync(path.join(root, `manifest-${id}.webmanifest`), JSON.stringify(m, null, 2) + '\n');
  }
  await browser.close();
})();
