// Kill switches in the Wallet app (Blueprint 18, W-23, owner answer Q4): which
// write page each stopped operation turns off, and the refusal copy. A
// navigation hint only: the database refuses every stopped operation with
// `conflict` + details.reason `operation_paused`.

import type { ApiFailure } from '#lib/contract/errors.js';

export const OPERATION_NAMES: Readonly<Record<string, string>> = {
	withdrawals: 'Withdrawals',
	payouts: 'Payout recording',
	transfers: 'Pocket moves',
	conversion: 'Currency conversion',
	income: 'Recording income',
	adjustments: 'Adjustments',
	reversals: 'Reversals',
	returned_funds: 'Recording returned funds'
};

/** Write pages each operation covers (longest match wins). */
const ROUTES: ReadonlyArray<readonly [string, string]> = [
	['/app/income', 'income'],
	['/app/withdrawals/new', 'withdrawals'],
	['/app/split/move', 'transfers'],
	['/app/convert', 'conversion'],
	['/app/adjust', 'adjustments'],
	['/app/reversals', 'reversals'],
	['/app/queue/returns', 'returned_funds']
];

/** The stopped operation that turns off this page, or null. */
export function stoppedHere(path: string, stopped: readonly string[]): string | null {
	const clean = path.length > 1 ? path.replace(/\/+$/, '') : path;
	for (const [route, operation] of ROUTES) {
		if ((clean === route || clean.startsWith(`${route}/`)) && stopped.includes(operation)) {
			return operation;
		}
	}
	return null;
}

/** Banner copy for a stopped operation. */
export function pausedCopy(operation: string): { title: string; lead: string } {
	const name = OPERATION_NAMES[operation] ?? 'This';
	const verb = name.endsWith('s') && !name.startsWith('Recording') ? 'are' : 'is';
	return {
		title: `${name} ${verb} paused for now`,
		lead: 'Your money is safe; open requests keep their place.'
	};
}

/** "Withdrawals are paused for now…" when a command was refused by a stop. */
export function pausedMessage(failure: ApiFailure | undefined): string | null {
	if (failure?._tag !== 'BackendError' || failure.code !== 'conflict') return null;
	if (failure.details.reason !== 'operation_paused') return null;
	const { title, lead } = pausedCopy(String(failure.details.operation ?? ''));
	return `${title}. ${lead}`;
}
