import { describe, expect, it } from 'vitest';
import { Effect, Exit, Layer } from 'effect';
import * as fx from '#lib/contract/fixtures.js';
import type { ApiFailure } from '#lib/contract/errors.js';
import { OrgApi, OrgApiLive, SecurityApi, SecurityApiLive } from './apis.js';
import { EdgeTransportLive } from './edge.js';

interface Call {
	url: URL;
	method: string;
	headers: Headers;
	body: unknown;
}

/** A fake fetch that records calls and answers from a queue. */
function fakeFetch(responses: Array<{ status: number; body: unknown } | 'network'>) {
	const calls: Call[] = [];
	const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
		calls.push({
			url: new URL(String(input)),
			method: init?.method ?? 'GET',
			headers: new Headers(init?.headers),
			body: init?.body ? JSON.parse(String(init.body)) : undefined
		});
		const next = responses.shift() ?? { status: 500, body: undefined };
		if (next === 'network') throw new TypeError('fetch failed');
		return new Response(next.body === undefined ? 'oops' : JSON.stringify(next.body), {
			status: next.status
		});
	}) as typeof fetch;
	return { fetcher, calls };
}

function layer(fetcher: typeof fetch) {
	const edge = EdgeTransportLive({
		supabaseUrl: 'http://127.0.0.1:54321',
		publishableKey: 'publishable-test-key',
		accessToken: 'access-token-test',
		fetch: fetcher
	});
	return Layer.mergeAll(SecurityApiLive, OrgApiLive).pipe(Layer.provide(edge));
}

const run = <A>(
	program: Effect.Effect<A, ApiFailure, SecurityApi | OrgApi>,
	fetcher: typeof fetch
) => Effect.runPromise(Effect.exit(program.pipe(Effect.provide(layer(fetcher)))));

const failure = <A>(exit: Exit.Exit<A, ApiFailure>) =>
	Exit.isFailure(exit) ? Effect.runSync(Effect.flip(Effect.failCause(exit.cause))) : null;

describe('EdgeTransport', () => {
	it('calls the function URL with bearer token, publishable key and X-Membership', async () => {
		const { fetcher, calls } = fakeFetch([{ status: 200, body: fx.success(fx.capabilities) }]);
		const exit = await run(
			Effect.gen(function* () {
				return yield* (yield* OrgApi).capabilities(fx.workspace.membershipId);
			}),
			fetcher
		);
		expect(Exit.isSuccess(exit)).toBe(true);
		const [call] = calls;
		expect(call?.url.toString()).toBe('http://127.0.0.1:54321/functions/v1/org/capabilities');
		expect(call?.headers.get('authorization')).toBe('Bearer access-token-test');
		expect(call?.headers.get('apikey')).toBe('publishable-test-key');
		expect(call?.headers.get('x-membership')).toBe(fx.workspace.membershipId);
	});

	it('does not send X-Membership on /workspaces', async () => {
		const { fetcher, calls } = fakeFetch([{ status: 200, body: fx.success([fx.workspace]) }]);
		await run(
			Effect.gen(function* () {
				return yield* (yield* OrgApi).workspaces;
			}),
			fetcher
		);
		expect(calls[0]?.headers.has('x-membership')).toBe(false);
	});

	it('sends the app-server secret only on the sign-in record (Blueprint 14)', async () => {
		const { fetcher, calls } = fakeFetch([
			{ status: 200, body: fx.success({ unusual: false }) },
			{ status: 200, body: fx.success({ passwordChangedAt: null, unusualSignIns: [] }) }
		]);
		await run(
			Effect.gen(function* () {
				const security = yield* SecurityApi;
				yield* security.recordSignIn(
					{
						method: 'password',
						ip: '102.89.1.10',
						city: 'Lagos',
						country: 'NG',
						device: 'Mac · Chrome',
						userAgent: null
					},
					'app-secret'
				);
				return yield* security.overview;
			}),
			fetcher
		);
		expect(calls[0]?.url.pathname).toBe('/functions/v1/security/sign-ins');
		expect(calls[0]?.headers.get('x-app-server-secret')).toBe('app-secret');
		expect(calls[1]?.headers.has('x-app-server-secret')).toBe(false);
	});
});

describe('SecurityApi', () => {
	it('retries a read at most twice on retryable failures', async () => {
		const { fetcher, calls } = fakeFetch([
			{ status: 500, body: fx.failure('internal_error') },
			'network',
			{ status: 500, body: fx.failure('internal_error') }
		]);
		const exit = await run(
			Effect.gen(function* () {
				return yield* (yield* SecurityApi).state;
			}),
			fetcher
		);
		expect(calls).toHaveLength(3);
		expect(failure(exit)).toMatchObject({ _tag: 'BackendError', code: 'internal_error' });
	});

	it('never retries PIN verification (each attempt counts)', async () => {
		const { fetcher, calls } = fakeFetch([{ status: 500, body: fx.failure('internal_error') }]);
		await run(
			Effect.gen(function* () {
				return yield* (yield* SecurityApi).verifyPin({ pin: '1234' });
			}),
			fetcher
		);
		expect(calls).toHaveLength(1);
		expect(calls[0]?.body).toEqual({ pin: '1234' });
	});

	it('validates PINs locally with the Edge rules before any request', async () => {
		const { fetcher, calls } = fakeFetch([]);
		const mismatch = await run(
			Effect.gen(function* () {
				return yield* (yield* SecurityApi).setPin({ pin: '1234', pinConfirm: '4321' });
			}),
			fetcher
		);
		expect(failure(mismatch)).toMatchObject({
			code: 'validation_error',
			details: { field: 'pinConfirm', reason: 'mismatch' }
		});
		const short = await run(
			Effect.gen(function* () {
				return yield* (yield* SecurityApi).verifyPin({ pin: '12a4' });
			}),
			fetcher
		);
		expect(failure(short)).toMatchObject({ code: 'validation_error', details: { field: 'pin' } });
		expect(calls).toHaveLength(0);
	});

	it('surfaces gate codes from any route as typed errors', async () => {
		const { fetcher } = fakeFetch([
			{ status: 423, body: fx.failure('pin_locked', { attemptsRemaining: 0 }) }
		]);
		const exit = await run(
			Effect.gen(function* () {
				return yield* (yield* SecurityApi).verifyPin({ pin: '0000' });
			}),
			fetcher
		);
		expect(failure(exit)).toMatchObject({ code: 'pin_locked', status: 423 });
	});

	it('times out a hanging request as a TransportError', async () => {
		const hanging = ((_: RequestInfo | URL, init?: RequestInit) =>
			new Promise((_, reject) =>
				init?.signal?.addEventListener('abort', () => reject(new Error('aborted')))
			)) as typeof fetch;
		const { requestJson } = await import('#lib/contract/transport.js');
		const { SecurityState } = await import('#lib/contract/security.js');
		const exit = await Effect.runPromise(
			Effect.exit(
				requestJson(
					{
						fetch: hanging,
						url: 'http://127.0.0.1/x',
						method: 'GET',
						route: 'GET /x',
						timeoutMs: 20
					},
					SecurityState
				)
			)
		);
		expect(failure(exit)).toMatchObject({ _tag: 'TransportError', reason: 'timeout' });
	});
});
