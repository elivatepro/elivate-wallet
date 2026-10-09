// HTML → PDF (owner decision Q2: Cloudflare Browser Rendering). The deployed
// Worker drives headless Chrome through the BROWSER binding; local e2e drives
// Playwright's Chromium (same engine, same HTML). Also returns a PNG of the
// first page for the statement preview (Paper S09).

import puppeteer from '@cloudflare/puppeteer';

export interface RenderedPdf {
	readonly pdf: Uint8Array;
	readonly pages: number;
	readonly preview: Uint8Array | null;
}

export interface PdfRenderer {
	render(html: string, options: { preview: boolean }): Promise<RenderedPdf>;
}

const A4 = { width: 794, height: 1123 };
const PDF_OPTIONS = { format: 'A4', printBackground: true, preferCSSPageSize: true } as const;

/** On screen the page has no @page margins: pad like page 1 so the preview matches it. */
const SCREEN_CSS = '@media screen{body{padding:48px 56px}}';
const withScreenCss = (html: string) => html.replace('</style>', `${SCREEN_CSS}</style>`);

/**
 * Lays the screen out as printed page 1: the page body ends 64 px above the
 * bottom (the @page margin), table rows never split (break-inside: avoid), so
 * every row or block that would not fit, and everything after it, moves to
 * page 2 and is hidden here; a forced page break ends page 1 too. Then the
 * page-1 footer is drawn where print puts it.
 */
export const pageOneScript = (pages: number) => `(() => {
  const limit = ${A4.height} - 64;
  let cut = false;
  const hide = (el) => { el.style.visibility = 'hidden'; };
  const walk = (el) => {
    for (const child of Array.from(el.children)) {
      if (cut) { hide(child); continue; }
      const style = getComputedStyle(child);
      if (style.breakBefore === 'page') { cut = true; hide(child); continue; }
      const box = child.getBoundingClientRect();
      if (box.bottom <= limit) continue;
      const rows = child.tagName === 'TR' || style.breakInside === 'avoid' || !child.children.length;
      if (rows) { cut = true; hide(child); } else { walk(child); }
    }
  };
  walk(document.querySelector('main'));
  const footer = document.createElement('div');
  footer.setAttribute('style', 'position:absolute;left:56px;right:56px;top:' + (limit + 0) + 'px;padding-top:12px;border-top:1px solid #E6E9EA;display:flex;justify-content:space-between;font:11px/16px Lexend,system-ui,sans-serif;color:#8A9396');
  const main = document.querySelector('main');
  const left = document.createElement('span');
  left.textContent = main.dataset.footerLeft || '';
  const right = document.createElement('span');
  right.textContent = (main.dataset.footerRight || '') + ' · Page 1 of ${pages}';
  footer.append(left, right);
  document.body.appendChild(footer);
  document.documentElement.style.height = '${A4.height}px';
})()`;

/** Counts page objects ("/Type /Page", not "/Pages") in the PDF. */
export function countPages(pdf: Uint8Array): number {
	const text = new TextDecoder('latin1').decode(pdf);
	return (text.match(/\/Type\s*\/Page(?![a-zA-Z])/g) ?? []).length;
}

export function browserRenderer(binding: BrowserBinding): PdfRenderer {
	return {
		async render(html, { preview }) {
			const browser = await puppeteer.launch(binding);
			try {
				const page = await browser.newPage();
				await page.setViewport(A4);
				await page.setContent(withScreenCss(html), { waitUntil: 'load' });
				await page.evaluate('document.fonts.ready');
				const pdf = new Uint8Array(await page.pdf(PDF_OPTIONS));
				let png: Uint8Array | null = null;
				if (preview) {
					await page.evaluate(pageOneScript(countPages(pdf)));
					png = new Uint8Array(await page.screenshot({ type: 'png', clip: { x: 0, y: 0, ...A4 } }));
				}
				return { pdf, pages: countPages(pdf), preview: png };
			} finally {
				await browser.close();
			}
		}
	};
}

interface LocalChromium {
	launch(): Promise<{
		newPage(options: { viewport: typeof A4 }): Promise<{
			setContent(html: string, options: { waitUntil: 'load' }): Promise<void>;
			evaluate(script: string): Promise<unknown>;
			pdf(options: typeof PDF_OPTIONS): Promise<Uint8Array>;
			screenshot(options: {
				type: 'png';
				clip: { x: number; y: number } & typeof A4;
			}): Promise<Uint8Array>;
		}>;
		close(): Promise<void>;
	}>;
}

/** Local e2e only: Playwright's Chromium, loaded at run time (never bundled). */
export function localRenderer(): PdfRenderer {
	return {
		async render(html, { preview }) {
			// Built at run time so no bundler (vite, wrangler's esbuild) follows it
			// into the Worker: Playwright exists only on a developer machine or CI.
			const specifier = ['@playwright', 'test'].join('/');
			const { chromium } = (await import(/* @vite-ignore */ specifier)) as {
				chromium: LocalChromium;
			};
			const browser = await chromium.launch();
			try {
				const page = await browser.newPage({ viewport: A4 });
				await page.setContent(withScreenCss(html), { waitUntil: 'load' });
				await page.evaluate('document.fonts.ready');
				const pdf = new Uint8Array(await page.pdf(PDF_OPTIONS));
				let png: Uint8Array | null = null;
				if (preview) {
					await page.evaluate(pageOneScript(countPages(pdf)));
					png = new Uint8Array(await page.screenshot({ type: 'png', clip: { x: 0, y: 0, ...A4 } }));
				}
				return { pdf, pages: countPages(pdf), preview: png };
			} finally {
				await browser.close();
			}
		}
	};
}
