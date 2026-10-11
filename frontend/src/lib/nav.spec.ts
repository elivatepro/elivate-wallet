import { describe, expect, it } from 'vitest';
import { countTasks, currentTab, isCurrent, MAX_TABS, navModel, type NavInput } from '#lib/nav.js';

// A-03 defaults per role (Blueprint 25 derives tabs and sections from them).
const OWN = [
	'view_own_wallet',
	'view_own_financials',
	'export_own_statement',
	'initiate_own_withdrawal',
	'manage_own_payout_accounts',
	'transfer_between_own_pockets'
];
const LEAD = [
	'view_managed_wallets',
	'record_income',
	'approve_withdrawal',
	'transfer_between_pockets_on_behalf',
	'approve_pocket_transfer',
	'perform_currency_conversion',
	'record_returned_funds',
	'view_scoped_financial_reports',
	'export_scoped_reports',
	'invite_members',
	'manage_members'
];
const MEMBER = OWN;
const TEAM_LEADER = [...OWN, ...LEAD];
const DIRECTOR = [...OWN, ...LEAD, 'manage_access_rules'];
const WORLD_TEAM = [
	...DIRECTOR,
	'withdraw_on_behalf',
	'manual_credit_debit_adjustment',
	'move_membership',
	'suspend_membership',
	'end_membership',
	'request_restore'
];
const PRESIDENT = [
	...LEAD,
	'withdraw_on_behalf',
	'manual_credit_debit_adjustment',
	'move_membership',
	'suspend_membership',
	'end_membership',
	'manage_access_rules',
	'manage_subscription',
	'manage_role_permissions',
	'manage_security_settings',
	'reverse_transaction',
	'manage_allocation',
	'manage_team_settings',
	'request_restore',
	'review_financial_evidence'
];
/** Blueprint 22: a director whose funds are not managed keeps every director authority. */
const DIRECTOR_NO_FUNDS = [...LEAD, 'manage_access_rules'];

const model = (input: Partial<NavInput> & Pick<NavInput, 'permissions' | 'role'>) =>
	navModel({ billingOwner: false, tasks: null, ...input });
const tabs = (m: ReturnType<typeof navModel>) => m.tabs.map((t) => t.label);
const section = (m: ReturnType<typeof navModel>, id: string) =>
	m.sections.find((s) => s.id === id)?.items.map((i) => i.label) ?? null;
const hrefs = (m: ReturnType<typeof navModel>) =>
	m.sections.flatMap((s) => s.items.map((i) => i.href));

describe('tab sets (owner decision 1)', () => {
	it('member: Home · Activity · Withdraw · More', () => {
		expect(tabs(model({ permissions: MEMBER, role: 'member' }))).toEqual([
			'Home',
			'Activity',
			'Withdraw',
			'More'
		]);
	});

	it('President Team: Home · Approvals · People · Activity · More', () => {
		const m = model({ permissions: PRESIDENT, role: 'president_team_member' });
		expect(tabs(m)).toEqual(['Home', 'Approvals', 'People', 'Activity', 'More']);
		// No own wallet: Activity is the network's audit log.
		expect(m.tabs.find((t) => t.id === 'activity')?.href).toBe('/app/audit');
		expect(m.tabs.find((t) => t.id === 'approvals')?.href).toBe('/app/queue');
		expect(m.tabs.find((t) => t.id === 'people')?.href).toBe('/app/members');
	});

	it('leaders with a wallet: the leader set; Activity is their own', () => {
		for (const [role, permissions] of [
			['team_leader', TEAM_LEADER],
			['director', DIRECTOR],
			['world_team_member', WORLD_TEAM]
		] as const) {
			const m = model({ permissions, role });
			expect(tabs(m), role).toEqual(['Home', 'Approvals', 'People', 'Activity', 'More']);
			expect(m.tabs.find((t) => t.id === 'activity')?.href, role).toBe('/app/activity');
		}
	});

	it('a director whose funds are not managed: no Activity, no Withdraw', () => {
		const m = model({ permissions: DIRECTOR_NO_FUNDS, role: 'director' });
		expect(tabs(m)).toEqual(['Home', 'Approvals', 'People', 'More']);
		expect(m.networkHome).toBe(true);
		expect(m.wallet).toBe(false);
	});

	it('a leader with a free slot gets Withdraw before More', () => {
		const peopleOnly = [...OWN, 'invite_members'];
		expect(tabs(model({ permissions: peopleOnly, role: 'team_leader' }))).toEqual([
			'Home',
			'People',
			'Activity',
			'Withdraw',
			'More'
		]);
	});

	it('never more than five tabs; Home first and More last', () => {
		for (const [role, permissions] of [
			['member', MEMBER],
			['team_leader', TEAM_LEADER],
			['world_team_member', WORLD_TEAM],
			['president_team_member', PRESIDENT],
			['director', DIRECTOR_NO_FUNDS]
		] as const) {
			const t = tabs(model({ permissions, role }));
			expect(t.length, role).toBeLessThanOrEqual(MAX_TABS);
			expect(t[0], role).toBe('Home');
			expect(t.at(-1), role).toBe('More');
		}
	});

	it('a dot on Approvals while something waits', () => {
		const idle = model({
			permissions: PRESIDENT,
			role: 'president_team_member',
			tasks: { withdrawals: 0, payouts: 0, transfers: 0, evidence: 0, identity: 0 }
		});
		expect(idle.tabs.find((t) => t.id === 'approvals')?.dot).toBe(false);
		const busy = model({
			permissions: PRESIDENT,
			role: 'president_team_member',
			tasks: { withdrawals: 0, payouts: 0, transfers: 0, evidence: 0, identity: 2 }
		});
		expect(busy.tabs.find((t) => t.id === 'approvals')?.dot).toBe(true);
	});

	it('offline: a network Home stays a network Home (saved kind, else the President Team)', () => {
		expect(model({ permissions: null, role: 'president_team_member' }).networkHome).toBe(true);
		expect(model({ permissions: null, role: 'director', networkHomeHint: true }).networkHome).toBe(
			true
		);
		expect(model({ permissions: null, role: 'director' }).networkHome).toBe(false);
		expect(model({ permissions: null, role: 'member', networkHomeHint: false }).networkHome).toBe(
			false
		);
	});

	it('offline (no permissions yet): the role stands in for own money', () => {
		expect(tabs(model({ permissions: null, role: 'member' }))).toEqual([
			'Home',
			'Activity',
			'Withdraw',
			'More'
		]);
		const president = model({ permissions: null, role: 'president_team_member' });
		expect(hrefs(president)).not.toContain('/app/withdrawals');
		expect(hrefs(president)).not.toContain('/app/payout-accounts');
	});
});

describe('sidebar sections (owner decision 2)', () => {
	it('President Team: NV03, with no wallet items', () => {
		const m = model({
			permissions: PRESIDENT,
			role: 'president_team_member',
			billingOwner: true,
			tasks: { withdrawals: 3, payouts: 1, transfers: 0, evidence: 1, identity: 2 }
		});
		expect(m.sections.map((s) => s.label)).toEqual([
			null,
			'Approvals',
			'Money',
			'People',
			'Workspace'
		]);
		expect(section(m, 'top')).toEqual(['Network overview', 'Activity']);
		expect(section(m, 'approvals')).toEqual([
			'Withdrawal queue',
			'Pocket moves',
			'Evidence',
			'Identity reviews',
			'Reversals'
		]);
		expect(section(m, 'money')).toEqual(['Record income', 'Member wallets', 'Convert', 'Reports']);
		expect(section(m, 'people')).toEqual(['Members', 'Offices', 'Invitations', 'Access']);
		expect(section(m, 'workspace')).toEqual(['Settings', 'Billing', 'Pockets & split']);
		expect(section(m, 'wallet')).toBeNull();
		for (const own of ['/app/withdrawals', '/app/payout-accounts', '/app/statements']) {
			expect(hrefs(m)).not.toContain(own);
		}
		const counts = Object.fromEntries(
			m.sections.flatMap((s) => s.items).map((i) => [i.id, i.count ?? null])
		);
		expect(counts).toMatchObject({ queue: 4, transfers: 0, evidence: 1, identity: 2 });
		expect(m.networkHome).toBe(true);
	});

	it('member: Home and Activity, then My wallet only', () => {
		const m = model({ permissions: MEMBER, role: 'member' });
		expect(m.sections.map((s) => s.id)).toEqual(['top', 'wallet']);
		expect(section(m, 'top')).toEqual(['Home', 'Activity']);
		expect(section(m, 'wallet')).toEqual([
			'Withdrawals',
			'Payout accounts',
			'Statements',
			'Pockets & split'
		]);
		expect(m.networkHome).toBe(false);
	});

	it('team leader: Team overview on top, My wallet last', () => {
		const m = model({ permissions: TEAM_LEADER, role: 'team_leader' });
		expect(section(m, 'top')).toEqual(['Home', 'Team overview', 'Activity']);
		expect(section(m, 'approvals')).toEqual(['Withdrawal queue', 'Pocket moves']);
		expect(section(m, 'people')).toEqual(['Members', 'Offices', 'Invitations']);
		expect(section(m, 'workspace')).toBeNull();
		expect(m.sections.at(-1)?.id).toBe('wallet');
	});

	it('World Team: the vault under Settings and identity reviews', () => {
		const m = model({ permissions: WORLD_TEAM, role: 'world_team_member' });
		expect(section(m, 'approvals')).toContain('Identity reviews');
		const settings = m.sections.flatMap((s) => s.items).find((i) => i.id === 'settings');
		expect(settings?.href).toBe('/app/settings/backups');
		expect(isCurrent(settings!, '/app/settings/backups/restore')).toBe(true);
	});

	it('Billing for the Billing Owner without manage_subscription', () => {
		expect(
			section(model({ permissions: MEMBER, role: 'member', billingOwner: true }), 'workspace')
		).toEqual(['Billing']);
	});
});

describe('current item', () => {
	const m = model({ permissions: PRESIDENT, role: 'president_team_member' });

	it('Home only on /app itself; others by prefix', () => {
		const home = m.tabs[0]!;
		expect(isCurrent(home, '/app')).toBe(true);
		expect(isCurrent(home, '/app/team')).toBe(false);
		expect(isCurrent({ href: '/app/queue', match: ['/app/queue'] }, '/app/queue/returns')).toBe(
			true
		);
		expect(isCurrent({ href: '/app/queue', match: ['/app/queue'] }, '/app/queuex')).toBe(false);
	});

	it('the tab follows every page of its group; anything else lights More', () => {
		expect(currentTab(m.tabs, '/app')).toBe('home');
		expect(currentTab(m.tabs, '/app/evidence')).toBe('approvals');
		expect(currentTab(m.tabs, '/app/offices/abc')).toBe('people');
		expect(currentTab(m.tabs, '/app/audit')).toBe('activity');
		expect(currentTab(m.tabs, '/app/reports')).toBe('more');
		expect(currentTab(m.tabs, '/app/more')).toBe('more');
	});
});

describe('bell tasks', () => {
	it('counts open tasks by what they ask for', () => {
		expect(
			countTasks([
				{ kind: 'task.withdrawal_approve' },
				{ kind: 'task.withdrawal_approve' },
				{ kind: 'task.payout_record' },
				{ kind: 'task.payout_fix' },
				{ kind: 'task.transfer_approve' },
				{ kind: 'task.payout_review' },
				{ kind: 'task.entry_review' },
				{ kind: 'task.nin_review' },
				{ kind: 'income_posted' }
			])
		).toEqual({ withdrawals: 2, payouts: 2, transfers: 1, evidence: 2, identity: 1 });
	});
});
