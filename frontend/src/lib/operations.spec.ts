import { describe, expect, it } from 'vitest';
import { BackendError } from '#lib/contract/errors.js';
import { pausedMessage, stoppedHere } from './operations';

const conflict = (details: Record<string, unknown>) =>
	new BackendError({
		status: 409,
		code: 'conflict',
		message: 'x',
		retryable: false,
		details,
		requestId: null
	});

describe('stoppedHere', () => {
	it('matches a write page to its stopped operation', () => {
		expect(stoppedHere('/app/withdrawals/new', ['withdrawals'])).toBe('withdrawals');
		expect(stoppedHere('/app/income/', ['income'])).toBe('income');
		expect(stoppedHere('/app/queue/returns/abc', ['returned_funds'])).toBe('returned_funds');
	});
	it('leaves other pages and running operations alone', () => {
		expect(stoppedHere('/app/withdrawals', ['withdrawals'])).toBeNull();
		expect(stoppedHere('/app/income', ['withdrawals'])).toBeNull();
		expect(stoppedHere('/app/incomes', ['income'])).toBeNull();
	});
});

describe('pausedMessage', () => {
	it('names the paused operation', () => {
		expect(pausedMessage(conflict({ reason: 'operation_paused', operation: 'withdrawals' }))).toBe(
			'Withdrawals are paused for now. Your money is safe; open requests keep their place.'
		);
		expect(pausedMessage(conflict({ reason: 'operation_paused', operation: 'income' }))).toMatch(
			/^Recording income is paused/
		);
	});
	it('ignores other failures', () => {
		expect(pausedMessage(conflict({ reason: 'invalid_transition' }))).toBeNull();
		expect(pausedMessage(undefined)).toBeNull();
	});
});
