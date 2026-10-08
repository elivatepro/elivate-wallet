import { describe, expect, it } from 'vitest';
import { Effect, Exit } from 'effect';
import * as fx from '#lib/contract/fixtures.js';
import { InvitationsApi, InvitationsApiLive } from './apis.js';
import { EdgeTransportLive } from './edge.js';

const TOKEN = 'A'.repeat(42) + '_';

function fakeFetch(body: unknown, status = 200) {
	const calls: Array<{ url: string; headers: Headers; body: unknown }> = [];
	const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
		calls.push({
			url: String(input),
			headers: new Headers(init?.headers),
			body: init?.body ? JSON.parse(String(init.body)) : undefined
		});
		return new Response(JSON.stringify(body), { status });
	}) as typeof fetch;
	return { fetcher, calls };
}

const run = <A, E>(
	program: Effect.Effect<A, E, InvitationsApi>,
	fetcher: typeof fetch,
	accessToken: string | null
) =>
	Effect.runPromise(
		Effect.exit(
			program.pipe(
				Effect.provide(InvitationsApiLive),
				Effect.provide(
					EdgeTransportLive({
						supabaseUrl: 'http://127.0.0.1:54321',
						publishableKey: 'publishable-test-key',
						accessToken,
						fetch: fetcher
					})
				)
			)
		)
	);

describe('InvitationsApi join flow', () => {
	it('previews without a bearer token and sends only the token', async () => {
		const { fetcher, calls } = fakeFetch(fx.success({ email: 'ada@example.test' }));
		const exit = await run(
			Effect.gen(function* () {
				return yield* (yield* InvitationsApi).preview(TOKEN);
			}),
			fetcher,
			null
		);
		expect(Exit.isSuccess(exit) && exit.value.email).toBe('ada@example.test');
		expect(calls[0]?.url).toBe('http://127.0.0.1:54321/functions/v1/invitations/preview');
		expect(calls[0]?.headers.has('authorization')).toBe(false);
		expect(calls[0]?.headers.get('apikey')).toBe('publishable-test-key');
		expect(calls[0]?.body).toEqual({ token: TOKEN });
	});

	it('verify-email posts no email field', async () => {
		const { fetcher, calls } = fakeFetch(fx.success({ sent: true }));
		const exit = await run(
			Effect.gen(function* () {
				return yield* (yield* InvitationsApi).verifyEmail(TOKEN);
			}),
			fetcher,
			null
		);
		expect(Exit.isSuccess(exit)).toBe(true);
		expect(calls[0]?.body).toEqual({ token: TOKEN });
	});

	it('refuses a malformed token locally, before any request', async () => {
		const { fetcher, calls } = fakeFetch(fx.success({ email: 'x@example.test' }));
		const exit = await run(
			Effect.gen(function* () {
				return yield* (yield* InvitationsApi).preview('short');
			}),
			fetcher,
			null
		);
		expect(Exit.isFailure(exit)).toBe(true);
		expect(calls).toHaveLength(0);
	});

	it('accepts by token with the session bearer and the given idempotency key', async () => {
		const accepted = {
			invitationId: fx.workspace.membershipId,
			membershipId: fx.workspace.membershipId,
			tenantId: fx.workspace.tenantId,
			officeId: fx.workspace.membershipId,
			role: 'member',
			isPrimary: true
		};
		const { fetcher, calls } = fakeFetch(fx.success(accepted));
		const exit = await run(
			Effect.gen(function* () {
				return yield* (yield* InvitationsApi).accept({
					token: TOKEN,
					idempotencyKey: 'join-key-0123456789'
				});
			}),
			fetcher,
			'access-token-test'
		);
		expect(Exit.isSuccess(exit)).toBe(true);
		expect(calls[0]?.headers.get('authorization')).toBe('Bearer access-token-test');
		expect(calls[0]?.body).toEqual({ token: TOKEN, idempotencyKey: 'join-key-0123456789' });
	});
});
