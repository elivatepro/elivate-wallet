// App-server glue for statements and reports (Blueprint 15): building the
// export runner from this deployment's bindings, starting it right after a
// request, and streaming a file after the backend authorized the download.

import type { RequestEvent } from '@sveltejs/kit';
import { Cause, Effect, Exit, Option } from 'effect';
import { TransportError } from '#lib/contract/errors.js';
import { ExportsApi } from '../apis-exports';
import { appServerSecret, exportsWorkerSecret, localExportsDir, requireConfig } from '../config';
import { respondError, toBackendError, unauthenticated } from '../relay';
import { runApi } from '../request';
import { browserRenderer, localRenderer, type PdfRenderer } from './render';
import { edgeWorkerClient, runExports, type RunnerDeps } from './runner';
import { exportStorage, workerBindings } from './storage';

/** Null when this deployment cannot make files (no secret, bucket or browser). */
export async function runnerDeps(): Promise<RunnerDeps | null> {
	const secret = exportsWorkerSecret();
	const storage = await exportStorage();
	let renderer: PdfRenderer | null = null;
	if (localExportsDir()) renderer = localRenderer();
	else {
		const browser = (await workerBindings()).BROWSER;
		if (browser) renderer = browserRenderer(browser);
	}
	if (!secret || !storage || !renderer) return null;
	const config = requireConfig();
	return {
		client: edgeWorkerClient({
			supabaseUrl: config.supabaseUrl,
			publishableKey: config.publishableKey,
			secret,
			fetch: globalThis.fetch.bind(globalThis)
		}),
		storage,
		renderer,
		log: (entry) => console.log(JSON.stringify({ route: 'exports.run', ...entry }))
	};
}

/**
 * Starts the runner after a new or retried file so small files are ready in
 * seconds (pg_cron/pg_net also wakes it; jobs are leased, so both are safe).
 */
export function kickRunner(): void {
	const run = (async () => {
		const deps = await runnerDeps();
		if (deps) await runExports(deps, 25_000);
	})().catch((error: unknown) =>
		console.log(JSON.stringify({ route: 'exports.kick', error: String(error).slice(0, 200) }))
	);
	import('cloudflare:workers').then(
		(m) => (m as unknown as { waitUntil?: (p: Promise<unknown>) => void }).waitUntil?.(run),
		() => undefined
	);
}

/** Sends one stored file after the backend re-checked the person (and PIN for reports). */
export async function streamExport(
	event: RequestEvent,
	id: string,
	part: 'file' | 'preview'
): Promise<Response> {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const secret = appServerSecret();
	const storage = await exportStorage();
	if (!secret || !storage) {
		return respondError(toBackendError(new TransportError({ reason: 'network', status: null })));
	}
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* ExportsApi).authorizeDownload(id, part, secret);
		})
	);
	if (Exit.isFailure(exit)) {
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		return respondError(
			toBackendError(failure ?? new TransportError({ reason: 'network', status: null }))
		);
	}
	const target = exit.value;
	const stored = await storage.get(target.objectKey);
	if (!stored) {
		// Removed by the 7-day lifecycle a moment early: say so as "expired".
		return new Response(
			JSON.stringify({
				ok: false,
				error: {
					code: 'conflict',
					message: 'This file has expired. Create it again.',
					retryable: false,
					details: { reason: 'export_expired' }
				},
				requestId: crypto.randomUUID()
			}),
			{
				status: 409,
				headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }
			}
		);
	}
	const headers: Record<string, string> = {
		'content-type': target.contentType,
		'content-disposition': `${part === 'preview' ? 'inline' : 'attachment'}; filename="${target.fileName}"`,
		'cache-control': 'private, no-store',
		'x-content-type-options': 'nosniff',
		'content-security-policy': "default-src 'none'; sandbox"
	};
	if (target.byteSize) headers['content-length'] = String(target.byteSize);
	const body =
		stored.body instanceof Uint8Array ? (stored.body.slice().buffer as ArrayBuffer) : stored.body;
	return new Response(body, { headers });
}
