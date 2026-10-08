import { describe, expect, it } from 'vitest';
import { Schema } from 'effect';
import { PayoutLookupCommand, PayoutRemoveCommand } from './contract/app.js';
import { BackendError, TransportError, type ErrorCode } from './contract/errors.js';
import type { PayoutAccount } from './contract/payout.js';
import {
	accountTitle,
	activeAccounts,
	canMakePrimary,
	cleanAccountNumber,
	formatAdded,
	formatUsable,
	isCoolingOff,
	isRefusal,
	lookupFieldError,
	nextUsableAt,
	payoutMessage,
	pinProblem
} from './payout.js';

const NOW = Date.parse('2026-10-08T12:00:00Z');

const account = (over: Partial<PayoutAccount> = {}): PayoutAccount => ({
	payoutAccountId: '11111111-1111-4111-8111-111111111111',
	bankCode: '058',
	bankName: 'Test Bank',
	accountLast4: '6789',
	accountNumberMasked: '•••• 6789',
	accountName: 'ADA NKEM OBI',
	currency: 'NGN',
	status: 'active',
	nameMatch: 'matched',
	isPrimary: false,
	usableFrom: '2026-10-07T12:00:00Z',
	createdAt: '2026-10-07T12:00:00Z',
	...over
});

const backend = (code: ErrorCode, details: Record<string, unknown> = {}) =>
	new BackendError({
		status: 409,
		code,
		message: `server: ${code}`,
		retryable: false,
		details,
		requestId: 'r'
	});

describe('rows', () => {
	it('titles with the last four only', () => {
		expect(accountTitle(account())).toBe('Test Bank •• 6789');
		expect(accountTitle(account({ bankName: null }))).toBe('058 •• 6789');
	});

	it('lists only active accounts, keeping the backend order', () => {
		const items = [
			account({ payoutAccountId: 'a', isPrimary: true }),
			account({ payoutAccountId: 'b', status: 'deactivated' }),
			account({ payoutAccountId: 'c', status: 'replaced' }),
			account({ payoutAccountId: 'd' })
		];
		expect(activeAccounts(items).map((a) => a.payoutAccountId)).toEqual(['a', 'd']);
	});

	it('knows the 24 h cooling-off', () => {
		expect(isCoolingOff(account(), NOW)).toBe(false);
		expect(isCoolingOff(account({ usableFrom: '2026-10-09T12:00:00Z' }), NOW)).toBe(true);
		expect(isCoolingOff(account({ usableFrom: null }), NOW)).toBe(false);
	});

	it('offers Make primary only for usable, non-primary, non-mismatched accounts', () => {
		expect(canMakePrimary(account(), NOW)).toBe(true);
		expect(canMakePrimary(account({ nameMatch: 'identity_pending' }), NOW)).toBe(true);
		expect(canMakePrimary(account({ isPrimary: true }), NOW)).toBe(false);
		expect(canMakePrimary(account({ nameMatch: 'mismatched' }), NOW)).toBe(false);
		expect(canMakePrimary(account({ status: 'deactivated' }), NOW)).toBe(false);
		expect(canMakePrimary(account({ usableFrom: '2026-10-09T12:00:00Z' }), NOW)).toBe(false);
	});

	it('finds the next cooling-off end', () => {
		const items = [
			account({ usableFrom: '2026-10-09T14:20:00Z' }),
			account({ usableFrom: '2026-10-09T09:00:00Z' }),
			account()
		];
		expect(nextUsableAt(items, NOW)).toBe(Date.parse('2026-10-09T09:00:00Z'));
		expect(nextUsableAt([account()], NOW)).toBeNull();
	});

	it('formats dates like Paper Y02', () => {
		const opts = { locale: 'en-GB', timeZone: 'Africa/Lagos' };
		expect(formatUsable('2026-10-09T13:20:00Z', opts)).toBe('9 Oct, 14:20');
		expect(formatAdded('2026-03-14T10:00:00Z', opts)).toBe('14 Mar 2026');
	});

	it('drops spaces from a typed account number', () => {
		expect(cleanAccountNumber(' 0123 456 789 ')).toBe('0123456789');
	});
});

describe('outcomes', () => {
	it('keeps PIN problems in the dialog', () => {
		expect(pinProblem(backend('step_up_required'))).toEqual({
			kind: 'pin',
			message: 'Enter your PIN to confirm.'
		});
		expect(pinProblem(backend('pin_incorrect', { attemptsRemaining: 1 }))).toEqual({
			kind: 'pin',
			message: 'That PIN is incorrect. 1 try left.'
		});
		expect(pinProblem(backend('pin_incorrect', { attemptsRemaining: 3 }))).toEqual({
			kind: 'pin',
			message: 'That PIN is incorrect. 3 tries left.'
		});
		expect(pinProblem(backend('pin_locked'))).toEqual({ kind: 'locked' });
		expect(pinProblem(backend('conflict'))).toBeNull();
		expect(pinProblem(new TransportError({ reason: 'timeout', status: null }))).toBeNull();
	});

	it('keeps the idempotency key only for an unknown outcome', () => {
		expect(isRefusal(backend('conflict'))).toBe(true);
		expect(isRefusal(new TransportError({ reason: 'network', status: null }))).toBe(false);
		expect(isRefusal(undefined)).toBe(false);
	});

	it('maps lookup errors to their field', () => {
		expect(lookupFieldError(backend('account_not_found'))).toEqual({
			field: 'accountNumber',
			message: 'No account with that number at this bank.'
		});
		expect(lookupFieldError(backend('bank_unknown'))?.field).toBe('bankCode');
		expect(lookupFieldError(backend('validation_error', { field: 'accountNumber' }))?.field).toBe(
			'accountNumber'
		);
		expect(lookupFieldError(backend('rate_limited'))).toBeNull();
	});

	it('says one short line per refusal', () => {
		expect(payoutMessage(backend('conflict', { reason: 'account_limit' }), 'confirm')).toBe(
			'You can keep up to 5 accounts. Remove one first.'
		);
		expect(payoutMessage(backend('payout_lookup_expired'), 'confirm')).toBe(
			'That check expired. Look the account up again.'
		);
		expect(payoutMessage(backend('payout_name_mismatch'), 'confirm')).toBe(
			'This account’s name doesn’t match your verified name.'
		);
		expect(payoutMessage(backend('rate_limited'), 'lookup')).toBe(
			'Too many account checks. Try again later.'
		);
		expect(payoutMessage(new TransportError({ reason: 'timeout', status: null }), 'lookup')).toBe(
			'We couldn’t check the account right now. Try again shortly.'
		);
		expect(payoutMessage(new TransportError({ reason: 'timeout', status: null }), 'remove')).toBe(
			'We couldn’t confirm that. Try again.'
		);
		expect(payoutMessage(backend('internal_error'), 'primary')).toBe('server: internal_error');
	});
});

describe('request schemas', () => {
	const key = 'k'.repeat(32);

	it('accepts a 10-digit string and refuses anything else', () => {
		const decode = Schema.decodeUnknownSync(PayoutLookupCommand);
		expect(decode({ bankCode: '058', accountNumber: '0123456789', idempotencyKey: key })).toEqual({
			bankCode: '058',
			accountNumber: '0123456789',
			idempotencyKey: key
		});
		expect(() =>
			decode({ bankCode: '058', accountNumber: 123456789, idempotencyKey: key })
		).toThrow();
		expect(() =>
			decode({ bankCode: '058', accountNumber: '012345678', idempotencyKey: key })
		).toThrow();
		expect(() =>
			decode({ bankCode: '058', accountNumber: '0123456789', pin: '12', idempotencyKey: key })
		).toThrow();
	});

	it('forwards only known fields', () => {
		const decoded = Schema.decodeUnknownSync(PayoutRemoveCommand)({
			reason: 'Closed it',
			pin: '1357',
			idempotencyKey: key,
			accountNumber: '0123456789'
		});
		expect(decoded).toEqual({ reason: 'Closed it', pin: '1357', idempotencyKey: key });
	});
});
