// Restore validation (Blueprint 18 — B3, owner answer Q7 "guided manual
// restore"). Re-reads a Team Backup Vault archive from private storage and
// checks it end to end in one streaming pass: the whole-archive SHA-256 and
// size, then each NDJSON file's SHA-256 and row count against what the
// database recorded at finalize. Section rows are staged in batches for the
// read-only comparison. Nothing is ever written back to the network.
//
// The archive is the runner's own format (zip.ts): deflated entries with data
// descriptors (bit 3), so the compressed size follows the data. The reader
// finds each entry's end at the descriptor whose compressed size matches the
// bytes read so far, then checks its CRC-32 and size; any other layout fails
// as unreadable. Nothing holds the whole archive in memory.

import { createHash } from 'node:crypto';
import type { RequestEvent } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import type { RestoreSource } from '#lib/contract/admin.js';
import { AdminApi } from '../apis-admin';
import type { VerifiedSession } from '../auth';
import type { EdgeFailure } from '../edge';
import { failureOf } from '../flow';
import { runApi } from '../request';
import { backupStorage } from './storage';
import { crc32 } from './zip';

export type RestoreFailReason =
	| 'archive_missing'
	| 'archive_checksum_mismatch'
	| 'file_checksum_mismatch'
	| 'row_count_mismatch'
	| 'archive_unreadable';

export interface SectionReport {
	readonly section: string;
	readonly rows: number;
	readonly sha256Ok: boolean;
}

export interface RestoreReport {
	readonly ok: boolean;
	readonly failReason: RestoreFailReason | null;
	readonly sections: SectionReport[];
}

export type ArchiveBody = ReadableStream<Uint8Array> | Uint8Array;

export interface RestoreCheckDeps {
	/** What the database recorded for this archive (admin_restore_source). */
	readonly source: Pick<RestoreSource, 'byteSize' | 'sha256' | 'files'>;
	/** The archive bytes, or null when the file is gone. */
	readonly archive: ArchiveBody | null;
	/** Stages up to `batchSize` parsed rows of one section. */
	readonly sendRows: (section: string, rows: Record<string, unknown>[]) => Promise<void>;
	readonly batchSize?: number;
}

/** A failure that is the archive's fault (reported, never thrown out). */
class ArchiveError extends Error {
	constructor(readonly reason: RestoreFailReason) {
		super(reason);
	}
}

/** A staging call failed: not the archive's fault, so the run stops without a verdict. */
export class StagingError extends Error {
	constructor(readonly cause: unknown) {
		super('restore rows could not be staged');
	}
}

const LOCAL = 0x04034b50;
const DESCRIPTOR = 0x08074b50;
const CENTRAL = 0x02014b50;
const SECTION_FILE = /^([a-z_]{2,40})\.ndjson$/;
/** Batches stay well under the Edge body limit even with large rows. */
const BATCH_BYTES = 1_500_000;

const u16 = (b: Uint8Array, at: number) => (b[at] ?? 0) | ((b[at + 1] ?? 0) << 8);
const u32 = (b: Uint8Array, at: number) =>
	((b[at] ?? 0) | ((b[at + 1] ?? 0) << 8) | ((b[at + 2] ?? 0) << 16) | ((b[at + 3] ?? 0) << 24)) >>>
	0;

/** One entry's inflated bytes: checksum, CRC, size and NDJSON rows. */
class EntryReader {
	readonly #sha = createHash('sha256');
	#crc = 0;
	#size = 0;
	#rows = 0;
	#line = '';
	#batch: Record<string, unknown>[] = [];
	#batchBytes = 0;
	readonly #decoder = new TextDecoder('utf-8', { fatal: true });
	readonly #input: WritableStreamDefaultWriter<Uint8Array>;
	readonly #pump: Promise<void>;

	constructor(
		readonly name: string,
		readonly section: string | null,
		private readonly deps: RestoreCheckDeps
	) {
		const inflate = new DecompressionStream('deflate-raw');
		this.#input = inflate.writable.getWriter() as WritableStreamDefaultWriter<Uint8Array>;
		const reader = inflate.readable.getReader();
		this.#pump = (async () => {
			for (;;) {
				const { done, value } = await reader.read();
				if (done) break;
				await this.#take(value);
			}
		})();
		// Errors surface through close(); avoid an unhandled rejection meanwhile.
		this.#pump.catch(() => undefined);
	}

	async #take(bytes: Uint8Array): Promise<void> {
		this.#sha.update(bytes);
		this.#crc = crc32(bytes, this.#crc);
		this.#size += bytes.length;
		if (this.section === null) return;
		this.#line += this.#decoder.decode(bytes, { stream: true });
		let cut = this.#line.indexOf('\n');
		while (cut >= 0) {
			await this.#row(this.#line.slice(0, cut));
			this.#line = this.#line.slice(cut + 1);
			cut = this.#line.indexOf('\n');
		}
	}

	async #row(line: string): Promise<void> {
		let data: unknown;
		try {
			data = JSON.parse(line);
		} catch {
			throw new ArchiveError('archive_unreadable');
		}
		if (typeof data !== 'object' || data === null || Array.isArray(data)) {
			throw new ArchiveError('archive_unreadable');
		}
		this.#rows += 1;
		this.#batch.push(data as Record<string, unknown>);
		this.#batchBytes += line.length;
		if (this.#batch.length >= (this.deps.batchSize ?? 1000) || this.#batchBytes >= BATCH_BYTES) {
			await this.#flush();
		}
	}

	async #flush(): Promise<void> {
		if (this.section === null || this.#batch.length === 0) return;
		const rows = this.#batch;
		this.#batch = [];
		this.#batchBytes = 0;
		try {
			await this.deps.sendRows(this.section, rows);
		} catch (error) {
			throw new StagingError(error);
		}
	}

	async write(bytes: Uint8Array): Promise<void> {
		if (bytes.length === 0) return;
		await this.#input.ready;
		// The pump may have failed (bad row, staging error): stop feeding it.
		await Promise.race([this.#input.write(bytes as Uint8Array<ArrayBuffer>), this.#pump]);
	}

	/** Ends the entry; checks the descriptor's CRC and size. */
	async close(crc: number, size: number): Promise<{ rows: number; sha256: string; text: string }> {
		await this.#input.close();
		await this.#pump;
		if (this.#crc !== crc || this.#size !== size) throw new ArchiveError('archive_unreadable');
		const rest = this.#line + this.#decoder.decode();
		if (this.section !== null && rest !== '') {
			// NDJSON files end with a newline; a trailing partial line is damage.
			throw new ArchiveError('archive_unreadable');
		}
		await this.#flush();
		return { rows: this.#rows, sha256: this.#sha.digest('hex'), text: rest };
	}

	abort(): void {
		this.#input.abort().catch(() => undefined);
	}
}

async function* chunks(body: ArchiveBody): AsyncGenerator<Uint8Array> {
	if (body instanceof Uint8Array) {
		// Feed local files in slices too, so both paths share one code path.
		for (let at = 0; at < body.length; at += 64 * 1024) yield body.subarray(at, at + 64 * 1024);
		return;
	}
	const reader = body.getReader();
	try {
		for (;;) {
			const { done, value } = await reader.read();
			if (done) return;
			if (value && value.length > 0) yield value;
		}
	} finally {
		reader.releaseLock();
	}
}

interface FileResult {
	readonly name: string;
	readonly section: string | null;
	readonly rows: number;
	readonly sha256: string;
}

/**
 * Walks the archive bytes: local header → deflated data → data descriptor,
 * until the central directory. Every byte (central directory included) goes
 * into the archive hash; parsing stops at the first damage but the hash still
 * reads to the end so a changed archive reports as a checksum mismatch.
 */
async function walk(
	deps: RestoreCheckDeps,
	body: ArchiveBody
): Promise<{ files: FileResult[]; sha256: string; byteSize: number; error: unknown }> {
	const hash = createHash('sha256');
	let byteSize = 0;
	const files: FileResult[] = [];
	let error: unknown = null;

	let buffer = new Uint8Array(0);
	let mode = 'header' as 'header' | 'data' | 'done';
	let entry: EntryReader | null = null;
	let compressed = 0;

	const take = (n: number) => {
		const out = buffer.subarray(0, n);
		buffer = buffer.subarray(n);
		return out;
	};

	const step = async (final: boolean): Promise<boolean> => {
		if (mode === 'header') {
			if (buffer.length < 4) {
				if (final) throw new ArchiveError('archive_unreadable');
				return false;
			}
			const signature = u32(buffer, 0);
			if (signature === CENTRAL) {
				if (files.length === 0) throw new ArchiveError('archive_unreadable');
				mode = 'done';
				return false;
			}
			if (signature !== LOCAL) throw new ArchiveError('archive_unreadable');
			if (buffer.length < 30) {
				if (final) throw new ArchiveError('archive_unreadable');
				return false;
			}
			const flags = u16(buffer, 6);
			const method = u16(buffer, 8);
			const nameLength = u16(buffer, 26);
			const extraLength = u16(buffer, 28);
			if (method !== 8 || (flags & 0x0008) === 0 || (flags & 0x0001) !== 0) {
				throw new ArchiveError('archive_unreadable');
			}
			if (buffer.length < 30 + nameLength + extraLength) {
				if (final) throw new ArchiveError('archive_unreadable');
				return false;
			}
			take(30);
			let name: string;
			try {
				name = new TextDecoder('utf-8', { fatal: true }).decode(take(nameLength));
			} catch {
				throw new ArchiveError('archive_unreadable');
			}
			take(extraLength);
			if (files.some((f) => f.name === name)) throw new ArchiveError('archive_unreadable');
			const match = SECTION_FILE.exec(name);
			if (!match && name !== 'manifest.json') throw new ArchiveError('file_checksum_mismatch');
			entry = new EntryReader(name, match?.[1] ?? null, deps);
			compressed = 0;
			mode = 'data';
			return true;
		}
		if (mode === 'data' && entry) {
			// The descriptor: signature, CRC, compressed size (= bytes so far), size.
			for (let i = 0; i + 16 <= buffer.length; i++) {
				if (u32(buffer, i) === DESCRIPTOR && u32(buffer, i + 8) === compressed + i) {
					await entry.write(take(i));
					const descriptor = take(16);
					const done = await entry.close(u32(descriptor, 4), u32(descriptor, 12));
					files.push({ name: entry.name, section: entry.section, ...done });
					entry = null;
					mode = 'header';
					return true;
				}
			}
			if (final) throw new ArchiveError('archive_unreadable');
			// Keep 15 bytes back: a descriptor may straddle the next chunk.
			const safe = Math.max(0, buffer.length - 15);
			if (safe > 0) {
				compressed += safe;
				await entry.write(take(safe));
			}
			return false;
		}
		return false;
	};

	for await (const chunk of chunks(body)) {
		hash.update(chunk);
		byteSize += chunk.length;
		if (error !== null || mode === 'done') continue;
		const joined = new Uint8Array(buffer.length + chunk.length);
		joined.set(buffer, 0);
		joined.set(chunk, buffer.length);
		buffer = joined;
		try {
			while (await step(false));
		} catch (caught) {
			error = caught;
			(entry as EntryReader | null)?.abort();
			buffer = new Uint8Array(0);
		}
	}
	if (error === null && mode !== 'done') {
		try {
			while (await step(true));
			if ((mode as string) !== 'done') throw new ArchiveError('archive_unreadable');
		} catch (caught) {
			error = caught;
			(entry as EntryReader | null)?.abort();
		}
	}
	return { files, sha256: hash.digest('hex'), byteSize, error };
}

/** Checks one archive against its recorded manifest; stages rows as it goes. */
export async function checkArchive(deps: RestoreCheckDeps): Promise<RestoreReport> {
	if (deps.archive === null) {
		return { ok: false, failReason: 'archive_missing', sections: [] };
	}
	let result: Awaited<ReturnType<typeof walk>>;
	try {
		result = await walk(deps, deps.archive);
	} catch {
		// The stream itself broke (storage read failed mid-way).
		return { ok: false, failReason: 'archive_unreadable', sections: [] };
	}
	if (result.error instanceof StagingError) throw result.error;

	const expected = new Map(deps.source.files.map((f) => [f.section, f]));
	const sections: SectionReport[] = result.files
		.filter((f) => f.section !== null)
		.map((f) => ({
			section: f.section!,
			rows: f.rows,
			sha256Ok: expected.get(f.section!)?.sha256 === f.sha256
		}));
	const fail = (failReason: RestoreFailReason): RestoreReport => ({
		ok: false,
		failReason,
		sections
	});

	if (result.sha256 !== deps.source.sha256 || result.byteSize !== deps.source.byteSize) {
		return fail('archive_checksum_mismatch');
	}
	if (result.error !== null) {
		return fail(result.error instanceof ArchiveError ? result.error.reason : 'archive_unreadable');
	}
	if (!result.files.some((f) => f.name === 'manifest.json')) return fail('archive_unreadable');
	if (sections.length !== expected.size || sections.some((s) => !s.sha256Ok)) {
		return fail('file_checksum_mismatch');
	}
	if (sections.some((s) => expected.get(s.section)?.rows !== s.rows)) {
		return fail('row_count_mismatch');
	}
	return { ok: true, failReason: null, sections };
}

export type ValidationOutcome =
	| { readonly ok: true; readonly passed: boolean; readonly failReason: RestoreFailReason | null }
	| { readonly ok: false; readonly failure: EdgeFailure | null };

/**
 * One validation run for a restore in `validating` (admin site, platform
 * admins only; the database checks the role on every call). Ends the run
 * with admin_restore_validated: in review, or failed with a safe reason. A
 * staging or transport failure leaves the request in validating so it can
 * be run again.
 */
export async function validateRestore(
	event: RequestEvent,
	session: VerifiedSession,
	restoreId: string
): Promise<ValidationOutcome> {
	const run = async <A>(
		program: Effect.Effect<A, EdgeFailure, AdminApi>
	): Promise<{ ok: true; value: A } | { ok: false; failure: EdgeFailure }> => {
		const exit = await runApi(event, session, program);
		return Exit.isSuccess(exit)
			? { ok: true, value: exit.value }
			: { ok: false, failure: failureOf(exit) };
	};

	const source = await run(
		Effect.gen(function* () {
			return yield* (yield* AdminApi).restoreSource(restoreId);
		})
	);
	if (!source.ok) return { ok: false, failure: source.failure };

	let archive: ArchiveBody | null = null;
	let storageMissing = false;
	try {
		const storage = await backupStorage();
		if (!storage) storageMissing = true;
		else archive = ((await storage.get(source.value.objectKey))?.body as ArchiveBody) ?? null;
	} catch {
		archive = null;
	}
	// No bucket on this deployment: that is configuration, not a missing archive.
	if (storageMissing) return { ok: false, failure: null };

	let report: RestoreReport;
	try {
		report = await checkArchive({
			source: source.value,
			archive,
			sendRows: async (section, rows) => {
				const sent = await run(
					Effect.gen(function* () {
						return yield* (yield* AdminApi).restoreRows(restoreId, section, rows);
					})
				);
				if (!sent.ok) throw sent.failure;
			}
		});
	} catch (error) {
		const cause = error instanceof StagingError ? error.cause : null;
		return { ok: false, failure: (cause as EdgeFailure | null) ?? null };
	}

	const done = await run(
		Effect.gen(function* () {
			return yield* (yield* AdminApi).restoreValidated(restoreId, report);
		})
	);
	if (!done.ok) return { ok: false, failure: done.failure };
	// The database re-counts the staged rows and may still fail the run.
	const passed = report.ok && done.value.ok !== false;
	return {
		ok: true,
		passed,
		failReason: passed ? null : (report.failReason ?? 'row_count_mismatch')
	};
}
