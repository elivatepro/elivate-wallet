// Worker bindings. adapter-cloudflare 8 exposes them through cloudflare:workers
// (emulated by vite dev/preview from wrangler.jsonc); event.platform is unused.

/** The slice of the Workers R2 binding the app uses. */
interface PhotoBucket {
	put(
		key: string,
		value: ArrayBuffer,
		options?: { httpMetadata?: { contentType?: string } }
	): Promise<unknown>;
	get(
		key: string
	): Promise<{ body: ReadableStream; httpMetadata?: { contentType?: string } } | null>;
	delete(key: string): Promise<void>;
}

/** One uploaded part of an R2 multipart upload. */
interface R2PartRef {
	readonly partNumber: number;
	readonly etag: string;
}

/** The slice of the R2 binding backup archives use (multipart upload). */
interface BackupBucket {
	createMultipartUpload(
		key: string,
		options?: { httpMetadata?: { contentType?: string } }
	): Promise<{
		uploadPart(partNumber: number, value: ArrayBuffer): Promise<R2PartRef>;
		complete(parts: R2PartRef[]): Promise<unknown>;
		abort(): Promise<void>;
	}>;
	get(key: string): Promise<{ body: ReadableStream } | null>;
	delete(key: string): Promise<void>;
}

/** Cloudflare Browser Rendering binding (Blueprint 15), passed to @cloudflare/puppeteer. */
type BrowserBinding = import('@cloudflare/puppeteer').BrowserWorker;

declare module 'cloudflare:workers' {
	export const env: {
		/** Private R2 bucket for profile photos (Blueprint 06 B4); absent until bound. */
		readonly PHOTOS?: PhotoBucket;
		/** Private R2 bucket for statements and reports (Blueprint 15); files kept 7 days. */
		readonly EXPORTS?: PhotoBucket;
		/** Private R2 bucket for Team Backup Vault archives (Blueprint 17); no lifecycle rule. */
		readonly BACKUPS?: BackupBucket;
		/** Headless Chrome for PDF statements and reports (Blueprint 15). */
		readonly BROWSER?: BrowserBinding;
	};
}
