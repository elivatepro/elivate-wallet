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
				const png = preview
					? new Uint8Array(await page.screenshot({ type: 'png', clip: { x: 0, y: 0, ...A4 } }))
					: null;
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
			const specifier = '@playwright/test';
			const { chromium } = (await import(/* @vite-ignore */ specifier)) as {
				chromium: LocalChromium;
			};
			const browser = await chromium.launch();
			try {
				const page = await browser.newPage({ viewport: A4 });
				await page.setContent(withScreenCss(html), { waitUntil: 'load' });
				await page.evaluate('document.fonts.ready');
				const pdf = new Uint8Array(await page.pdf(PDF_OPTIONS));
				const png = preview
					? new Uint8Array(await page.screenshot({ type: 'png', clip: { x: 0, y: 0, ...A4 } }))
					: null;
				return { pdf, pages: countPages(pdf), preview: png };
			} finally {
				await browser.close();
			}
		}
	};
}
