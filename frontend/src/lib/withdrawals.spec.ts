import { describe, expect, it } from 'vitest';
import { Exit, Schema } from 'effect';
import { RequestWithdrawalCommand, Withdrawal } from '#lib/contract/withdrawals.js';
import {
	calendarDate,
	cancelSummary,
	debited,
	detailPill,
	detailSteps,
	memberLine,
	moveMessage,
	onHoldLine,
	openWithdrawalConflict,
	pendingStage,
	phoneLine,
	stillOpenLine,
	withdrawalHref,
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

// ── Blueprint 44: follow-through ──
const person = (uid: string, name: string) => ({ uid, name });
const member = person('EW-AAAA-0001', 'Ada Obi');
const leader = person('EW-BBBB-0002', 'Tunde Bello');
const wd = (over: Record<string, unknown>) =>
	({
		withdrawalId: '00000000-0000-0000-0000-000000000044',
		reference: 'WDR-VVXS-5SR8',
		status: 'requested',
		amount: '5000.00',
		pocket: { pocketId: '00000000-0000-0000-0000-000000000001', name: 'Business Investment' },
		member,
		decidedBy: null,
		decisionReason: null,
		createdAt: '2026-10-16T21:15:00Z',
		approvedAt: null,
		decidedAt: null,
		completedAt: null,
		payout: null,
		destination: { bankName: 'United Bank For Africa', accountLast4: '1988' },
		...over
	}) as unknown as Withdrawal;
const TZ = 'Africa/Lagos';

describe('Blueprint 44 rows (D5)', () => {
	it('says what happened last on desktop', () => {
		expect(memberLine(wd({}), TZ)).toBe('Requested 16 Oct, 22:15 · WDR-VVXS-5SR8');
		expect(memberLine(wd({}), TZ, true)).toBe('Requested 16 Oct, 22:15');
		expect(memberLine(wd({ status: 'approved', approvedAt: '2026-10-01T09:00:00Z' }), TZ)).toBe(
			'Approved 1 Oct · waiting for payout'
		);
		expect(
			memberLine(
				wd({ status: 'cancelled', decidedBy: member, decidedAt: '2026-10-15T09:00:00Z' }),
				TZ
			)
		).toBe('Cancelled by you 15 Oct');
		expect(
			memberLine(
				wd({
					status: 'rejected',
					decidedBy: leader,
					decidedAt: '2026-10-09T09:00:00Z',
					decisionReason: 'Account name mismatch'
				}),
				TZ
			)
		).toBe('Rejected 9 Oct · Account name mismatch');
	});
	it('says pocket and date on phones', () => {
		expect(phoneLine(wd({}), TZ)).toBe('Business Investment · 16 Oct');
	});
	it('links to the withdrawal', () => {
		expect(withdrawalHref('abc')).toBe('/app/withdrawals/abc');
	});
});

describe('Blueprint 44 detail (D4)', () => {
	it('shows the stage in the card', () => {
		expect(detailPill(wd({}))).toEqual({ label: 'Waiting for approval', tone: 'warning' });
		expect(detailPill(wd({ status: 'rejected' })).tone).toBe('danger');
	});
	it('walks Requested → Approval → Paid out', () => {
		const waiting = detailSteps(wd({}), TZ);
		expect(waiting.map((s) => [s.label, s.state])).toEqual([
			['Requested', 'done'],
			['Approval', 'current'],
			['Paid out', 'todo']
		]);
		expect(waiting[0]?.sub).toBe('16 Oct, 22:15');
		expect(waiting[1]?.sub).toBe('With your team leader');
		expect(waiting[2]?.sub).toBe('To your bank');
		const paid = detailSteps(
			wd({
				status: 'completed',
				approvedAt: '2026-10-17T08:00:00Z',
				completedAt: '2026-10-17T10:30:00Z'
			}),
			TZ
		);
		expect(paid.map((s) => s.state)).toEqual(['done', 'done', 'done']);
		expect(paid[2]?.sub).toBe('17 Oct, 11:30');
	});
	it('ends where it stopped', () => {
		const cancelled = detailSteps(
			wd({ status: 'cancelled', decidedBy: member, decidedAt: '2026-10-17T08:00:00Z' }),
			TZ
		);
		expect(cancelled.map((s) => [s.label, s.state])).toEqual([
			['Requested', 'done'],
			['Cancelled by you', 'stopped']
		]);
		const byLeader = detailSteps(
			wd({
				status: 'cancelled',
				decidedBy: leader,
				approvedAt: '2026-10-16T22:00:00Z',
				decidedAt: '2026-10-17T08:00:00Z'
			}),
			TZ
		);
		expect(byLeader.map((s) => s.label)).toEqual([
			'Requested',
			'Approved',
			'Cancelled by Tunde Bello'
		]);
		const rejected = detailSteps(
			wd({ status: 'rejected', decidedAt: '2026-10-17T08:00:00Z', decisionReason: 'Wrong pocket' }),
			TZ
		);
		expect(rejected[1]).toMatchObject({
			label: 'Not approved',
			state: 'stopped',
			note: 'Wrong pocket'
		});
	});
});

describe('Blueprint 44 copy (D1, D3, D6, D7)', () => {
	it('says where cancelled money goes', () => {
		expect(cancelSummary(wd({}))).toBe('₦5,000.00 goes back to Business Investment.');
	});
	it('says the request is on hold, and what keeps a new one waiting', () => {
		expect(onHoldLine('4000.00')).toBe('₦4,000.00 is on hold until it’s approved.');
		expect(stillOpenLine('5000.00')).toBe('Your withdrawal of ₦5,000.00 is still open.');
		// Hide amounts (Greptile on PR #83).
		expect(stillOpenLine('5000.00', true)).toBe('Your withdrawal of ₦•••••• is still open.');
		expect(onHoldLine('4000.00', true)).toBe('₦•••••• is on hold until it’s approved.');
	});
	it('labels open withdrawals by stage', () => {
		expect(pendingStage('requested')).toEqual({ label: 'Requested', tone: 'warning' });
		expect(pendingStage('approved')).toEqual({ label: 'Approved', tone: 'info' });
	});
	it('recognises the one-open-withdrawal refusal', () => {
		const failure = {
			_tag: 'BackendError',
			code: 'conflict',
			status: 409,
			message: 'Conflict',
			requestId: 'r',
			details: { reason: 'open_withdrawal_exists', withdrawalId: 'w-1' }
		} as const;
		expect(openWithdrawalConflict(failure as never)).toBe('w-1');
		expect(moveMessage(failure as never)).toMatch(/already an open withdrawal/);
		expect(
			openWithdrawalConflict({ ...failure, details: { reason: 'payout_open' } } as never)
		).toBeNull();
	});
});
