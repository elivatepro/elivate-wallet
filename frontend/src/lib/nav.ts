// Blueprint 25: the app's navigation, derived once from the workspace's
// capabilities (Paper "Navigation v5", NV01–NV03). The desktop sidebar is
// split into sections, the mobile pill bar gets a tab set per role, and the
// More page lists the same sections. Navigation hints only: every read and
// command is still authorized by the backend (A-01).
//
// The items keep the permissions they had before this slice (Blueprints 07–22);
// only their grouping and a few labels change.

import type { Role } from './contract/common';

export type NavIcon =
	| 'home'
	| 'team'
	| 'activity'
	| 'withdraw'
	| 'more'
	| 'approvals'
	| 'people'
	| 'queue'
	| 'transfers'
	| 'evidence'
	| 'identity'
	| 'reversals'
	| 'income'
	| 'wallets'
	| 'convert'
	| 'reports'
	| 'members'
	| 'offices'
	| 'invitations'
	| 'access'
	| 'settings'
	| 'billing'
	| 'audit'
	| 'payout'
	| 'statements'
	| 'split';

export interface NavItem {
	readonly id: string;
	readonly label: string;
	readonly href: string;
	readonly icon: NavIcon;
	/** Path prefixes this item is current for ('/app' itself matches exactly). */
	readonly match: readonly string[];
	/** Open tasks behind this item (Approvals), when known. */
	readonly count?: number;
	/** The count is the coral one (withdrawals waiting). */
	readonly accent?: boolean;
}

export type SectionId = 'top' | 'approvals' | 'money' | 'people' | 'workspace' | 'wallet';

export interface NavSection {
	readonly id: SectionId;
	/** Heading ("APPROVALS"); null for the top group. */
	readonly label: string | null;
	readonly items: readonly NavItem[];
}

export interface NavTab extends NavItem {
	/** A dot on the icon: something here waits for this person. */
	readonly dot: boolean;
}

/**
 * Live "needs your action" tasks of the bell (Blueprint 13), counted by what
 * they ask for. Null before the first read.
 */
export interface TaskCounts {
	readonly withdrawals: number;
	readonly payouts: number;
	readonly transfers: number;
	readonly evidence: number;
	readonly identity: number;
}

export interface NavInput {
	/** The workspace's effective permissions; null before they load or offline. */
	readonly permissions: readonly string[] | null;
	readonly role: Role | null;
	/** The current Billing Owner (Blueprint 16) sees Billing too. */
	readonly billingOwner: boolean;
	readonly tasks: TaskCounts | null;
	/**
	 * The Home kind saved with the workspace summary (offline, or before the
	 * capabilities load): keeps a network Home a network Home.
	 */
	readonly networkHomeHint?: boolean | undefined;
}

export interface NavModel {
	readonly sections: readonly NavSection[];
	readonly tabs: readonly NavTab[];
	/**
	 * Home shows the network overview: a leadership workspace that holds no
	 * money (President Team, a director whose funds are not managed).
	 */
	readonly networkHome: boolean;
	/** The workspace holds the person's own wallet. */
	readonly wallet: boolean;
	/** Everything under Approvals, for Home's "Needs your action". */
	readonly approvals: readonly NavItem[];
}

/** Bell task kinds (notify.task_open) → the count they add to. */
const TASK_KINDS: Record<string, keyof TaskCounts> = {
	'task.withdrawal_approve': 'withdrawals',
	'task.payout_record': 'payouts',
	'task.payout_fix': 'payouts',
	'task.transfer_approve': 'transfers',
	'task.payout_review': 'evidence',
	'task.entry_review': 'evidence',
	'task.nin_review': 'identity'
};

/** Counts the bell's open tasks by what they ask for. */
export function countTasks(actions: readonly { readonly kind: string }[]): TaskCounts {
	const counts = { withdrawals: 0, payouts: 0, transfers: 0, evidence: 0, identity: 0 };
	for (const action of actions) {
		const key = TASK_KINDS[action.kind];
		if (key) counts[key] += 1;
	}
	return counts;
}

/** Most tabs the pill bar holds (390 px, checked at 320 px). */
export const MAX_TABS = 5;

export function navModel(input: NavInput): NavModel {
	const { permissions, role, tasks } = input;
	const can = (key: string) => permissions?.includes(key) ?? false;
	const president = role === 'president_team_member';
	/**
	 * Slice 21: own-money entries follow the own-wallet permissions, which the
	 * President Team never holds (A-03). Before they load (or offline) the role
	 * stands in, so a member's Activity stays reachable offline.
	 */
	const own = (key: string) => (permissions ? can(key) : role !== null && !president);
	const wallet = own('view_own_wallet') || own('view_own_financials');
	const leader = can('view_managed_wallets') || can('view_scoped_financial_reports');
	const leads = president || can('manage_members') || can('view_managed_wallets');
	const reports = can('view_scoped_financial_reports') || can('export_scoped_reports');
	/** Blueprint 06 Q4: NIN reviews (the backend re-checks each review). */
	const reviewer = president || role === 'world_team_member';
	const billing = can('manage_subscription') || input.billingOwner;
	const settings = can('manage_team_settings') || can('request_restore');
	// Offline (no permissions) the saved Home kind stands in; without one the
	// President Team (never a wallet) still gets its network Home.
	const networkHome =
		permissions !== null ? !wallet && leader : (input.networkHomeHint ?? president);

	const item = (
		id: string,
		label: string,
		href: string,
		icon: NavIcon,
		extra: Partial<Pick<NavItem, 'match' | 'count' | 'accent'>> = {}
	): NavItem => ({ id, label, href, icon, match: extra.match ?? [href], ...extra });
	const pick = (...items: (NavItem | false)[]) => items.filter((i): i is NavItem => !!i);

	// The President's network has no money feed of its own: their Activity is
	// the network's audit log (Blueprint 25, open for the owner).
	const activity = own('view_own_financials')
		? item('activity', 'Activity', '/app/activity', 'activity')
		: president
			? item('activity', 'Activity', '/app/audit', 'activity')
			: null;

	const top = pick(
		item('home', networkHome && president ? 'Network overview' : 'Home', '/app', 'home'),
		leader && !networkHome && item('team', 'Team overview', '/app/team', 'team'),
		!!activity && activity
	);

	const approvals = pick(
		can('approve_withdrawal') &&
			item('queue', 'Withdrawal queue', '/app/queue', 'queue', {
				...(tasks ? { count: tasks.withdrawals + tasks.payouts } : {}),
				accent: true
			}),
		can('approve_pocket_transfer') &&
			item('transfers', 'Pocket moves', '/app/transfers', 'transfers', {
				...(tasks ? { count: tasks.transfers } : {})
			}),
		can('review_financial_evidence') &&
			item('evidence', 'Evidence', '/app/evidence', 'evidence', {
				...(tasks ? { count: tasks.evidence } : {})
			}),
		reviewer &&
			item('identity', 'Identity reviews', '/app/reviews', 'identity', {
				...(tasks ? { count: tasks.identity } : {})
			}),
		can('reverse_transaction') && item('reversals', 'Reversals', '/app/reversals', 'reversals')
	);

	const money = pick(
		can('record_income') && item('income', 'Record income', '/app/income', 'income'),
		leader && item('wallets', 'Member wallets', '/app/wallets', 'wallets'),
		can('perform_currency_conversion') && item('convert', 'Convert', '/app/convert', 'convert'),
		reports && item('reports', 'Reports', '/app/reports', 'reports')
	);

	const people = pick(
		leads && item('members', 'Members', '/app/members', 'members'),
		leads && item('offices', 'Offices', '/app/offices', 'offices'),
		can('invite_members') && item('invitations', 'Invitations', '/app/invitations', 'invitations'),
		(president || can('manage_access_rules')) && item('access', 'Access', '/app/access', 'access')
	);

	// Pockets & split: the person's own pockets where they hold a wallet,
	// otherwise the network's split (the President Team edits it).
	const split = item('split', 'Pockets & split', '/app/split', 'split');
	const workspace = pick(
		settings &&
			item(
				'settings',
				'Settings',
				can('manage_team_settings') ? '/app/settings' : '/app/settings/backups',
				'settings',
				{ match: ['/app/settings'] }
			),
		billing && item('billing', 'Billing', '/app/billing', 'billing'),
		!wallet && split
	);

	const mine = pick(
		own('initiate_own_withdrawal') &&
			item('withdrawals', 'Withdrawals', '/app/withdrawals', 'withdraw'),
		own('manage_own_payout_accounts') &&
			item('payout', 'Payout accounts', '/app/payout-accounts', 'payout'),
		own('export_own_statement') &&
			item('statements', 'Statements', '/app/statements', 'statements'),
		wallet && split
	);

	const sections: NavSection[] = (
		[
			{ id: 'top', label: null, items: top },
			{ id: 'approvals', label: 'Approvals', items: approvals },
			{ id: 'money', label: 'Money', items: money },
			{ id: 'people', label: 'People', items: people },
			{ id: 'workspace', label: 'Workspace', items: workspace },
			{ id: 'wallet', label: 'My wallet', items: mine }
		] satisfies NavSection[]
	).filter((s) => s.items.length > 0);

	return {
		sections,
		tabs: tabSet(top, approvals, people, activity, own),
		networkHome,
		wallet,
		approvals
	};
}

function tabSet(
	top: readonly NavItem[],
	approvals: readonly NavItem[],
	people: readonly NavItem[],
	activity: NavItem | null,
	own: (key: string) => boolean
): NavTab[] {
	const tab = (item: NavItem, dot = false): NavTab => ({ ...item, dot });
	const home = top[0]!;
	const homeTab = tab({ ...home, label: 'Home' });
	const more = tab({
		id: 'more',
		label: 'More',
		href: '/app/more',
		icon: 'more',
		match: ['/app/more']
	});
	const withdraw =
		own('initiate_own_withdrawal') &&
		tab({
			id: 'withdraw',
			label: 'Withdraw',
			href: '/app/withdrawals',
			icon: 'withdraw',
			match: ['/app/withdrawals']
		});
	const waiting = approvals.reduce((sum, a) => sum + (a.count ?? 0), 0);
	const approvalsTab =
		approvals.length > 0 &&
		tab(
			{
				id: 'approvals',
				label: 'Approvals',
				href: approvals[0]!.href,
				icon: 'approvals',
				match: approvals.flatMap((a) => a.match)
			},
			waiting > 0
		);
	const peopleTab =
		people.length > 0 &&
		tab({
			id: 'people',
			label: 'People',
			href: people[0]!.href,
			icon: 'people',
			match: people.flatMap((p) => p.match)
		});
	const activityTab = activity && tab(activity);

	// Leaders (approvals or people): Home · Approvals · People · Activity · More,
	// with Withdraw added only where a slot is left (else it is on Home and More).
	// Members: Home · Activity · Withdraw · More.
	const leaderSet = !!approvalsTab || !!peopleTab;
	const middle = (
		leaderSet ? [approvalsTab, peopleTab, activityTab] : [activityTab, withdraw]
	).filter((t): t is NavTab => !!t);
	if (leaderSet && withdraw && middle.length < MAX_TABS - 2) middle.push(withdraw);
	return [homeTab, ...middle, more];
}

/** Is the item current for this path? */
export function isCurrent(item: Pick<NavItem, 'href' | 'match'>, path: string): boolean {
	if (item.href === '/app' && item.match.length === 1) return path === '/app';
	return item.match.some((prefix) => path === prefix || path.startsWith(`${prefix}/`));
}

/**
 * The current tab: the first that matches, else More for any other page of
 * the app (pages reached from More keep More lit).
 */
export function currentTab(tabs: readonly NavTab[], path: string): string | null {
	const found = tabs.find((t) => t.id !== 'more' && isCurrent(t, path));
	if (found) return found.id;
	return path.startsWith('/app') ? 'more' : null;
}
