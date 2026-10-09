// Export runner (Blueprint 15 — B4): called every minute by pg_cron/pg_net
// (Vault exports_worker_url/secret) and on each new request, with
// `Authorization: Bearer <EXPORTS_WORKER_SECRET>`. Never reachable without it.
import { exportsWorkerSecret } from '#lib/server/config.js';
import { runnerDeps } from '#lib/server/exports/endpoints.js';
import { runExports } from '#lib/server/exports/runner.js';
import type { RequestHandler } from './$types';

const json = (status: number, body: unknown) =>
	new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }
	});

async function sameSecret(given: string, expected: string): Promise<boolean> {
	const key = crypto.getRandomValues(new Uint8Array(32));
	const mac = async (value: string) => {
		const k = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, [
			'sign'
		]);
		return new Uint8Array(await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(value)));
	};
	const [a, b] = await Promise.all([mac(given), mac(expected)]);
	let diff = 0;
	for (let i = 0; i < a.length; i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
	return diff === 0;
}

export const POST: RequestHandler = async ({ request }) => {
	const expected = exportsWorkerSecret();
	const given = request.headers.get('authorization')?.match(/^Bearer (.+)$/)?.[1];
	if (!expected || !given || !(await sameSecret(given, expected))) {
		return json(403, { ok: false, error: { code: 'authorization_denied' } });
	}
	const deps = await runnerDeps();
	if (!deps)
		return json(503, {
			ok: false,
			error: { code: 'internal_error', message: 'exports not configured' }
		});
	const outcomes = await runExports(deps);
	return json(200, {
		ok: true,
		data: {
			ran: outcomes.length,
			ready: outcomes.filter((o) => o.status === 'ready').length,
			failed: outcomes.filter((o) => o.status === 'failed').length,
			tooLarge: outcomes.filter((o) => o.status === 'too_large').length
		}
	});
};
