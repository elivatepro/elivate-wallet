// Renders the iPhone/iPad launch images (apple-touch-startup-image) for the
// installed app (Blueprint 35): the dark canvas (#111314) with the mark at
// 140 CSS px in the centre, the first frame of the launch animation in
// app.html. Run when the mark changes:
//   pnpm exec node --experimental-strip-types scripts/make-splash.ts
// It prints the <link> tags app.html carries.

import { mkdir, readFile } from 'node:fs/promises';
import { chromium } from '@playwright/test';

const svg = await readFile(new URL('../static/icons/mark.svg', import.meta.url), 'utf8');
const dataUrl = `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`;

/** Portrait CSS viewport and pixel ratio of each iPhone and iPad size class. */
const devices = [
	{ w: 440, h: 956, r: 3 }, // 16/17 Pro Max
	{ w: 430, h: 932, r: 3 }, // 14/15 Pro Max, 15/16 Plus
	{ w: 428, h: 926, r: 3 }, // 12/13 Pro Max, 14 Plus
	{ w: 420, h: 912, r: 3 }, // Air
	{ w: 414, h: 896, r: 3 }, // XS Max, 11 Pro Max
	{ w: 414, h: 896, r: 2 }, // XR, 11
	{ w: 402, h: 874, r: 3 }, // 16/17 Pro, 17
	{ w: 393, h: 852, r: 3 }, // 14/15 Pro, 15, 16
	{ w: 390, h: 844, r: 3 }, // 12/13/14
	{ w: 375, h: 812, r: 3 }, // X, XS, 11 Pro, mini
	{ w: 375, h: 667, r: 2 }, // SE, 8
	{ w: 1032, h: 1376, r: 2 }, // iPad Pro 13"
	{ w: 1024, h: 1366, r: 2 }, // iPad Pro 12.9"
	{ w: 834, h: 1210, r: 2 }, // iPad Pro 11" (M4)
	{ w: 834, h: 1194, r: 2 }, // iPad Pro 11"
	{ w: 820, h: 1180, r: 2 }, // iPad Air, iPad 10th
	{ w: 744, h: 1133, r: 2 }, // iPad mini
	{ w: 810, h: 1080, r: 2 }, // iPad 9th
	{ w: 768, h: 1024, r: 2 } // older iPads
];

const outDir = new URL('../static/splash/', import.meta.url);
await mkdir(outDir, { recursive: true });
const browser = await chromium.launch();
const links: string[] = [];
for (const { w, h, r } of devices) {
	const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: r });
	await page.setContent(
		`<html><body style="margin:0;width:${w}px;height:${h}px;display:flex;align-items:center;justify-content:center;background:#111314">` +
			`<img src="${dataUrl}" width="140" height="140"></body></html>`
	);
	const file = `apple-${w * r}x${h * r}.png`;
	await page.screenshot({ path: new URL(file, outDir).pathname });
	await page.close();
	links.push(
		`<link rel="apple-touch-startup-image" href="/splash/${file}" media="(device-width: ${w}px) and (device-height: ${h}px) and (-webkit-device-pixel-ratio: ${r}) and (orientation: portrait)" />`
	);
}
await browser.close();
console.log(links.join('\n'));
