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

declare module 'cloudflare:workers' {
	export const env: {
		/** Private R2 bucket for profile photos (Blueprint 06 B4); absent until bound. */
		readonly PHOTOS?: PhotoBucket;
	};
}
