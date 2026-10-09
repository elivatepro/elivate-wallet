import { describe, expect, it } from 'vitest';
import {
	allocate,
	fieldOfFailure,
	formatSent,
	formatSize,
	groupAmount,
	initials,
	isDefinitive,
	isFormRefusal,
	isTargetRefusal,
	localToday,
	parseAmount,
	receiptProblem,
	refusalLead,
	shortPercent,
	shortPocket,
	sniffReceipt,
	validateDraft
} from './income.js';
import { BackendError, TransportError } from './contract/errors.js';

const DEFAULT_SPLIT = [
	{ pocketId: 'a', name: 'Point Value', basisPoints: 4000 },
	{ pocketId: 'b', name: 'Business Investment', basisPoints: 1000 },
	{ pocketId: 'c', name: 'Personal Investment', basisPoints: 1500 },
	{ pocketId: 'd', name: 'Upkeep', basisPoints: 2500 },
	{ pocketId: 'e', name: 'Savings', basisPoints: 1000 }
];
const amounts = (amount: string) => allocate(amount, 2, DEFAULT_SPLIT).map((l) => l.amount);

const backend = (code: BackendError['code'], details: Record<string, unknown> = {}) =>
	new BackendError({
		status: 400,
		code,
		message: code,
		retryable: false,
		details,
		requestId: null
	});

describe('parseAmount', () => {
	it('canonicalises to the currency scale', () => {
		expect(parseAmount('180000', 2)).toBe('180000.00');
		expect(parseAmount('₦180,000.5', 2)).toBe('180000.50');
		expect(parseAmount(' $1,234.56 ', 2)).toBe('1234.56');
		expect(parseAmount('007.10', 2)).toBe('7.10');
		expect(parseAmount('0.01', 2)).toBe('0.01');
	});

	it('refuses zero, negatives, extra decimals and junk', () => {
		for (const bad of ['', '0', '0.00', '-5', '1.234', '1e5', 'abc', '1.2.3', '1234567890123456']) {
			expect(parseAmount(bad, 2)).toBeNull();
		}
	});

	it('groups for display', () => {
		expect(groupAmount('180000.00')).toBe('180,000.00');
		expect(groupAmount('999.10')).toBe('999.10');
	});
});

describe('allocate (mirror of ledger.allocate, Blueprint 04 042 cases)', () => {
	it('gives one kobo to the largest fraction', () => {
		expect(amounts('0.01')).toEqual(['0.01', '0.00', '0.00', '0.00', '0.00']);
	});

	it('gives leftover kobo to the largest remainders', () => {
		expect(amounts('0.03')).toEqual(['0.01', '0.00', '0.01', '0.01', '0.00']);
	});

	it('splits exactly when it divides', () => {
		expect(amounts('1000.00')).toEqual(['400.00', '100.00', '150.00', '250.00', '100.00']);
		expect(
			allocate('180000.00', 2, [
				{ pocketId: 'm', name: 'Main', basisPoints: 6000 },
				{ pocketId: 's', name: 'Savings', basisPoints: 3000 },
				{ pocketId: 'g', name: 'Giving', basisPoints: 1000 }
			]).map((l) => l.amount)
		).toEqual(['108000.00', '54000.00', '18000.00']);
	});

	it('breaks equal remainders by display order', () => {
		const thirds = [
			{ pocketId: 'x', name: 'X', basisPoints: 3334 },
			{ pocketId: 'y', name: 'Y', basisPoints: 3333 },
			{ pocketId: 'z', name: 'Z', basisPoints: 3333 }
		];
		expect(allocate('0.02', 2, thirds).map((l) => l.amount)).toEqual(['0.01', '0.01', '0.00']);
	});

	it('always sums exactly and stays within one minor unit of each share', () => {
		for (let i = 0; i < 500; i++) {
			const units = BigInt(Math.floor(Math.random() * 1e12) + 1);
			const amount = `${units / 100n}.${String(units % 100n).padStart(2, '0')}`;
			const lines = allocate(amount, 2, DEFAULT_SPLIT);
			const total = lines.reduce((sum, l) => sum + BigInt(l.amount.replace('.', '')), 0n);
			expect(total).toBe(units);
			for (const l of lines) {
				const got = BigInt(l.amount.replace('.', '')) * 10000n;
				const exact = units * BigInt(l.basisPoints);
				expect(got >= exact - 10000n && got <= exact + 10000n).toBe(true);
			}
		}
	});

	it('keeps zero-share lines', () => {
		const lines = allocate('10.00', 2, [
			{ pocketId: 'a', name: 'A', basisPoints: 10000 },
			{ pocketId: 'b', name: 'B', basisPoints: 0 }
		]);
		expect(lines.map((l) => l.amount)).toEqual(['10.00', '0.00']);
	});
});

describe('small helpers', () => {
	it('formats percents, sizes, initials and today', () => {
		expect(shortPercent(4000)).toBe('40');
		expect(shortPercent(1250)).toBe('12.5');
		expect(shortPercent(3333)).toBe('33.33');
		expect(formatSize(219_136)).toBe('214 KB');
		expect(formatSize(1_258_291)).toBe('1.2 MB');
		expect(initials('Adaeze Nwosu', 'EW-48213')).toBe('AN');
		expect(initials('Ada', 'EW-48213')).toBe('A');
		expect(initials(null, 'EW-48213')).toBe('13');
		expect(localToday(new Date(2026, 9, 2, 23, 30))).toBe('2026-10-02');
	});

	it('sniffs receipt types from bytes', () => {
		expect(sniffReceipt(new TextEncoder().encode('%PDF-1.7'))).toBe('application/pdf');
		expect(sniffReceipt(new Uint8Array([0xff, 0xd8, 0xff, 0xe0]))).toBe('image/jpeg');
		expect(sniffReceipt(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))).toBe(
			'image/png'
		);
		expect(sniffReceipt(new TextEncoder().encode('GIF89a'))).toBeNull();
	});

	it('checks receipts locally', () => {
		expect(receiptProblem({ size: 10, type: 'application/pdf' }, 0)).toBeNull();
		expect(receiptProblem({ size: 10, type: 'application/pdf' }, 5)).toMatch(/up to 5/);
		expect(receiptProblem({ size: 0, type: 'image/png' }, 0)).toMatch(/empty/);
		expect(receiptProblem({ size: 11 * 1024 * 1024, type: 'image/png' }, 0)).toMatch(/10 MB/);
		expect(receiptProblem({ size: 10, type: 'image/gif' }, 0)).toMatch(/PDF, JPEG or PNG/);
	});
});

describe('validateDraft', () => {
	const ok = {
		targetMembershipId: '6b0f8f3e-2a4c-4b8e-9d55-0c7a1d2e3f40',
		currency: 'NGN' as const,
		scale: 2,
		amount: '₦180,000.00',
		source: 'Fiverr order',
		receivedOn: '2026-10-02',
		notes: '',
		providerReference: '',
		feeAmount: '',
		feeCurrency: 'NGN' as const,
		receipts: 1,
		today: '2026-10-08'
	};

	it('accepts a complete draft', () => {
		expect(validateDraft(ok)).toEqual({});
	});

	it('names every missing or invalid field', () => {
		const errors = validateDraft({
			...ok,
			targetMembershipId: null,
			amount: '0',
			source: '  ',
			receivedOn: '2026-10-09',
			feeAmount: 'x',
			receipts: 0
		});
		expect(Object.keys(errors).sort()).toEqual(
			['amount', 'fee', 'receipts', 'receivedOn', 'source', 'target'].sort()
		);
	});
});

describe('outcomes', () => {
	it('treats only backend refusals as definitive (W-00)', () => {
		expect(isDefinitive(backend('target_not_eligible'))).toBe(true);
		expect(isDefinitive(backend('step_up_required'))).toBe(true);
		expect(isDefinitive(backend('internal_error'))).toBe(false);
		expect(isDefinitive(new TransportError({ reason: 'timeout', status: null }))).toBe(false);
		expect(isDefinitive(undefined)).toBe(false);
	});

	it('maps validation fields to form fields', () => {
		expect(fieldOfFailure(backend('validation_error', { field: 'receivedOn' }))).toBe('receivedOn');
		expect(fieldOfFailure(backend('validation_error', { field: 'fee.amount' }))).toBe('fee');
		expect(fieldOfFailure(backend('validation_error', { field: 'mimeType' }))).toBe('receipts');
		expect(fieldOfFailure(backend('evidence_invalid'))).toBeNull();
	});
});

describe('J01–J05 helpers', () => {
	it('shortens pocket names for the mobile preview', () => {
		expect(shortPocket('Business Investment')).toBe('Business Inv.');
		expect(shortPocket('Upkeep')).toBe('Upkeep');
	});

	it('formats the sent time', () => {
		expect(formatSent(Date.parse('2026-10-02T14:12:00Z'), 'en-GB', 'UTC')).toBe(
			'2 Oct 2026, 14:12'
		);
	});

	it('routes refusals to the form or to J05', () => {
		expect(isFormRefusal(backend('validation_error'))).toBe(true);
		expect(isFormRefusal(backend('evidence_invalid'))).toBe(true);
		expect(isFormRefusal(backend('target_not_eligible'))).toBe(false);
		expect(isTargetRefusal(backend('target_not_eligible'))).toBe(true);
		expect(isTargetRefusal(backend('network_not_active'))).toBe(false);
		expect(refusalLead(backend('target_not_eligible'), 'Musa Bello')).toBe(
			'Musa Bello’s membership or account isn’t active. Nothing was posted.'
		);
		expect(refusalLead(backend('network_not_active'), 'Musa Bello')).toMatch(
			/isn’t active.*Nothing was posted\.$/
		);
	});
});
