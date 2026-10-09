import { Effect } from 'effect';
import { describe, expect, it } from 'vitest';
import { BackendError, TransportError, type ApiFailure } from '#lib/contract/errors.js';
import type { CommandOutcome } from '#lib/contract/ledger.js';
import { storageKey } from '#lib/recovery.js';
import { CommandAttempt } from './command-attempt.svelte';
import { MemoryStore } from './device-cache';

type Sent = { body: Record<string, unknown> };
const scope = { uid: 'EW-48213', workspaceId: 'ws-1' };

function harness(replies: Array<'ok' | 'timeout' | BackendError>, outcomes: CommandOutcome[]) {
	const sent: Sent[] = [];
	const store = new MemoryStore();
	const attempt = new CommandAttempt({
		command: 'record_income',
		path: '/api/income',
		method: 'POST',
		schema: {} as never,
		scope: () => scope,
		store,
		send: (_p, _m, body) => {
			sent.push({ body: body as Record<string, unknown> });
			const reply = replies.shift() ?? 'ok';
			if (reply === 'ok') return Effect.succeed({ reference: 'INC-7F2K-0931' } as never);
			if (reply === 'timeout')
				return Effect.fail<ApiFailure>(new TransportError({ reason: 'timeout', status: null }));
			return Effect.fail<ApiFailure>(reply);
		},
		lookup: () => {
			const next = outcomes.shift();
			return next
				? Effect.succeed(next)
				: Effect.fail<ApiFailure>(new TransportError({ reason: 'network', status: null }));
		}
	});
	return { attempt, sent, store };
}

const refused = (code: BackendError['code']) =>
	new BackendError({
		status: 409,
		code,
		message: '',
		retryable: false,
		details: {},
		requestId: null
	});

describe('CommandAttempt', () => {
	it('a success rotates the key and clears the device', async () => {
		const { attempt, sent, store } = harness(['ok'], []);
		const first = attempt.key;
		const state = await attempt.send('ws-1', { amount: '1.00' }, { pin: '1234' });
		expect(state.kind).toBe('done');
		expect(sent[0]?.body).toEqual({ amount: '1.00', pin: '1234', idempotencyKey: first });
		expect(attempt.key).not.toBe(first);
		expect(store.getItem(storageKey(scope, 'record_income'))).toBeNull();
	});

	it('a timeout that committed replays the same key and shows the result', async () => {
		const { attempt, sent } = harness(
			['timeout', 'ok'],
			[
				{
					status: 'committed',
					command: 'record_income',
					committedAt: 'x',
					reference: 'INC-7F2K-0931'
				}
			]
		);
		const key = attempt.key;
		const state = await attempt.send('ws-1', { amount: '1.00' }, { pin: '1234' });
		expect(state.kind).toBe('done');
		expect(sent.map((s) => s.body.idempotencyKey)).toEqual([key, key]);
		expect(sent[1]?.body.pin).toBeUndefined();
	});

	it('a timeout that did not commit blocks new submissions until resent with the same key', async () => {
		const { attempt, sent } = harness(['timeout', 'ok'], [{ status: 'not_found', command: null }]);
		const key = attempt.key;
		const state = await attempt.send('ws-1', { amount: '1.00' });
		expect(state).toMatchObject({
			kind: 'resolved',
			resolution: { kind: 'not_committed', canResend: true }
		});
		expect(attempt.blocked).toBe(true);
		expect((await attempt.send('ws-1', { amount: '9.00' })).kind).toBe('resolved');
		expect(sent).toHaveLength(1);
		expect((await attempt.resend()).kind).toBe('done');
		expect(sent[1]?.body).toEqual({ amount: '1.00', idempotencyKey: key });
	});

	it('when the lookup itself fails the outcome stays unknown', async () => {
		const { attempt } = harness(['timeout'], []);
		expect((await attempt.send('ws-1', { amount: '1.00' })).kind).toBe('unknown');
		expect(attempt.blocked).toBe(true);
	});

	it('a refusal rotates the key; a PIN prompt keeps it', async () => {
		const { attempt } = harness([refused('step_up_required'), refused('insufficient_funds')], []);
		const key = attempt.key;
		expect((await attempt.send('ws-1', { amount: '1.00' })).kind).toBe('failed');
		expect(attempt.key).toBe(key);
		expect((await attempt.send('ws-1', { amount: '1.00' }, { pin: '1234' })).kind).toBe('failed');
		expect(attempt.key).not.toBe(key);
	});

	it('after a PIN prompt the kept body goes again with the same key', async () => {
		const { attempt, sent } = harness([refused('step_up_required'), 'ok'], []);
		const key = attempt.key;
		await attempt.send('ws-1', { amount: '1.00' });
		expect(attempt.awaitingPin).toBe(true);
		expect((await attempt.resend({ pin: '1234' })).kind).toBe('done');
		expect(sent[1]?.body).toEqual({ amount: '1.00', pin: '1234', idempotencyKey: key });
	});

	it('a reload restores the attempt from the device and checks it', async () => {
		const first = harness(['timeout'], []);
		await first.attempt.send('ws-1', { amount: '1.00' });
		const second = new CommandAttempt({
			command: 'record_income',
			path: '/api/income',
			method: 'POST',
			schema: {} as never,
			scope: () => scope,
			store: first.store,
			lookup: () =>
				Effect.succeed<CommandOutcome>({
					status: 'committed',
					command: 'record_income',
					committedAt: 'x',
					reference: 'INC-7F2K-0931'
				}),
			send: () => Effect.succeed({} as never)
		});
		const state = await second.restore();
		expect(state.kind).toBe('done');
	});
});
