// The deployed renderer must hand Chrome the page footer (Cloudflare's Chrome
// ignores CSS margin boxes): checks what browserRenderer passes to page.pdf.
import { describe, expect, it, vi } from 'vitest';
import { reportHtml } from './html';
import { reportMembers, reportSummary } from './fixtures';

const calls: { pdf?: Record<string, unknown>; script?: string } = {};

vi.mock('@cloudflare/puppeteer', () => ({
	default: {
		launch: async () => ({
			newPage: async () => ({
				setViewport: async () => undefined,
				setContent: async () => undefined,
				evaluate: async (script: string) => {
					calls.script = script;
				},
				pdf: async (options: Record<string, unknown>) => {
					calls.pdf = options;
					return new TextEncoder().encode('%PDF-1.7 << /Type /Page >> << /Type /Page >>');
				},
				screenshot: async () => new Uint8Array([137, 80, 78, 71])
			}),
			close: async () => undefined
		})
	}
}));

describe('browser renderer', () => {
	it('prints Paper’s footer with the reference and Chrome page numbers on every page', async () => {
		const { browserRenderer } = await import('./render');
		const out = await browserRenderer({} as BrowserBinding).render(
			reportHtml(reportSummary, reportMembers),
			{
				preview: true
			}
		);
		expect(out.pages).toBe(2);
		expect(calls.pdf).toMatchObject({
			format: 'A4',
			printBackground: true,
			displayHeaderFooter: true
		});
		const footer = String(calls.pdf?.footerTemplate);
		expect(footer).toContain(
			'Cedar Network · Powered by Elivate Wallet · Confidential to office leadership'
		);
		expect(footer).toContain(
			'RPT-6H4S-0031 · Page <span class="pageNumber"></span> of <span class="totalPages"></span>'
		);
		// The page-1 preview gets the same footer, with the real page count.
		expect(calls.script).toContain('Page 1 of 2');
	});
});
