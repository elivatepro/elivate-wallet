// Where generated files live (owner decision Q6): the private R2 bucket bound
// as EXPORTS (lifecycle: removed after 7 days). Keys are built by the database;
// the browser never sees one. Local e2e keeps files in a directory instead.

import { localExportsDir } from '../config';

export interface StoredFile {
	readonly body: ReadableStream | Uint8Array;
	readonly size: number | null;
}

export interface ExportStorage {
	put(key: string, bytes: Uint8Array, contentType: string): Promise<void>;
	get(key: string): Promise<StoredFile | null>;
	delete(key: string): Promise<void>;
}

const KEY = /^exports\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.(pdf|csv)(\.png)?$/;

function checked(key: string): string {
	if (!KEY.test(key)) throw new Error('unexpected export key');
	return key;
}

export function r2Storage(bucket: PhotoBucket): ExportStorage {
	return {
		async put(key, bytes, contentType) {
			await bucket.put(checked(key), bytes.slice().buffer as ArrayBuffer, {
				httpMetadata: { contentType }
			});
		},
		async get(key) {
			const object = await bucket.get(checked(key));
			return object ? { body: object.body, size: null } : null;
		},
		delete: (key) => bucket.delete(checked(key))
	};
}

/** Local e2e only (E2E_LOCAL_EXPORTS with a loopback Supabase). */
export function localStorage(dir: string): ExportStorage {
	const path = async (key: string) => {
		const { join } = await import('node:path');
		return join(dir, checked(key).replaceAll('/', '_'));
	};
	return {
		async put(key, bytes) {
			const fs = await import('node:fs/promises');
			await fs.mkdir(dir, { recursive: true });
			await fs.writeFile(await path(key), bytes);
		},
		async get(key) {
			const fs = await import('node:fs/promises');
			try {
				const bytes = new Uint8Array(await fs.readFile(await path(key)));
				return { body: bytes, size: bytes.length };
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

let bindings: Promise<{ EXPORTS?: PhotoBucket; BROWSER?: BrowserBinding }> | undefined;

export async function workerBindings() {
	bindings ??= import('cloudflare:workers').then(
		(m) => m.env,
		() => ({})
	);
	return bindings;
}

/** The bucket for this deployment, or null when none is configured. */
export async function exportStorage(): Promise<ExportStorage | null> {
	const local = localExportsDir();
	if (local) return localStorage(local);
	const bucket = (await workerBindings()).EXPORTS;
	return bucket ? r2Storage(bucket) : null;
}
