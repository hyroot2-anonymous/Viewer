// Renders the app icon (SVG → PNG) at every size the asset catalog needs.
// Usage: NODE_PATH=$(npm root -g) node tools/make_icon.js
const { chromium } = require('playwright');
const path = require('path');

const out = path.join(__dirname, '../App/Assets.xcassets/AppIcon.appiconset');

// iOS: full-bleed square (the system applies the mask).
// macOS: rounded tile with transparent margin, per the macOS icon grid.
function svg(mac) {
  const tile = mac
    ? '<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>'
    : '<rect width="1024" height="1024" fill="url(#bg)"/>';
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#3B82F6"/><stop offset="1" stop-color="#1E3A8A"/>
    </linearGradient>
    <filter id="s" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#0B1B4D" flood-opacity="0.35"/>
    </filter>
  </defs>
  ${tile}
  <g filter="url(#s)">
    <path d="M312 230 H612 L742 360 V794 H312 Z" fill="#FFFFFF"/>
    <path d="M612 230 V360 H742 Z" fill="#BFD3F7"/>
  </g>
  <rect x="372" y="430" width="310" height="26" rx="13" fill="#93B4EE"/>
  <rect x="372" y="490" width="310" height="26" rx="13" fill="#93B4EE"/>
  <rect x="372" y="550" width="220" height="26" rx="13" fill="#93B4EE"/>
  <text x="527" y="720" text-anchor="middle" font-family="Helvetica, Arial, sans-serif" font-weight="800"
        font-size="120" fill="#1E40AF" letter-spacing="4">HWP</text>
</svg>`;
}

const mac = [16, 32, 128, 256, 512].flatMap(s => [[s, 1], [s, 2]]);

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ deviceScaleFactor: 1 });
  async function render(size, isMac, file) {
    await page.setViewportSize({ width: size, height: size });
    await page.setContent(`<html><body style="margin:0;background:transparent">
      <div style="width:${size}px;height:${size}px">${svg(isMac).replace('width="1024" height="1024"', `width="${size}" height="${size}"`)}</div></body></html>`);
    await page.screenshot({ path: path.join(out, file), omitBackground: isMac });
  }
  const images = [];
  await render(1024, false, 'icon-ios-1024.png');
  images.push({ filename: 'icon-ios-1024.png', idiom: 'universal', platform: 'ios', size: '1024x1024' });
  for (const [size, scale] of mac) {
    const file = `icon-mac-${size}@${scale}x.png`;
    await render(size * scale, true, file);
    images.push({ filename: file, idiom: 'mac', scale: `${scale}x`, size: `${size}x${size}` });
  }
  require('fs').writeFileSync(path.join(out, 'Contents.json'),
    JSON.stringify({ images, info: { author: 'xcode', version: 1 } }, null, 2) + '\n');
  await browser.close();
})();
