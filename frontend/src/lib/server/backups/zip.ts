// A streaming ZIP writer for backup archives (Blueprint 17, W-24): each entry
// is deflated as it is written (data descriptors, so sizes and CRC follow the
// data) and the bytes go straight to the sink. Nothing holds a whole archive
// in memory. Plain ZIP (no Zip64): archives stay far below 4 GB and 65,535
// entries.

import { createHash, type Hash } from 'node:crypto';

const CRC_TABLE = (() => {
	const table = new Uint32Array(256);
	for (let n = 0; n < 256; n++) {
		let c = n;
		for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
		table[n] = c >>> 0;
	}
	return table;
})();

export function crc32(bytes: Uint8Array, previous = 0): number {
	let crc = previous ^ 0xffffffff;
	for (let i = 0; i < bytes.length; i++) {
		crc = (CRC_TABLE[(crc ^ (bytes[i] ?? 0)) & 0xff] ?? 0) ^ (crc >>> 8);
	}
	return (crc ^ 0xffffffff) >>> 0;
}

/** Where archive bytes go, in order. */
export type Sink = (bytes: Uint8Array) => Promise<void>;

interface CentralEntry {
	readonly name: Uint8Array;
	readonly offset: number;
	readonly crc: number;
	readonly compressed: number;
	readonly size: number;
}

// 1980-01-01 00:00 in DOS format; the manifest carries the real time.
const DOS_TIME = 0;
const DOS_DATE = (0 << 9) | (1 << 5) | 1;
// Bit 3: sizes in a data descriptor; bit 11: UTF-8 names.
const FLAGS = 0x0808;

function header(size: number, write: (view: DataView) => void): Uint8Array {
	const bytes = new Uint8Array(size);
	write(new DataView(bytes.buffer));
	return bytes;
}

export interface EntryWriter {
	write(bytes: Uint8Array): Promise<void>;
	/** Finishes the entry; returns its uncompressed size and SHA-256 (hex). */
	close(): Promise<{ size: number; sha256: string }>;
}

export class ZipWriter {
	#offset = 0;
	#entries: CentralEntry[] = [];
	#hash: Hash = createHash('sha256');
	#open = false;
	readonly #sink: Sink;

	constructor(sink: Sink) {
		this.#sink = sink;
	}

	async #emit(bytes: Uint8Array): Promise<void> {
		if (bytes.length === 0) return;
		this.#hash.update(bytes);
		this.#offset += bytes.length;
		await this.#sink(bytes);
	}

	/** Starts one deflated entry; entries are written one at a time. */
	async entry(fileName: string): Promise<EntryWriter> {
		if (this.#open) throw new Error('zip: previous entry still open');
		this.#open = true;
		const name = new TextEncoder().encode(fileName);
		const offset = this.#offset;
		await this.#emit(
			header(30 + name.length, (v) => {
				v.setUint32(0, 0x04034b50, true);
				v.setUint16(4, 20, true);
				v.setUint16(6, FLAGS, true);
				v.setUint16(8, 8, true);
				v.setUint16(10, DOS_TIME, true);
				v.setUint16(12, DOS_DATE, true);
				v.setUint16(26, name.length, true);
				new Uint8Array(v.buffer).set(name, 30);
			})
		);

		const deflate = new CompressionStream('deflate-raw');
		const input = deflate.writable.getWriter();
		let compressed = 0;
		const reader = deflate.readable.getReader();
		// A sink failure cancels the stream so a pending write rejects instead of waiting.
		const pump = (async () => {
			for (;;) {
				const { done, value } = await reader.read();
				if (done) break;
				compressed += value.length;
				await this.#emit(value);
			}
		})().catch(async (error: unknown) => {
			await reader.cancel(error).catch(() => undefined);
			throw error;
		});
		pump.catch(() => undefined);
		let crc = 0;
		let size = 0;
		const sha = createHash('sha256');

		return {
			write: async (bytes) => {
				crc = crc32(bytes, crc);
				size += bytes.length;
				sha.update(bytes);
				await input.write(bytes as Uint8Array<ArrayBuffer>);
			},
			close: async () => {
				await input.close();
				await pump;
				await this.#emit(
					header(16, (v) => {
						v.setUint32(0, 0x08074b50, true);
						v.setUint32(4, crc, true);
						v.setUint32(8, compressed, true);
						v.setUint32(12, size, true);
					})
				);
				this.#entries.push({ name, offset, crc, compressed, size });
				this.#open = false;
				return { size, sha256: sha.digest('hex') };
			}
		};
	}

	/** Writes the central directory; returns the archive's size and SHA-256 (hex). */
	async finish(): Promise<{ byteSize: number; sha256: string }> {
		if (this.#open) throw new Error('zip: entry still open');
		const start = this.#offset;
		for (const e of this.#entries) {
			await this.#emit(
				header(46 + e.name.length, (v) => {
					v.setUint32(0, 0x02014b50, true);
					v.setUint16(4, 20, true);
					v.setUint16(6, 20, true);
					v.setUint16(8, FLAGS, true);
					v.setUint16(10, 8, true);
					v.setUint16(12, DOS_TIME, true);
					v.setUint16(14, DOS_DATE, true);
					v.setUint32(16, e.crc, true);
					v.setUint32(20, e.compressed, true);
					v.setUint32(24, e.size, true);
					v.setUint16(28, e.name.length, true);
					v.setUint32(42, e.offset, true);
					new Uint8Array(v.buffer).set(e.name, 46);
				})
			);
		}
		const size = this.#offset - start;
		await this.#emit(
			header(22, (v) => {
				v.setUint32(0, 0x06054b50, true);
				v.setUint16(8, this.#entries.length, true);
				v.setUint16(10, this.#entries.length, true);
				v.setUint32(12, size, true);
				v.setUint32(16, start, true);
			})
		);
		return { byteSize: this.#offset, sha256: this.#hash.digest('hex') };
	}
}
