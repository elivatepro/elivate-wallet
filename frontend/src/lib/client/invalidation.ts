// Blueprint 20 B6: which cached reads a successful command makes stale.
// CommandAttempt uses the per-command list; every other command (sendCommand,
// sendAccountCommand) falls back to its path. Writes always go to the server;
// this only decides what the device and memory caches forget afterwards.
// Blueprint 23: every page has a kind now, so the lists grew.

import type { CacheKind } from './device-cache';

// Offices show held-money totals too (Greptile P2 on PR #57). Blueprint 23:
// every page that shows money, a money request or a money approval.
const MONEY: readonly CacheKind[] = [
	'balances',
	'history',
	'wallets',
	'offices',
	'withdrawals',
	'queue',
	'transfers',
	'evidence',
	'split',
	'entries',
	'reports',
	'statements'
];
const ORG: readonly CacheKind[] = ['offices', 'members', 'access', 'invitations'];
const SETTINGS: readonly CacheKind[] = ['settings', 'vault'];

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
	// POST reads (a lookup, revealing a payout account to the approver): nothing
	// cached changes.
	[/^\/api\/(payout-accounts\/lookup|support|search|commands)(\/|$|\?)/, []],
	[/^\/api\/queue\/[^/]+\/reveal(\/|$|\?)/, []],
	// Saving, deactivating or choosing the primary bank account.
	[/^\/api\/payout-accounts(\/|$|\?)/, ['payout-accounts', 'withdrawals']],
	[/^\/api\/notifications(\/|$|\?)/, ['notifications']],
	// Export requests add a file to these lists.
	[/^\/api\/(reports|exports)(\/|$|\?)/, ['reports', 'statements']],
	[/^\/api\/statements(\/|$|\?)/, ['statements']],
	// Profile, password, PIN and device sessions.
	[/^\/api\/(account|profile)(\/|$|\?)/, ['account']],
	[/^\/api\/billing(\/|$|\?)/, ['billing']],
	[
		/^\/api\/(income|withdrawals|queue|evidence-reviews|pocket-moves|transfers|conversions|adjustments|reversals|returns|split)(\/|$|\?)/,
		MONEY
	],
	[/^\/api\/nin-reviews(\/|$|\?)/, ['nin-reviews', ...ORG]],
	[/^\/api\/(org|invitations)(\/|$|\?)/, [...ORG, 'audit']],
	[/^\/api\/(backups|restores)(\/|$|\?)/, ['vault']],
	[/^\/api\/(settings|brand)(\/|$|\?)/, SETTINGS]
];

export function invalidatesForPath(path: string): readonly CacheKind[] {
	return PATH_RULES.find(([pattern]) => pattern.test(path))?.[1] ?? [];
}

export function invalidatesFor(command: string, path: string): readonly CacheKind[] {
	return COMMAND_INVALIDATES[command] ?? invalidatesForPath(path);
}
