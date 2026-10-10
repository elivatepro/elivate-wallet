import { Effect } from 'effect';
import { describe, expect, it } from 'vitest';
import { BackendError, TransportError, type ApiFailure } from '#lib/contract/errors.js';
import type { CommandOutcome } from '#lib/contract/ledger.js';
import { storageKey } from '#lib/recovery.js';
import { CommandAttempt, showsRecovery } from './command-attempt.svelte';
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

	it('while recovering, a refused re-send keeps the attempt and its key', async () => {
		const { attempt, store } = harness(
			['timeout', refused('authorization_denied')],
			[{ status: 'not_found', command: null }]
		);
		const key = attempt.key;
		await attempt.send('ws-1', { amount: '1.00' });
		const state = await attempt.resend();
		expect(state.kind).toBe('unknown');
		expect(attempt.key).toBe(key);
		expect(attempt.lastRefusal?._tag).toBe('BackendError');
		expect(store.getItem(storageKey(scope, 'record_income'))).not.toBeNull();
	});

	it('while recovering, a PIN prompt says so and the same body goes again with the PIN', async () => {
		const { attempt, sent } = harness(
			['timeout', refused('step_up_required'), 'ok'],
			[{ status: 'not_found', command: null }]
		);
		const key = attempt.key;
		await attempt.send('ws-1', { amount: '1.00' });
		await attempt.resend();
		expect(attempt.recovering).toBe(true);
		expect(attempt.awaitingPin).toBe(true);
		attempt.reset();
		expect(attempt.key).toBe(key);
		const state = await attempt.resend({ pin: '1234' });
		expect(state.kind).toBe('done');
		expect(sent[2]?.body).toEqual({ amount: '1.00', pin: '1234', idempotencyKey: key });
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

describe('showsRecovery', () => {
	it('keeps the locked screen through the PIN prompt and the re-send in flight', async () => {
		let release: () => void = () => {};
		const held = new Promise<void>((resolve) => (release = resolve));
		const replies: Array<'timeout' | 'held' | BackendError> = [
			'timeout',
			refused('step_up_required'),
			'held'
		];
		const attempt = new CommandAttempt({
			command: 'submit_conversion',
			path: '/api/conversions',
			method: 'POST',
			schema: {} as never,
			scope: () => scope,
			store: new MemoryStore(),
			send: () => {
				const reply = replies.shift();
				if (reply === 'timeout')
					return Effect.fail<ApiFailure>(new TransportError({ reason: 'timeout', status: null }));
				if (reply === 'held')
					return Effect.promise(() => held).pipe(Effect.as({ reference: 'CNV-1' } as never));
				return Effect.fail<ApiFailure>(reply as BackendError);
			},
			lookup: () => Effect.succeed({ status: 'not_found', command: null })
		});
		expect(showsRecovery(attempt)).toBe(false);
		await attempt.send('ws-1', { amount: '1.00' });
		expect(showsRecovery(attempt)).toBe(true);
		await attempt.resend();
		expect(attempt.state.kind).toBe('failed');
		expect(showsRecovery(attempt)).toBe(true);
		const sending = attempt.resend({ pin: '1234' });
		expect(attempt.state.kind).toBe('sending');
		expect(showsRecovery(attempt)).toBe(true);
		release();
		expect((await sending).kind).toBe('done');
		expect(showsRecovery(attempt)).toBe(false);
	});

	it('a fresh form that is sending is not recovery', async () => {
		const { attempt } = harness(['ok'], []);
		const pending = attempt.send('ws-1', { amount: '1.00' });
		expect(attempt.state.kind).toBe('sending');
		expect(showsRecovery(attempt)).toBe(false);
		await pending;
	});
});

describe('CommandAttempt invalidation (Blueprint 20 B6)', () => {
	const make = (command: string, path: string, reply: 'ok' | BackendError = 'ok') => {
		const cleared: (readonly string[])[] = [];
		const attempt = new CommandAttempt({
			command,
			path,
			method: 'POST',
			schema: {} as never,
			scope: () => null,
			store: null,
			onInvalidate: (kinds) => cleared.push(kinds),
			send: () => (reply === 'ok' ? Effect.succeed({} as never) : Effect.fail<ApiFailure>(reply))
		});
		return { attempt, cleared };
	};

	it.each([
		['record_income', '/api/income'],
		['request_withdrawal', '/api/withdrawals'],
		['submit_conversion', '/api/conversions'],
		['submit_adjustment', '/api/adjustments'],
		['reverse_transaction', '/api/reversals'],
		['request_pocket_transfer', '/api/pocket-moves']
	])('%s clears balances, history and wallets on success', async (command, path) => {
		const { attempt, cleared } = make(command, path);
		await attempt.send('ws-1', {});
		expect(cleared).toEqual([['balances', 'history', 'wallets']]);
	});

	it('falls back to the path for other commands', async () => {
		const org = make('rename_office', '/api/org/offices/x');
		await org.attempt.send('ws-1', {});
		expect(org.cleared).toEqual([['offices', 'members']]);
		const settings = make('save_settings', '/api/settings');
		await settings.attempt.send('ws-1', {});
		expect(settings.cleared).toEqual([['settings']]);
	});

	it('clears nothing when the command is refused', async () => {
		const { attempt, cleared } = make('record_income', '/api/income', refused('conflict'));
		await attempt.send('ws-1', {});
		expect(cleared).toEqual([]);
	});
});
