// The export runner (Blueprint 15 — B4). pg_cron/pg_net (and the app server,
// right after a request) POST /internal/exports/run; this claims jobs from the
// `exports-worker` Edge Function and, per job: prepare (Postgres writes every
// row in one transaction) → page through all rows in seq order → build the CSV
// or the PDF → store it → finalize. Complete or fail: any gap, short page, bad
// row or error fails the job, and a file is never marked ready unless the
// database confirms every prepared row made it.

import { Effect, Schema } from 'effect';
import {
	ClaimResult,
	MemberFigure,
	PrepareResult,
	ReportSummary,
	RowsPage,
	StatementSummary,
	StepResult,
	TxnRow,
	type ClaimedJob
} from '#lib/contract/exports.js';
import { requestJson } from '#lib/contract/transport.js';
import { memberBalancesCsv, statementCsv, transactionsCsv } from './csv';
import { reportHtml, statementHtml } from './html';
import type { PdfRenderer } from './render';
import type { ExportStorage } from './storage';

export type FailReason =
	'read_failed' | 'render_failed' | 'storage_failed' | 'incomplete' | 'timeout';

class StepFailure extends Error {
	constructor(readonly reason: FailReason) {
		super(reason);
	}
}

export interface WorkerClient {
	claim(worker: string): Promise<ClaimedJob | null>;
	prepare(id: string, worker: string): Promise<PrepareResult>;
	rows(id: string, worker: string, after: number, limit: number): Promise<RowsPage>;
	finalize(
		id: string,
		worker: string,
		file: {
			rowCount: number;
			pageCount: number | null;
			byteSize: number;
			sha256: string;
			hasPreview: boolean;
		}
	): Promise<{ status: string }>;
	fail(id: string, worker: string, reason: FailReason): Promise<void>;
}

export interface RunnerDeps {
	readonly client: WorkerClient;
	readonly storage: ExportStorage;
	readonly renderer: PdfRenderer;
	readonly log: (entry: Record<string, unknown>) => void;
	readonly pageSize?: number;
}

export interface JobOutcome {
	readonly exportId: string;
	readonly status: 'ready' | 'too_large' | 'failed';
	readonly reason?: string;
}

/** The edge client for the exports-worker steps (secret, never a user token). */
export function edgeWorkerClient(options: {
	supabaseUrl: string;
	publishableKey: string;
	secret: string;
	fetch: typeof globalThis.fetch;
}): WorkerClient {
	const call = <S extends Schema.ConstraintDecoder<unknown>>(
		method: 'GET' | 'POST',
		path: string,
		schema: S,
		body?: unknown
	): Promise<S['Type']> =>
		Effect.runPromise(
			requestJson(
				{
					fetch: options.fetch,
					url: new URL(`/functions/v1/exports-worker${path}`, options.supabaseUrl).toString(),
					method,
					route: `${method} /exports-worker${path.replace(/[0-9a-f-]{36}/, ':id').replace(/\?.*$/, '')}`,
					headers: { apikey: options.publishableKey, authorization: `Bearer ${options.secret}` },
					body,
					timeoutMs: 60_000
				},
				schema
			)
		);
	return {
		claim: async (worker) => (await call('POST', '/claim', ClaimResult, { worker })).job,
		prepare: (id, worker) => call('POST', `/${id}/prepare`, PrepareResult, { worker }),
		rows: (id, worker, after, limit) =>
			call(
				'GET',
				`/${id}/rows?${new URLSearchParams({ worker, after: String(after), limit: String(limit) })}`,
				RowsPage
			),
		finalize: (id, worker, file) =>
			call('POST', `/${id}/finalize`, StepResult, { worker, ...file }),
		fail: async (id, worker, reason) => {
			await call('POST', `/${id}/fail`, StepResult, { worker, reason });
		}
	};
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
	const digest = new Uint8Array(
		await crypto.subtle.digest('SHA-256', bytes.slice().buffer as ArrayBuffer)
	);
	return Array.from(digest, (b) => b.toString(16).padStart(2, '0')).join('');
}

const decode = <S extends Schema.ConstraintDecoder<unknown>>(
	schema: S,
	value: unknown
): S['Type'] => {
	try {
		return Schema.decodeUnknownSync(schema as never)(value) as S['Type'];
	} catch {
		throw new StepFailure('read_failed');
	}
};

/** Every prepared row, in order, or a StepFailure: never a partial list. */
export async function readAllRows(
	client: WorkerClient,
	id: string,
	worker: string,
	rowCount: number,
	pageSize: number
): Promise<RowsPage['rows']> {
	const rows: RowsPage['rows'][number][] = [];
	let after = 0;
	while (rows.length < rowCount) {
		let page: RowsPage;
		try {
			page = await client.rows(id, worker, after, pageSize);
		} catch {
			throw new StepFailure('read_failed');
		}
		if (page.rowCount !== rowCount || page.rows.length === 0) throw new StepFailure('incomplete');
		for (const row of page.rows) {
			if (row.seq !== after + 1) throw new StepFailure('incomplete');
			rows.push(row);
			after = row.seq;
		}
	}
	if (rows.length !== rowCount) throw new StepFailure('incomplete');
	return rows;
}

const encoder = new TextEncoder();

async function build(
	job: ClaimedJob,
	summary: unknown,
	rows: RowsPage['rows'],
	renderer: PdfRenderer
): Promise<{ bytes: Uint8Array; pages: number | null; preview: Uint8Array | null; type: string }> {
	const txns = () => rows.map((r) => decode(TxnRow, r.data));
	const members = () => rows.map((r) => decode(MemberFigure, r.data));
	switch (job.kind) {
		case 'statement_csv':
			return {
				bytes: encoder.encode(statementCsv(decode(StatementSummary, summary), txns())),
				pages: null,
				preview: null,
				type: 'text/csv; charset=utf-8'
			};
		case 'transactions_csv':
			return {
				bytes: encoder.encode(transactionsCsv(decode(ReportSummary, summary), txns())),
				pages: null,
				preview: null,
				type: 'text/csv; charset=utf-8'
			};
		case 'member_balances_csv':
			return {
				bytes: encoder.encode(memberBalancesCsv(decode(ReportSummary, summary), members())),
				pages: null,
				preview: null,
				type: 'text/csv; charset=utf-8'
			};
		case 'statement_pdf':
		case 'office_pdf': {
			const html =
				job.kind === 'statement_pdf'
					? statementHtml(decode(StatementSummary, summary), txns())
					: reportHtml(decode(ReportSummary, summary), members());
			try {
				const out = await renderer.render(html, { preview: job.kind === 'statement_pdf' });
				if (out.pages < 1) throw new Error('empty pdf');
				return { bytes: out.pdf, pages: out.pages, preview: out.preview, type: 'application/pdf' };
			} catch {
				throw new StepFailure('render_failed');
			}
		}
	}
}

export async function runJob(
	deps: RunnerDeps,
	job: ClaimedJob,
	worker: string
): Promise<JobOutcome> {
	const id = job.exportId;
	const stored: string[] = [];
	try {
		let prepared: PrepareResult;
		try {
			prepared = await deps.client.prepare(id, worker);
		} catch {
			throw new StepFailure('read_failed');
		}
		if (prepared.status === 'too_large') return { exportId: id, status: 'too_large' };
		if (prepared.status === 'failed')
			return { exportId: id, status: 'failed', reason: prepared.failReason ?? 'failed' };
		const rowCount = prepared.rowCount ?? -1;
		if (rowCount < 0) throw new StepFailure('read_failed');

		const rows = await readAllRows(deps.client, id, worker, rowCount, deps.pageSize ?? 1000);
		const file = await build(job, prepared.summary, rows, deps.renderer);

		try {
			await deps.storage.put(job.objectKey, file.bytes, file.type);
			stored.push(job.objectKey);
			if (file.preview) {
				await deps.storage.put(`${job.objectKey}.png`, file.preview, 'image/png');
				stored.push(`${job.objectKey}.png`);
			}
		} catch {
			throw new StepFailure('storage_failed');
		}

		const done = await deps.client.finalize(id, worker, {
			rowCount: rows.length,
			pageCount: file.pages,
			byteSize: file.bytes.length,
			sha256: await sha256Hex(file.bytes),
			hasPreview: file.preview !== null
		});
		if (done.status !== 'ready') {
			await Promise.allSettled(stored.map((key) => deps.storage.delete(key)));
			return { exportId: id, status: 'failed', reason: 'incomplete' };
		}
		return { exportId: id, status: 'ready' };
	} catch (error) {
		const reason: FailReason = error instanceof StepFailure ? error.reason : 'render_failed';
		await Promise.allSettled(stored.map((key) => deps.storage.delete(key)));
		try {
			await deps.client.fail(id, worker, reason);
		} catch {
			// The lease runs out and the next run retries or fails it (3 attempts).
		}
		deps.log({ exportId: id, outcome: 'failed', reason });
		return { exportId: id, status: 'failed', reason };
	}
}

/** Works through waiting jobs until none are left or the time budget is spent. */
export async function runExports(deps: RunnerDeps, budgetMs = 100_000): Promise<JobOutcome[]> {
	const worker = `app:${crypto.randomUUID()}`;
	const started = Date.now();
	const outcomes: JobOutcome[] = [];
	while (Date.now() - started < budgetMs) {
		const job = await deps.client.claim(worker);
		if (!job) break;
		const outcome = await runJob(deps, job, worker);
		deps.log({ exportId: outcome.exportId, outcome: outcome.status, reason: outcome.reason });
		outcomes.push(outcome);
	}
	return outcomes;
}
