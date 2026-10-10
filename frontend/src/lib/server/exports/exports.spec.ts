import { writeFileSync, mkdirSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import type { ClaimedJob, RowsPage } from '#lib/contract/exports.js';
import { guardText, memberBalancesCsv, statementCsv, toCsv } from './csv';
import { badges, description, detail } from './describe';
import { reportMembers, reportSummary, statementRows, statementSummary } from './fixtures';
import { cssString, escapeHtml, reportHtml, statementHtml } from './html';
import { countPages, footerTemplate } from './render';
import { readAllRows, runJob, type WorkerClient } from './runner';
import type { ExportStorage } from './storage';

describe('csv', () => {
	it('quotes, uses CRLF and a BOM', () => {
		const csv = toCsv(['a', 'b'], [[{ text: 'x, "y"' }, { amount: '-48000.00' }]]);
		expect(csv).toBe('﻿a,b\r\n"x, ""y""",-48000.00\r\n');
	});

	it('guards text cells against formulas but never touches amounts', () => {
		expect(guardText('=HYPERLINK("x")')).toBe(`'=HYPERLINK("x")`);
		expect(guardText('-cmd')).toBe(`'-cmd`);
		expect(guardText('@SUM(A1)')).toBe(`'@SUM(A1)`);
		expect(toCsv(['n'], [[{ amount: '-1.00' }]])).toContain('\r\n-1.00\r\n');
	});

	it('keeps exact amounts, one row per movement, with the running balance', () => {
		const csv = statementCsv(statementSummary, statementRows);
		const lines = csv.trim().split('\r\n');
		expect(lines).toHaveLength(1 + statementRows.length);
		expect(lines[0]).toContain('posted_at_utc,date_wat,time_wat,reference');
		expect(lines[0]).toContain(',balance,');
		expect(csv).toContain('REV-2B7C-0923');
		expect(csv).toContain(',-32500.00,484400.00,');
		expect(csv).not.toMatch(/₦/);
	});

	it('lists one row per member with every figure', () => {
		const csv = memberBalancesCsv(reportSummary, reportMembers);
		expect(csv.trim().split('\r\n')).toHaveLength(1 + reportMembers.length);
		expect(csv).toContain('EW-31877');
	});

	it('refuses a row that does not match the header', () => {
		expect(() => toCsv(['a', 'b'], [[{ text: 'x' }]])).toThrow();
	});
});

describe('descriptions', () => {
	it('reads like Paper S01/S02', () => {
		const [income, withdrawal, , move, reversed, reversal] = statementRows;
		expect(description(income!)).toBe('Income · Lagos office');
		expect(detail(income!, 'NGN')).toBe(
			'INC-5A1B-0712 · Spend ₦72,000 · Save ₦36,000 · Invest ₦12,000'
		);
		expect(detail(withdrawal!, 'NGN')).toBe('WDR-7H2K-0455 · from Spend');
		expect(description(move!)).toBe('Pocket move · Save → Spend');
		expect(detail(move!, 'NGN')).toBe('PTR-3D1E-1101 · ₦20,000.00 · no change to total');
		expect(badges(reversed!)).toEqual(['Reversed']);
		expect(detail(reversed!, 'NGN')).toBe('INC-8E4F-0915 · reversed by REV-2B7C-0923');
		expect(description(reversal!)).toBe('Reversal · recorded twice');
		expect(badges(reversal!)).toEqual(['Correction']);
		expect(detail(reversal!, 'NGN')).toBe('REV-2B7C-0923 · reverses INC-8E4F-0915');
	});
});

describe('pdf html', () => {
	it('escapes every value', () => {
		expect(escapeHtml(`<img src=x onerror="a">'`)).toBe(
			'&lt;img src=x onerror=&quot;a&quot;&gt;&#39;'
		);
		const html = statementHtml(
			{ ...statementSummary, person: { uid: 'EW-48213', name: '<script>alert(1)</script>' } },
			statementRows
		);
		expect(html).not.toContain('<script>alert');
		expect(html).toContain('&lt;script&gt;');
	});

	it('never lets a name out of the page CSS', () => {
		expect(cssString('A</style><script>"x"\\')).toBe(
			'"A\\3c \\2f style\\3e \\3c script\\3e \\22 x\\22 \\5c "'
		);
	});

	it('shows the statement figures, both reversal rows and what was waiting', () => {
		const html = statementHtml(statementSummary, statementRows);
		expect(html).toContain('Account statement');
		expect(html).toContain('1 – 30 September 2026 · Nigerian naira (NGN)');
		expect(html).toContain('₦312,400.00');
		expect(html).toContain('+₦272,500.00');
		expect(html).toContain('−₦128,500.00');
		expect(html).toContain('2 withdrawals · 1 reversal');
		expect(html).toContain('Reversed');
		expect(html).toContain('Correction');
		expect(html).toContain('Not yet posted on 30 Sep');
		expect(html).toContain('Approved · not paid');
		expect(html).toContain('Available to withdraw');
		expect(html).toContain('support@elivatewallet.com');
		expect(html).not.toMatch(/root-|\/root\//); // Root stays out of generated files
	});

	it('says an empty period is empty, with balances (Paper S07)', () => {
		const html = statementHtml(
			{
				...statementSummary,
				currency: 'USD',
				opening: '1240.00',
				moneyIn: '0.00',
				moneyOut: '0.00',
				closing: '1240.00',
				inCount: 0,
				outTypes: {},
				pockets: [],
				pending: [],
				reserved: '0.00',
				available: '1240.00'
			},
			[]
		);
		expect(html).toContain('No transactions in this period');
		expect(html).toContain('Your USD balance did not change in September.');
		expect(html).toContain('No credits');
	});

	it('builds the office report with memberships vs people', () => {
		const html = reportHtml(reportSummary, reportMembers);
		expect(html).toContain('Office report');
		expect(html).toContain('Prepared for Tunde B. · Team Leader');
		expect(html).toContain('Income posted · 42 entries');
		expect(html).toContain('Reserved for 2 open requests');
		expect(html).toContain('Active memberships');
		expect(html).toContain('Distinct people');
		expect(html).toContain('By member');
		expect(html).toContain('Confidential to office leadership');
	});

	it('writes sample files when asked (compared with Paper)', () => {
		const dir = process.env.EXPORT_SAMPLES;
		expect(typeof statementHtml).toBe('function');
		if (!dir) return;
		mkdirSync(dir, { recursive: true });
		writeFileSync(`${dir}/statement.html`, statementHtml(statementSummary, statementRows));
		writeFileSync(`${dir}/report.html`, reportHtml(reportSummary, reportMembers));
		writeFileSync(`${dir}/statement.csv`, statementCsv(statementSummary, statementRows));
		writeFileSync(`${dir}/members.csv`, memberBalancesCsv(reportSummary, reportMembers));
	});
});

describe('page footer', () => {
	it('carries the network, the reference and Chrome page numbers, escaped', () => {
		const html = statementHtml(
			{ ...statementSummary, network: { ...statementSummary.network, name: 'Cedar <b>' } },
			statementRows
		);
		const footer = footerTemplate(html);
		expect(footer).toContain(
			'Cedar &lt;b&gt; · Powered by Elivate Wallet · support@elivatewallet.com'
		);
		expect(footer).toContain(
			'STM-4V9B-0412 · Page <span class="pageNumber"></span> of <span class="totalPages"></span>'
		);
		expect(html).not.toMatch(/@bottom-|@top-/);
	});
});

describe('page count', () => {
	it('counts page objects, not the page tree', () => {
		const pdf = new TextEncoder().encode(
			'<< /Type /Pages /Count 2 >> << /Type /Page >> << /Type/Page >>'
		);
		expect(countPages(pdf)).toBe(2);
	});
});

// ── Complete or fail ──

const job: ClaimedJob = {
	exportId: '00000000-0000-4000-8000-0000000000f1',
	reference: 'STM-4V9B-0412',
	kind: 'statement_csv',
	format: 'csv',
	objectKey:
		'exports/00000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-0000000000f1.csv',
	fileName: 'f.csv',
	attempt: 1
};

function fakeClient(pages: RowsPage[] | ((after: number) => RowsPage), rowCount: number) {
	const calls: string[] = [];
	const client: WorkerClient = {
		claim: async () => null,
		prepare: async () => {
			calls.push('prepare');
			return { status: 'rendering', rowCount, summary: statementSummary, background: false };
		},
		rows: async (_id, _w, after) => {
			calls.push(`rows:${after}`);
			if (typeof pages === 'function') return pages(after);
			const page = pages.shift();
			if (!page) throw new Error('network');
			return page;
		},
		finalize: async (_id, _w, file) => {
			calls.push(`finalize:${file.rowCount}`);
			return { status: file.rowCount === rowCount ? 'ready' : 'failed' };
		},
		fail: async (_id, _w, reason) => {
			calls.push(`fail:${reason}`);
		}
	};
	return { client, calls };
}

function memoryStorage() {
	const files = new Map<string, Uint8Array>();
	const storage: ExportStorage = {
		put: async (key, bytes) => void files.set(key, bytes),
		get: async (key) =>
			files.has(key) ? { body: files.get(key)!, size: files.get(key)!.length } : null,
		delete: async (key) => void files.delete(key)
	};
	return { files, storage };
}

const page = (from: number, to: number, rowCount: number): RowsPage => ({
	rowCount,
	rows: Array.from({ length: to - from + 1 }, (_, i) => ({
		seq: from + i,
		section: 'txn' as const,
		data: statementRows[(from + i - 1) % statementRows.length]
	}))
});

const deps = (client: WorkerClient, storage: ExportStorage) => ({
	client,
	storage,
	renderer: { render: async () => ({ pdf: new Uint8Array([37]), pages: 1, preview: null }) },
	log: () => {},
	pageSize: 3
});

describe('the runner completes or fails', () => {
	it('reads every page in seq order', async () => {
		const { client, calls } = fakeClient([page(1, 3, 7), page(4, 6, 7), page(7, 7, 7)], 7);
		const rows = await readAllRows(client, job.exportId, 'w', 7, 3);
		expect(rows.map((r) => r.seq)).toEqual([1, 2, 3, 4, 5, 6, 7]);
		expect(calls).toEqual(['rows:0', 'rows:3', 'rows:6']);
	});

	it('a ready file holds every row', async () => {
		const { client, calls } = fakeClient([page(1, 3, 5), page(4, 5, 5)], 5);
		const { files, storage } = memoryStorage();
		expect((await runJob(deps(client, storage), job, 'w')).status).toBe('ready');
		expect(calls.at(-1)).toBe('finalize:5');
		const csv = new TextDecoder().decode(files.get(job.objectKey));
		expect(csv.trim().split('\r\n')).toHaveLength(6);
	});

	it('a gap in the rows fails the file, nothing is stored', async () => {
		const { client, calls } = fakeClient([page(1, 3, 6), page(5, 6, 6)], 6);
		const { files, storage } = memoryStorage();
		const outcome = await runJob(deps(client, storage), job, 'w');
		expect(outcome).toMatchObject({ status: 'failed', reason: 'incomplete' });
		expect(calls).toContain('fail:incomplete');
		expect(calls.some((c) => c.startsWith('finalize'))).toBe(false);
		expect(files.size).toBe(0);
	});

	it('an error mid-export fails the file (never a first-page-only file)', async () => {
		const { client, calls } = fakeClient([page(1, 3, 6)], 6);
		const { files, storage } = memoryStorage();
		const outcome = await runJob(deps(client, storage), job, 'w');
		expect(outcome).toMatchObject({ status: 'failed', reason: 'read_failed' });
		expect(calls).toContain('fail:read_failed');
		expect(files.size).toBe(0);
	});

	it('a short page with the same count is incomplete', async () => {
		const { client } = fakeClient(() => ({ rowCount: 4, rows: [] }), 4);
		const { storage } = memoryStorage();
		expect((await runJob(deps(client, storage), job, 'w')).reason).toBe('incomplete');
	});

	it('a lost finalize answer never deletes a file the database may call ready', async () => {
		const { client, calls } = fakeClient([page(1, 2, 2)], 2);
		const { files, storage } = memoryStorage();
		const lost: WorkerClient = {
			...client,
			finalize: async () => Promise.reject(new Error('network')),
			fail: async () => Promise.reject(new Error('conflict: lease_lost'))
		};
		const outcome = await runJob(deps(lost, storage), job, 'w');
		expect(outcome.reason).toBe('finalize_unknown');
		expect(files.has(job.objectKey)).toBe(true);
		expect(calls).not.toContain('fail:render_failed');
	});

	it('a lost finalize answer on a job still rendering fails it and cleans up', async () => {
		const { client, calls } = fakeClient([page(1, 2, 2)], 2);
		const { files, storage } = memoryStorage();
		const outcome = await runJob(
			deps({ ...client, finalize: async () => Promise.reject(new Error('network')) }, storage),
			job,
			'w'
		);
		expect(outcome.reason).toBe('storage_failed');
		expect(calls).toContain('fail:storage_failed');
		expect(files.size).toBe(0);
	});

	it('a render failure fails the file', async () => {
		const { client, calls } = fakeClient([page(1, 2, 2)], 2);
		const { storage } = memoryStorage();
		const failing = {
			...deps(client, storage),
			renderer: { render: async () => Promise.reject(new Error('chrome gone')) }
		};
		const outcome = await runJob(failing, { ...job, kind: 'statement_pdf', format: 'pdf' }, 'w');
		expect(outcome).toMatchObject({ status: 'failed', reason: 'render_failed' });
		expect(calls).toContain('fail:render_failed');
	});
});

// Blueprint 17: the network header on PDFs.
describe('PDF branding', () => {
	it('uses the logo, else the initial on the theme colour, and the team contact', () => {
		const base = statementSummary;
		const themed = statementHtml(
			{
				...base,
				network: {
					...base.network,
					theme: 'cobalt',
					support: {
						name: null,
						email: 'help@cedar.example',
						phone: '+2348012342210',
						helpUrl: null
					}
				}
			},
			[]
		);
		expect(themed).toContain('background:#6AACFE');
		expect(themed).toContain('Cedar Network support: help@cedar.example · +2348012342210');
		const logo = `data:image/png;base64,${'A'.repeat(16)}`;
		expect(statementHtml(base, [], logo)).toContain(`<img class="logo" src="${logo}"`);
		expect(statementHtml(base, [], 'javascript:alert(1)')).not.toContain('javascript:');
	});
});
