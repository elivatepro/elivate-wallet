import { describe, expect, it } from 'vitest';
import { BackendError, ContractViolation, TransportError } from '#lib/contract/errors.js';
import { MemoryStore } from '#lib/client/device-cache.js';
import {
	ATTEMPT_MAX_AGE_MS,
	ATTEMPT_SETTLE_MS,
	attemptLabel,
	isUnknownOutcome,
	keepsAttempt,
	loadAttempt,
	resolveOutcome,
	saveAttempt,
	storableBody,
	storageKey,
	type PendingAttempt
} from './recovery';

const backend = (code: BackendError['code']) =>
	new BackendError({
		status: 400,
		code,
		message: '',
		retryable: false,
		details: {},
		requestId: null
	});

const attempt = (over: Partial<PendingAttempt> = {}): PendingAttempt => ({
	key: 'k0123456789abcdef0123',
	command: 'record_income',
	workspaceId: 'ws-1',
	dispatchedAt: 1_000_000,
	summary: '₦120,000.00 income',
	body: { amount: '120000.00' },
	...over
});

describe('isUnknownOutcome', () => {
	it('treats missing answers, 502s and contract drift as unknown', () => {
		expect(isUnknownOutcome(new TransportError({ reason: 'timeout', status: null }))).toBe(true);
		expect(isUnknownOutcome(new TransportError({ reason: 'network', status: null }))).toBe(true);
		expect(isUnknownOutcome(new TransportError({ reason: 'non_envelope', status: 504 }))).toBe(
			true
		);
		expect(isUnknownOutcome(backend('internal_error'))).toBe(true);
		expect(
			isUnknownOutcome(new ContractViolation({ route: 'r', requestId: null, summary: 's' }))
		).toBe(true);
	});
	it('treats refusals and a gateway 401 as known', () => {
		expect(isUnknownOutcome(new TransportError({ reason: 'non_envelope', status: 401 }))).toBe(
			false
		);
		expect(isUnknownOutcome(backend('insufficient_funds'))).toBe(false);
		expect(isUnknownOutcome(backend('idempotency_conflict'))).toBe(false);
	});
	it('keeps the attempt for PIN prompts only among refusals', () => {
		expect(keepsAttempt(backend('step_up_required'))).toBe(true);
		expect(keepsAttempt(backend('pin_incorrect'))).toBe(true);
		expect(keepsAttempt(backend('authorization_denied'))).toBe(false);
	});
});

describe('resolveOutcome', () => {
	it('committed shows the reference', () => {
		expect(
			resolveOutcome(
				{
					status: 'committed',
					command: 'record_income',
					committedAt: '2026-10-08T10:00:00Z',
					reference: 'INC-7F2K-0931'
				},
				attempt()
			)
		).toEqual({ kind: 'committed', reference: 'INC-7F2K-0931', at: '2026-10-08T10:00:00Z' });
	});
	it('a different command under the key is a conflict', () => {
		expect(
			resolveOutcome(
				{
					status: 'committed',
					command: 'set_allocation',
					committedAt: '2026-10-08T10:00:00Z',
					reference: null
				},
				attempt()
			).kind
		).toBe('conflict');
	});
	it('cancelled income attempts', () => {
		expect(
			resolveOutcome({ status: 'cancelled', command: 'record_income', cancelledAt: 'x' }, attempt())
				.kind
		).toBe('cancelled');
	});
	it('not found with the body kept: resend the same key now', () => {
		expect(resolveOutcome({ status: 'not_found', command: null }, attempt())).toEqual({
			kind: 'not_committed',
			canResend: true
		});
	});
	it('not found without a body: wait until the original request cannot still run', () => {
		const a = attempt({ body: null });
		expect(
			resolveOutcome({ status: 'not_found', command: null }, a, a.dispatchedAt + 5_000).kind
		).toBe('pending');
		expect(
			resolveOutcome({ status: 'not_found', command: null }, a, a.dispatchedAt + ATTEMPT_SETTLE_MS)
		).toEqual({ kind: 'not_committed', canResend: false });
	});
});

describe('storage', () => {
	const scope = { uid: 'EW-48213', workspaceId: 'ws-1' };
	it('never stores PINs, passwords, tokens, account numbers or the key in the body', () => {
		expect(
			storableBody({
				pin: '1234',
				password: 'x',
				token: 't',
				accountNumber: '0123456789',
				idempotencyKey: 'k',
				amount: '1.00'
			})
		).toEqual({ amount: '1.00' });
		const store = new MemoryStore();
		saveAttempt(store, scope, attempt({ body: { pin: '9876', amount: '1.00' } }));
		const raw = store.getItem(storageKey(scope, 'record_income')) ?? '';
		expect(raw).not.toContain('9876');
		expect(loadAttempt(store, scope, 'record_income', 1_000_000)?.body).toEqual({ amount: '1.00' });
	});
	it('is scoped to person, workspace and command, and expires', () => {
		const store = new MemoryStore();
		saveAttempt(store, scope, attempt());
		expect(
			loadAttempt(store, { ...scope, workspaceId: 'ws-2' }, 'record_income', 1_000_000)
		).toBeNull();
		expect(loadAttempt(store, scope, 'set_allocation', 1_000_000)).toBeNull();
		expect(
			loadAttempt(store, scope, 'record_income', 1_000_000 + ATTEMPT_MAX_AGE_MS + 1)
		).toBeNull();
		expect(store.getItem(storageKey(scope, 'record_income'))).toBeNull();
	});
	it('drops unreadable entries', () => {
		const store = new MemoryStore();
		store.setItem(storageKey(scope, 'record_income'), '{nope');
		expect(loadAttempt(store, scope, 'record_income')).toBeNull();
	});
});

it('labels the attempt without exposing the whole key', () => {
	expect(attemptLabel('k3f92a1b0000000000000')).toBe('K3F9-2A1B');
});
