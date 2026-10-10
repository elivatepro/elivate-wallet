import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { checkArchive, StagingError, type RestoreCheckDeps } from './restore-check';
import { ZipWriter } from './zip';

const encoder = new TextEncoder();

interface Built {
	bytes: Uint8Array;
	sha256: string;
	files: { section: string; rows: number; sha256: string }[];
}

/** An archive in the runner's layout: one NDJSON file per section, then manifest.json. */
async function build(sections: Record<string, Record<string, unknown>[]>): Promise<Built> {
	const chunks: Uint8Array[] = [];
	const zip = new ZipWriter(async (b) => {
		chunks.push(b.slice());
	});
	const files: Built['files'] = [];
	for (const [section, rows] of Object.entries(sections)) {
		const entry = await zip.entry(`${section}.ndjson`);
		for (const row of rows) await entry.write(encoder.encode(`${JSON.stringify(row)}\n`));
		const { sha256 } = await entry.close();
		files.push({ section, rows: rows.length, sha256 });
	}
	const manifest = await zip.entry('manifest.json');
	await manifest.write(encoder.encode(JSON.stringify({ formatVersion: 1, files })));
	await manifest.close();
	const { sha256 } = await zip.finish();
	const bytes = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
	let at = 0;
	for (const c of chunks) {
		bytes.set(c, at);
		at += c.length;
	}
	return { bytes, sha256, files };
}

/** Streams bytes in small, uneven chunks so descriptors straddle chunk edges. */
function stream(bytes: Uint8Array, size = 7): ReadableStream<Uint8Array> {
	let at = 0;
	return new ReadableStream({
		pull(controller) {
			if (at >= bytes.length) return controller.close();
			const n = size + (at % 5);
			controller.enqueue(bytes.slice(at, at + n));
			at += n;
		}
	});
}

const sha = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');

function deps(
	built: Built,
	archive: RestoreCheckDeps['archive'],
	overrides: Partial<RestoreCheckDeps> = {}
) {
	const staged: { section: string; rows: Record<string, unknown>[] }[] = [];
	const d: RestoreCheckDeps = {
		source: { byteSize: built.bytes.length, sha256: built.sha256, files: built.files },
		archive,
		sendRows: async (section, rows) => {
			staged.push({ section, rows });
		},
		batchSize: 3,
		...overrides
	};
	return { d, staged };
}

const offices = Array.from({ length: 7 }, (_, i) => ({ id: `office-${i}`, name: `Office ${i}` }));
const transactions = Array.from({ length: 40 }, (_, i) => ({
	id: `txn-${i}`,
	amount: `${1000 + i}.00`,
	memo: 'x'.repeat(i * 13)
}));

describe('checkArchive', () => {
	it('round-trips a runner archive: checksums, row counts and batched rows', async () => {
		const built = await build({ offices, transactions });
		expect(sha(built.bytes)).toBe(built.sha256);
		const { d, staged } = deps(built, stream(built.bytes));
		const report = await checkArchive(d);
		expect(report).toEqual({
			ok: true,
			failReason: null,
			sections: [
				{ section: 'offices', rows: 7, sha256Ok: true },
				{ section: 'transactions', rows: 40, sha256Ok: true }
			]
		});
		expect(staged.every((b) => b.rows.length <= 3)).toBe(true);
		expect(staged.filter((b) => b.section === 'offices').flatMap((b) => b.rows)).toEqual(offices);
		expect(staged.filter((b) => b.section === 'transactions').flatMap((b) => b.rows)).toEqual(
			transactions
		);
	});

	it('reads a local file (bytes) the same way', async () => {
		const built = await build({ offices });
		const { d } = deps(built, built.bytes);
		expect((await checkArchive(d)).ok).toBe(true);
	});

	it('reports a changed byte as an archive checksum mismatch', async () => {
		const built = await build({ offices, transactions });
		const tampered = built.bytes.slice();
		const middle = Math.floor(tampered.length / 2);
		tampered[middle] = (tampered[middle] ?? 0) ^ 0x01;
		const { d } = deps(built, stream(tampered));
		const report = await checkArchive(d);
		expect(report.ok).toBe(false);
		expect(report.failReason).toBe('archive_checksum_mismatch');
	});

	it('reports a file whose checksum differs from the manifest', async () => {
		const built = await build({ offices, transactions });
		const files = built.files.map((f) =>
			f.section === 'offices' ? { ...f, sha256: 'a'.repeat(64) } : f
		);
		const { d } = deps(built, stream(built.bytes), {
			source: { byteSize: built.bytes.length, sha256: built.sha256, files }
		});
		const report = await checkArchive(d);
		expect(report.failReason).toBe('file_checksum_mismatch');
		expect(report.sections.find((s) => s.section === 'offices')?.sha256Ok).toBe(false);
	});

	it('reports a missing row as a row count mismatch', async () => {
		// The archive holds 6 offices; the database recorded 7.
		const built = await build({ offices: offices.slice(0, 6), transactions });
		const files = built.files.map((f) => (f.section === 'offices' ? { ...f, rows: 7 } : f));
		const { d } = deps(built, stream(built.bytes), {
			source: { byteSize: built.bytes.length, sha256: built.sha256, files }
		});
		const report = await checkArchive(d);
		expect(report.failReason).toBe('row_count_mismatch');
		expect(report.sections.find((s) => s.section === 'offices')?.rows).toBe(6);
	});

	it('reports a missing archive', async () => {
		const built = await build({ offices });
		const { d } = deps(built, null);
		expect(await checkArchive(d)).toEqual({
			ok: false,
			failReason: 'archive_missing',
			sections: []
		});
	});

	it('reports a truncated archive as a checksum mismatch, and garbage as unreadable', async () => {
		const built = await build({ offices });
		const { d } = deps(built, stream(built.bytes.slice(0, built.bytes.length - 30)));
		expect((await checkArchive(d)).failReason).toBe('archive_checksum_mismatch');

		const garbage = encoder.encode('not a zip file at all, just text');
		const g = deps(built, garbage, {
			source: { byteSize: garbage.length, sha256: sha(garbage), files: built.files }
		});
		expect((await checkArchive(g.d)).failReason).toBe('archive_unreadable');
	});

	it('stops without a verdict when rows cannot be staged', async () => {
		const built = await build({ offices });
		const { d } = deps(built, stream(built.bytes), {
			sendRows: async () => {
				throw new Error('edge down');
			}
		});
		await expect(checkArchive(d)).rejects.toBeInstanceOf(StagingError);
	});
});
