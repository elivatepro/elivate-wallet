import { describe, expect, it } from 'vitest';
import { Exit, Schema } from 'effect';
import { RequestWithdrawalCommand, Withdrawal } from '#lib/contract/withdrawals.js';
import {
	calendarDate,
	debited,
	fixLabel,
	memberStage,
	mismatchedFields,
	progress,
	reasonText,
	withdrawalStage,
	withinRequested
} from './withdrawals';

const base = {
	status: 'approved',
	payout: null,
	createdAt: '2026-10-05T09:42:00Z',
	approvedAt: '2026-10-05T10:00:00Z'
} as unknown as Withdrawal;

const withPayout = (status: string, check: string | null = 'queued') =>
	({
		...base,
		payout: {
			status,
			revision: 1,
			createdAt: base.createdAt,
			revisions: [
				{ revision: 1, createdAt: base.createdAt, check: check ? { status: check } : null }
			]
		}
	}) as unknown as Withdrawal;

describe('withdrawal stages', () => {
	it('names the approver sub-states', () => {
		expect(withdrawalStage(base).label).toBe('Approved · pay out');
		expect(withdrawalStage(withPayout('verifying')).label).toBe('Checking receipt');
		expect(withdrawalStage(withPayout('verifying', 'dead')).label).toBe('Check delayed');
		expect(withdrawalStage(withPayout('correction_required')).label).toBe('Correction needed');
		expect(withdrawalStage(withPayout('needs_review')).label).toBe('In review');
		expect(withdrawalStage(withPayout('rejected')).label).toBe('Receipt rejected');
	});

	it('shows members a plain Approved', () => {
		expect(memberStage(withPayout('correction_required')).label).toBe('Approved');
	});

	it('tracks progress', () => {
		expect(progress(base).map((s) => s.state)).toEqual(['done', 'done', 'current', 'todo']);
		expect(progress(withPayout('verifying')).map((s) => s.state)).toEqual([
			'done',
			'done',
			'done',
			'current'
		]);
	});
});

describe('receipt reasons', () => {
	it('maps reasons to fields and fixes', () => {
		expect([...mismatchedFields(['paymentDate_mismatch'])]).toEqual(['date']);
		expect(fixLabel(['paymentDate_mismatch'])).toBe('Fix the date');
		expect(fixLabel(['amount_mismatch', 'recipientName_mismatch'])).toBe('Fix the record');
		expect(reasonText('unknown_reason')).toMatch(/didn’t match/);
	});
});

describe('money and dates', () => {
	it('keeps sent + fee within the request exactly', () => {
		expect(withinRequested('47950.00', '50.00', '48000.00')).toBe(true);
		expect(withinRequested('47950.01', '50', '48000')).toBe(false);
		expect(withinRequested('48000', null, '48000.00')).toBe(true);
	});

	it('shows what left the pocket, not what was requested', () => {
		const done = {
			status: 'completed',
			amount: '1500.00',
			payout: { revision: 1, revisions: [{ revision: 1, amount: '1000.00', fee: null }] }
		} as unknown as Withdrawal;
		expect(debited(done)).toBe('1000.00');
		expect(debited(base)).toBe(base.amount);
	});

	it('never shifts a calendar date', () => {
		expect(calendarDate('2026-10-05')).toBe('5 Oct 2026');
	});
});

describe('the withdrawal reason (Blueprint 40)', () => {
	const body = {
		accountId: '00000000-0000-4000-8000-000000000001',
		amount: '2500.00',
		payoutAccountId: '00000000-0000-4000-8000-000000000002',
		idempotencyKey: 'k-0000000000000001'
	};
	const decode = (value: unknown) =>
		Exit.isSuccess(Schema.decodeUnknownExit(RequestWithdrawalCommand)(value));

	it('is required, 3–500 characters, in the request body', () => {
		expect(decode({ ...body, reason: 'School fees' })).toBe(true);
		expect(decode(body)).toBe(false);
		expect(decode({ ...body, reason: 'ab' })).toBe(false);
		expect(decode({ ...body, reason: 'x'.repeat(501) })).toBe(false);
	});

	it('is optional and nullable on reads (older withdrawals have none)', () => {
		const reasonOf = Schema.decodeUnknownSync(Schema.Struct({ reason: Withdrawal.fields.reason }));
		expect(reasonOf({ reason: 'School fees' })).toEqual({ reason: 'School fees' });
		expect(reasonOf({ reason: null })).toEqual({ reason: null });
		expect(reasonOf({})).toEqual({});
	});
});
