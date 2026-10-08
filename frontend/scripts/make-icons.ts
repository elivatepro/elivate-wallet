// Renders the PWA icons from the Elivate mark (static/icons/mark.svg) with
// Playwright's Chromium. Run once when the mark changes:
//   pnpm exec node --experimental-strip-types scripts/make-icons.ts
// The mark is never recoloured; icons sit on the dark canvas (#111314).

import { readFile } from 'node:fs/promises';
import { chromium } from '@playwright/test';

const svg = await readFile(new URL('../static/icons/mark.svg', import.meta.url), 'utf8');
const dataUrl = `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`;

const targets = [
	{ file: 'icon-192.png', size: 192, padding: 0 },
	{ file: 'icon-512.png', size: 512, padding: 0 },
	// Maskable icons keep the mark inside the 80% safe zone.
	{ file: 'icon-maskable-512.png', size: 512, padding: 0.1 },
	{ file: 'apple-touch-icon.png', size: 180, padding: 0.02 }
];

const browser = await chromium.launch();
const page = await browser.newPage();
for (const { file, size, padding } of targets) {
	const inner = Math.round(size * (1 - padding * 2));
	await page.setViewportSize({ width: size, height: size });
	await page.setContent(
		`<html><body style="margin:0;width:${size}px;height:${size}px;display:flex;align-items:center;justify-content:center;background:#111314">` +
			`<img src="${dataUrl}" width="${inner}" height="${inner}"></body></html>`
	);
	await page.screenshot({ path: new URL(`../static/icons/${file}`, import.meta.url).pathname });
}
await browser.close();
