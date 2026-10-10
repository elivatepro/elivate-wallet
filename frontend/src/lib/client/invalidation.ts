// Blueprint 20 B6: which cached reads a successful command makes stale.
// CommandAttempt uses the per-command list; every other command (sendCommand)
// falls back to its path. Writes always go to the server; this only decides
// what the device and memory caches forget afterwards.

import type { CacheKind } from './device-cache';

const MONEY: readonly CacheKind[] = ['balances', 'history', 'wallets'];
const ORG: readonly CacheKind[] = ['offices', 'members'];
const SETTINGS: readonly CacheKind[] = ['settings'];

/** Per backend command name (CommandAttempt). */
export const COMMAND_INVALIDATES: Readonly<Record<string, readonly CacheKind[]>> = {
	record_income: MONEY,
	request_withdrawal: MONEY,
	submit_conversion: MONEY,
	submit_adjustment: MONEY,
	submit_returned_funds: MONEY,
	reverse_transaction: MONEY,
	request_pocket_transfer: MONEY,
	set_allocation: MONEY
};

/** Path rules for commands sent without a CommandAttempt; the first match wins. */
const PATH_RULES: readonly (readonly [RegExp, readonly CacheKind[]])[] = [
	// POST reads and per-device state: nothing cached changes.
	[/^\/api\/(payout-accounts|notifications|reports|exports|support|account|search)(\/|$|\?)/, []],
	[
		/^\/api\/(income|withdrawals|queue|evidence-reviews|pocket-moves|transfers|conversions|adjustments|reversals|returns|split)(\/|$|\?)/,
		MONEY
	],
	[/^\/api\/(org|invitations|nin-reviews)(\/|$|\?)/, ORG],
	[/^\/api\/(settings|brand)(\/|$|\?)/, SETTINGS]
];

export function invalidatesForPath(path: string): readonly CacheKind[] {
	return PATH_RULES.find(([pattern]) => pattern.test(path))?.[1] ?? [];
}

export function invalidatesFor(command: string, path: string): readonly CacheKind[] {
	return COMMAND_INVALIDATES[command] ?? invalidatesForPath(path);
}
