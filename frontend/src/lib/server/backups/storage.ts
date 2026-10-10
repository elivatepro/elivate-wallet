// Where backup archives live (Blueprint 17, owner answer Q2): the private R2
// bucket bound as BACKUPS, with no lifecycle rule; the database expires
// archives after 90 days and the runner removes their files. Archives are
// uploaded in parts so a large network never sits in memory. Local e2e keeps
// files in a directory instead.

import { localExportsDir } from '../config';

export interface ArchiveUpload {
	write(bytes: Uint8Array): Promise<void>;
	complete(): Promise<void>;
	abort(): Promise<void>;
}

export interface StoredArchive {
	readonly body: ReadableStream | Uint8Array;
}

export interface BackupStorage {
	upload(key: string): Promise<ArchiveUpload>;
	get(key: string): Promise<StoredArchive | null>;
	delete(key: string): Promise<void>;
}

const KEY = /^backups\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9]{1,3}\.zip$/;

function checked(key: string): string {
	if (!KEY.test(key)) throw new Error('unexpected backup key');
	return key;
}

/** R2 multipart parts must be at least 5 MiB (except the last). */
const PART_BYTES = 8 * 1024 * 1024;

export function r2Backups(bucket: BackupBucket): BackupStorage {
	return {
		async upload(key) {
			const upload = await bucket.createMultipartUpload(checked(key), {
				httpMetadata: { contentType: 'application/zip' }
			});
			const parts: R2PartRef[] = [];
			let pending: Uint8Array[] = [];
			let pendingBytes = 0;
			const flush = async () => {
				if (pendingBytes === 0) return;
				const part = new Uint8Array(pendingBytes);
				let at = 0;
				for (const chunk of pending) {
					part.set(chunk, at);
					at += chunk.length;
				}
				pending = [];
				pendingBytes = 0;
				parts.push(await upload.uploadPart(parts.length + 1, part.buffer as ArrayBuffer));
			};
			return {
				async write(bytes) {
					pending.push(bytes.slice());
					pendingBytes += bytes.length;
					if (pendingBytes >= PART_BYTES) await flush();
				},
				async complete() {
					await flush();
					await upload.complete(parts);
				},
				abort: () => upload.abort()
			};
		},
		async get(key) {
			const object = await bucket.get(checked(key));
			return object ? { body: object.body } : null;
		},
		delete: (key) => bucket.delete(checked(key))
	};
}

/** Local e2e only (E2E_LOCAL_EXPORTS with a loopback Supabase). */
export function localBackups(dir: string): BackupStorage {
	const path = async (key: string) => {
		const { join } = await import('node:path');
		return join(dir, checked(key).replaceAll('/', '_'));
	};
	return {
		async upload(key) {
			const fs = await import('node:fs/promises');
			await fs.mkdir(dir, { recursive: true });
			const file = await path(key);
			await fs.writeFile(file, new Uint8Array());
			return {
				write: (bytes) => fs.appendFile(file, bytes),
				complete: async () => undefined,
				abort: () => fs.rm(file, { force: true })
			};
		},
		async get(key) {
			const fs = await import('node:fs/promises');
			try {
				return { body: new Uint8Array(await fs.readFile(await path(key))) };
			} catch {
				return null;
			}
		},
		async delete(key) {
			const fs = await import('node:fs/promises');
			await fs.rm(await path(key), { force: true });
		}
	};
}

let bindings: Promise<{ BACKUPS?: BackupBucket }> | undefined;

/** The bucket for this deployment, or null when none is configured. */
export async function backupStorage(): Promise<BackupStorage | null> {
	const local = localExportsDir();
	if (local) return localBackups(`${local}/backups`);
	bindings ??= import('cloudflare:workers').then(
		(m) => m.env,
		() => ({})
	);
	const bucket = (await bindings).BACKUPS;
	return bucket ? r2Backups(bucket) : null;
}
