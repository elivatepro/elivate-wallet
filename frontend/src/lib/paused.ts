// Paused network (Blueprint 16 Part A item 7, owner decision Q10): which app
// pages are writes that are off while the network is paused. Navigation hint
// only; the backend refuses every paused write with `network_not_active`.
//
// Off: record income, new withdrawal, move between pockets, conversion,
// adjustment, reversal, returned funds and invitations (every action there is
// a write). Still open: Home, activity, withdrawals and the queue (payouts and
// reviews of withdrawals approved before the pause carry on), evidence review,
// transfers, pockets, payout accounts (read-only), statements, reports, team
// and member views, offices, roles, audit log, account, support and Billing
// (pay to resume). Mixed pages hide their own write actions.

export const PAUSED_WRITE_ROUTES = [
	'/app/income',
	'/app/withdrawals/new',
	'/app/split/move',
	'/app/convert',
	'/app/adjust',
	'/app/reversals',
	'/app/queue/returns',
	'/app/invitations'
] as const;

/** True when `path` (a pathname) is a write page that is off on a paused network. */
export function pausedWriteRoute(path: string): boolean {
	const clean = path.length > 1 ? path.replace(/\/+$/, '') : path;
	return PAUSED_WRITE_ROUTES.some((route) => clean === route || clean.startsWith(`${route}/`));
}
