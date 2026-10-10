import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { crc32, ZipWriter } from './zip';

/** A minimal reader: the central directory, then each entry inflated. */
async function readZip(bytes: Uint8Array) {
	const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
	const eocd = bytes.length - 22;
	expect(view.getUint32(eocd, true)).toBe(0x06054b50);
	const count = view.getUint16(eocd + 10, true);
	let at = view.getUint32(eocd + 16, true);
	const entries: { name: string; text: string; crc: number; size: number }[] = [];
	for (let i = 0; i < count; i++) {
		expect(view.getUint32(at, true)).toBe(0x02014b50);
		const crc = view.getUint32(at + 16, true);
		const compressed = view.getUint32(at + 20, true);
		const size = view.getUint32(at + 24, true);
		const nameLength = view.getUint16(at + 28, true);
		const offset = view.getUint32(at + 42, true);
		const name = new TextDecoder().decode(bytes.subarray(at + 46, at + 46 + nameLength));
		expect(view.getUint32(offset, true)).toBe(0x04034b50);
		const dataStart = offset + 30 + view.getUint16(offset + 26, true);
		const data = bytes.slice(dataStart, dataStart + compressed);
		const inflated = new Uint8Array(
			await new Response(
				new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate-raw'))
			).arrayBuffer()
		);
		expect(inflated.length).toBe(size);
		expect(crc32(inflated)).toBe(crc);
		entries.push({ name, text: new TextDecoder().decode(inflated), crc, size });
		at += 46 + nameLength;
	}
	return entries;
}

describe('ZipWriter', () => {
	it('round-trips entries with sizes, CRCs and checksums', async () => {
		const chunks: Uint8Array[] = [];
		const zip = new ZipWriter(async (b) => {
			chunks.push(b.slice());
		});
		const people = await zip.entry('people.ndjson');
		const lines = Array.from({ length: 500 }, (_, i) => `{"uid":"EW-${10000 + i}"}\n`);
		for (const line of lines) await people.write(new TextEncoder().encode(line));
		const done = await people.close();
		expect(done.sha256).toBe(createHash('sha256').update(lines.join('')).digest('hex'));
		const manifest = await zip.entry('manifest.json');
		await manifest.write(new TextEncoder().encode('{"files":1}'));
		await manifest.close();
		const archive = await zip.finish();

		const bytes = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
		let at = 0;
		for (const c of chunks) {
			bytes.set(c, at);
			at += c.length;
		}
		expect(archive.byteSize).toBe(bytes.length);
		expect(archive.sha256).toBe(createHash('sha256').update(bytes).digest('hex'));
		const entries = await readZip(bytes);
		expect(entries.map((e) => e.name)).toEqual(['people.ndjson', 'manifest.json']);
		expect(entries[0]?.text).toBe(lines.join(''));
		expect(entries[1]?.text).toBe('{"files":1}');
	});

	it('refuses overlapping entries', async () => {
		const zip = new ZipWriter(async () => undefined);
		await zip.entry('a.ndjson');
		await expect(zip.entry('b.ndjson')).rejects.toThrow();
	});

	it('crc32 matches the standard check value', () => {
		expect(crc32(new TextEncoder().encode('123456789'))).toBe(0xcbf43926);
	});
});
