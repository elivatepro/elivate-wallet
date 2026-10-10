// The backup runner (Blueprint 17 — B3, W-24). Runs beside the export runner
// (pg_cron/pg_net and the app server after "Back up now" call it): claim a
// backup, have Postgres snapshot the network in one transaction, page through
// the rows, write one NDJSON file per section plus manifest.json into a ZIP
// streamed to private R2, then finalize. Complete or fail: any gap, short page
// or error fails the backup, and it is ready only if the database confirms
// every row and every file count. Expired archives' files are removed here.

import { Effect, Schema } from 'effect';
import { requestJson } from '#lib/contract/transport.js';
import type { BackupStorage } from './storage';
import { ZipWriter, type EntryWriter } from './zip';

export type BackupFailReason = 'read_failed' | 'storage_failed' | 'incomplete' | 'timeout';

class StepFailure extends Error {
	constructor(readonly reason: BackupFailReason) {
		super(reason);
	}
}

const Job = Schema.Struct({
	backupId: Schema.String,
	objectKey: Schema.String,
	attempt: Schema.Int
});
export type BackupJob = typeof Job.Type;

const Claim = Schema.Struct({ job: Schema.NullOr(Job) });

const Prepared = Schema.Struct({
	status: Schema.Literals(['building', 'too_large', 'failed']),
	recordCount: Schema.optional(Schema.Int),
	counts: Schema.optional(Schema.Record(Schema.String, Schema.Int)),
	network: Schema.optional(Schema.Struct({ tenantId: Schema.String, name: Schema.String })),
	formatVersion: Schema.optional(Schema.Int),
	takenAt: Schema.optional(Schema.String),
	failReason: Schema.optional(Schema.String)
});
export type Prepared = typeof Prepared.Type;

const Row = Schema.Struct({
	seq: Schema.Int,
	section: Schema.String.check(Schema.isPattern(/^[a-z_]{2,40}$/)),
	data: Schema.Record(Schema.String, Schema.Unknown)
});
const Page = Schema.Struct({ rows: Schema.Array(Row), recordCount: Schema.Int });
export type RowsPage = typeof Page.Type;

const Step = Schema.Struct({ status: Schema.String });

const Expired = Schema.Struct({
	items: Schema.Array(
		Schema.Struct({ backupId: Schema.String, objectKeys: Schema.Array(Schema.String) })
	)
});
export type ExpiredList = typeof Expired.Type;

export interface FileEntry {
	readonly section: string;
	readonly rows: number;
	readonly sha256: string;
}

export interface BackupClient {
	claim(worker: string): Promise<BackupJob | null>;
	prepare(id: string, worker: string): Promise<Prepared>;
	rows(id: string, worker: string, after: number, limit: number): Promise<RowsPage>;
	finalize(
		id: string,
		worker: string,
		file: { recordCount: number; byteSize: number; sha256: string; files: FileEntry[] }
	): Promise<{ status: string }>;
	fail(id: string, worker: string, reason: BackupFailReason): Promise<void>;
	expired(): Promise<ExpiredList>;
	deleted(id: string): Promise<void>;
}

export interface BackupRunnerDeps {
	readonly client: BackupClient;
	readonly storage: BackupStorage;
	readonly log: (entry: Record<string, unknown>) => void;
	readonly pageSize?: number;
}

export interface BackupOutcome {
	readonly backupId: string;
	readonly status: 'ready' | 'too_large' | 'failed';
	readonly reason?: string;
}

/** The edge client for the backup steps (worker secret, never a user token). */
export function edgeBackupClient(options: {
	supabaseUrl: string;
	publishableKey: string;
	secret: string;
	fetch: typeof globalThis.fetch;
}): BackupClient {
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
					url: new URL(
						`/functions/v1/exports-worker/backups${path}`,
						options.supabaseUrl
					).toString(),
					method,
					route: `${method} /exports-worker/backups${path.replace(/[0-9a-f-]{36}/, ':id').replace(/\?.*$/, '')}`,
					headers: { apikey: options.publishableKey, authorization: `Bearer ${options.secret}` },
					body,
					timeoutMs: 60_000
				},
				schema
			)
		);
	return {
		claim: async (worker) => (await call('POST', '/claim', Claim, { worker })).job,
		prepare: (id, worker) => call('POST', `/${id}/prepare`, Prepared, { worker }),
		rows: (id, worker, after, limit) =>
			call(
				'GET',
				`/${id}/rows?${new URLSearchParams({ worker, after: String(after), limit: String(limit) })}`,
				Page
			),
		finalize: (id, worker, file) => call('POST', `/${id}/finalize`, Step, { worker, ...file }),
		fail: async (id, worker, reason) => {
			await call('POST', `/${id}/fail`, Step, { worker, reason });
		},
		expired: () => call('GET', '/expired', Expired),
		deleted: async (id) => {
			await call('POST', `/${id}/deleted`, Step, {});
		}
	};
}

const encoder = new TextEncoder();

/** What a backup never contains (W-24), stated in every manifest. */
export const EXCLUDED = [
	'passwords and PINs',
	'sessions and sign-in records',
	'Auth, integration and payment-provider secrets',
	'NIN numbers',
	'full bank account numbers (last 4 digits only)',
	'evidence files (listed with name, size and SHA-256)',
	'other networks'
];

/**
 * Pages through every prepared row in seq order, writing each section to its
 * own NDJSON file. Throws a StepFailure on any gap: never a partial archive.
 */
async function writeSections(
	deps: BackupRunnerDeps,
	zip: ZipWriter,
	id: string,
	worker: string,
	recordCount: number
): Promise<FileEntry[]> {
	const files: FileEntry[] = [];
	let section: string | null = null;
	let writer: EntryWriter | null = null;
	let rows = 0;
	const closeCurrent = async () => {
		if (section === null || writer === null) return;
		const { sha256 } = await writer.close();
		files.push({ section, rows, sha256 });
		section = null;
		writer = null;
		rows = 0;
	};
	let after = 0;
	while (after < recordCount) {
		let page: RowsPage;
		try {
			page = await deps.client.rows(id, worker, after, deps.pageSize ?? 2000);
		} catch {
			throw new StepFailure('read_failed');
		}
		if (page.recordCount !== recordCount || page.rows.length === 0) {
			throw new StepFailure('incomplete');
		}
		for (const row of page.rows) {
			if (row.seq !== after + 1) throw new StepFailure('incomplete');
			after = row.seq;
			if (row.section !== section) {
				// Sections arrive grouped; one seen twice means the rows are out of order.
				if (files.some((f) => f.section === row.section)) throw new StepFailure('incomplete');
				await closeCurrent();
				section = row.section;
				writer = await zip.entry(`${row.section}.ndjson`);
			}
			await writer!.write(encoder.encode(`${JSON.stringify(row.data)}\n`));
			rows += 1;
		}
	}
	await closeCurrent();
	return files;
}

export async function runBackup(
	deps: BackupRunnerDeps,
	job: BackupJob,
	worker: string
): Promise<BackupOutcome> {
	const id = job.backupId;
	let upload: Awaited<ReturnType<BackupStorage['upload']>> | null = null;
	let stored = false;
	try {
		let prepared: Prepared;
		try {
			prepared = await deps.client.prepare(id, worker);
		} catch {
			throw new StepFailure('read_failed');
		}
		if (prepared.status === 'too_large') return { backupId: id, status: 'too_large' };
		if (prepared.status === 'failed') {
			return { backupId: id, status: 'failed', reason: prepared.failReason ?? 'failed' };
		}
		const recordCount = prepared.recordCount ?? -1;
		if (recordCount < 0 || !prepared.counts) throw new StepFailure('read_failed');

		try {
			upload = await deps.storage.upload(job.objectKey);
		} catch {
			throw new StepFailure('storage_failed');
		}
		const target = upload;
		const zip = new ZipWriter(async (bytes) => {
			try {
				await target.write(bytes);
			} catch {
				throw new StepFailure('storage_failed');
			}
		});
		const files = await writeSections(deps, zip, id, worker, recordCount);
		const counted = Object.fromEntries(files.map((f) => [f.section, f.rows]));
		for (const [section, rows] of Object.entries(prepared.counts)) {
			if (counted[section] !== rows) throw new StepFailure('incomplete');
		}
		if (files.length !== Object.keys(prepared.counts).length) throw new StepFailure('incomplete');

		const manifestWriter = await zip.entry('manifest.json');
		await manifestWriter.write(
			encoder.encode(
				JSON.stringify(
					{
						formatVersion: prepared.formatVersion ?? 1,
						backupId: id,
						network: prepared.network ?? null,
						takenAt: prepared.takenAt ?? null,
						recordCount,
						files: files.map((f) => ({
							name: `${f.section}.ndjson`,
							section: f.section,
							rows: f.rows,
							sha256: f.sha256
						})),
						excluded: EXCLUDED
					},
					null,
					2
				)
			)
		);
		await manifestWriter.close();
		const archive = await zip.finish();
		try {
			await target.complete();
			stored = true;
		} catch {
			throw new StepFailure('storage_failed');
		}

		let done: { status: string };
		try {
			done = await deps.client.finalize(id, worker, {
				recordCount,
				byteSize: archive.byteSize,
				sha256: archive.sha256,
				files
			});
		} catch {
			// Unknown outcome: only a fail the database accepts proves the file is unused.
			try {
				await deps.client.fail(id, worker, 'storage_failed');
			} catch {
				deps.log({ backupId: id, outcome: 'finalize_unknown' });
				return { backupId: id, status: 'failed', reason: 'finalize_unknown' };
			}
			await deps.storage.delete(job.objectKey).catch(() => undefined);
			return { backupId: id, status: 'failed', reason: 'storage_failed' };
		}
		if (done.status !== 'ready') {
			await deps.storage.delete(job.objectKey).catch(() => undefined);
			return { backupId: id, status: 'failed', reason: 'incomplete' };
		}
		return { backupId: id, status: 'ready' };
	} catch (error) {
		const reason: BackupFailReason = error instanceof StepFailure ? error.reason : 'storage_failed';
		if (stored) await deps.storage.delete(job.objectKey).catch(() => undefined);
		else await upload?.abort().catch(() => undefined);
		try {
			await deps.client.fail(id, worker, reason);
		} catch {
			// The lease runs out and the next run retries or fails it (3 attempts).
		}
		deps.log({ backupId: id, outcome: 'failed', reason });
		return { backupId: id, status: 'failed', reason };
	}
}

/** Removes the files of expired archives (90 days, owner answer Q2) and of failed ones. */
export async function removeExpired(deps: BackupRunnerDeps): Promise<number> {
	let removed = 0;
	const list = await deps.client.expired();
	for (const item of list.items) {
		try {
			for (const key of item.objectKeys) await deps.storage.delete(key);
			await deps.client.deleted(item.backupId);
			removed += 1;
		} catch {
			deps.log({ backupId: item.backupId, outcome: 'delete_failed' });
		}
	}
	return removed;
}

/** Works through waiting backups until none are left or the time budget is spent. */
export async function runBackups(
	deps: BackupRunnerDeps,
	budgetMs = 100_000
): Promise<BackupOutcome[]> {
	const worker = `app:${crypto.randomUUID()}`;
	const started = Date.now();
	const outcomes: BackupOutcome[] = [];
	while (Date.now() - started < budgetMs) {
		const job = await deps.client.claim(worker);
		if (!job) break;
		const outcome = await runBackup(deps, job, worker);
		deps.log({ backupId: outcome.backupId, outcome: outcome.status, reason: outcome.reason });
		outcomes.push(outcome);
	}
	await removeExpired(deps).catch(() => 0);
	return outcomes;
}
