// Own-money pages (slice 21, owner decision 2026-10-10): a workspace whose
// role holds no wallet (the President Team: A-03 gives it none of the
// own-wallet permissions, and D-01 creates no wallet for it) must not see
// modules it can't use. Navigation hint only; the backend authorizes every
// read and command.

/** Each own-money page and the permission that makes it usable. */
export const OWN_WALLET_ROUTES = [
	['/app/payout-accounts', 'manage_own_payout_accounts'],
	['/app/withdrawals', 'initiate_own_withdrawal'],
	['/app/statements', 'export_own_statement'],
	['/app/activity', 'view_own_financials'],
	['/app/split/move', 'transfer_between_own_pockets'],
	// Slice 28: a leader's own wallet, off Home.
	['/app/wallet', 'view_own_wallet']
] as const;

export type OwnWalletPermission = (typeof OWN_WALLET_ROUTES)[number][1];

/** The permission an own-money page needs, or null for any other page. */
export function ownWalletPermission(path: string): OwnWalletPermission | null {
	const clean = path.length > 1 ? path.replace(/\/+$/, '') : path;
	const hit = OWN_WALLET_ROUTES.find(([route]) => clean === route || clean.startsWith(`${route}/`));
	return hit ? hit[1] : null;
}

/**
 * True when `path` is an own-money page the workspace can't use. Only once the
 * permissions are known (null while loading: never block on a guess).
 */
export function ownWalletBlocked(path: string, permissions: readonly string[] | null): boolean {
	if (!permissions) return false;
	const needed = ownWalletPermission(path);
	return needed !== null && !permissions.includes(needed);
}
