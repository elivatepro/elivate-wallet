// Pure helpers for the org-management screens (Blueprint 07; Paper O/R, C11,
// F05): labels, the office tree order, permission groups, audit sentences and
// what to say when a command is refused. No I/O here.

import type { OfficeType, Role } from '#lib/contract/common.js';
import type { ApiFailure } from '#lib/contract/errors.js';
import type { AuditEvent, MembershipStatus, OfficeRow } from '#lib/contract/org-admin.js';
import { ROLE_LABELS } from '#lib/labels.js';

export const OFFICE_TYPE_LABELS: Record<OfficeType, string> = {
	world_team: 'World Team',
	director: 'Directorate',
	team_leader: 'Team office'
};

/** org.leader_role(): the role that leads an office of this kind. */
export const LEADER_ROLE: Record<OfficeType, Exclude<Role, 'member' | 'president_team_member'>> = {
	world_team: 'world_team_member',
	director: 'director',
	team_leader: 'team_leader'
};

/** Parent kinds an office may sit under (W-05: strictly higher, or none). */
export const PARENT_TYPES: Record<OfficeType, OfficeType[]> = {
	world_team: [],
	director: ['world_team'],
	team_leader: ['world_team', 'director']
};

export const STATUS_LABELS: Record<MembershipStatus, string> = {
	active: 'Active',
	suspended: 'Suspended',
	ended: 'Ended'
};

type Person = { uid: string; name: string | null } | null;

export const personName = (person: Person) => person?.name ?? person?.uid ?? 'Unknown';

/** "Adaeze Nwosu" → "AN"; a UID-only person → "EW". */
export function initials(person: Person): string {
	const name = person?.name?.trim();
	if (!name) return person?.uid.slice(0, 2) ?? '?';
	const parts = name.split(/\s+/).filter(Boolean);
	const first = parts[0]?.[0] ?? '';
	const last = parts.length > 1 ? (parts[parts.length - 1]?.[0] ?? '') : '';
	return (first + last).toUpperCase();
}

export interface TreeRow {
	readonly office: OfficeRow;
	readonly depth: number;
}

/**
 * Depth-first order (siblings by name): an office whose parent is not in the
 * list (above the workspace, or closed and filtered out) is shown at the top.
 */
export function officeTree(offices: ReadonlyArray<OfficeRow>): TreeRow[] {
	const ids = new Set(offices.map((o) => o.id));
	const children = new Map<string | null, OfficeRow[]>();
	for (const office of offices) {
		const parent =
			office.parentOfficeId && ids.has(office.parentOfficeId) ? office.parentOfficeId : null;
		const list = children.get(parent) ?? [];
		list.push(office);
		children.set(parent, list);
	}
	for (const list of children.values()) list.sort((a, b) => a.name.localeCompare(b.name));
	const rows: TreeRow[] = [];
	const seen = new Set<string>();
	const walk = (parent: string | null, depth: number) => {
		for (const office of children.get(parent) ?? []) {
			if (seen.has(office.id)) continue;
			seen.add(office.id);
			rows.push({ office, depth });
			walk(office.id, depth + 1);
		}
	};
	walk(null, 0);
	return rows;
}

/** "1 World Team · 2 directorates · 6 team offices" (zero kinds left out). */
export function officeCountLine(offices: ReadonlyArray<OfficeRow>): string {
	const count = (type: OfficeType) => offices.filter((o) => o.type === type).length;
	const parts: string[] = [];
	const w = count('world_team');
	const d = count('director');
	const t = count('team_leader');
	if (w) parts.push(`${w} World Team${w === 1 ? '' : 's'}`);
	if (d) parts.push(`${d} ${d === 1 ? 'directorate' : 'directorates'}`);
	if (t) parts.push(`${t} team ${t === 1 ? 'office' : 'offices'}`);
	return parts.join(' · ');
}

/** "Directorate · 3 team offices" under an office name. */
export function officeSubline(office: OfficeRow, all: ReadonlyArray<OfficeRow>): string {
	const kids = all.filter((o) => o.parentOfficeId === office.id && o.status === 'active');
	if (kids.length === 0) return OFFICE_TYPE_LABELS[office.type];
	const teams = kids.filter((o) => o.type === 'team_leader').length;
	const dirs = kids.filter((o) => o.type === 'director').length;
	const bits: string[] = [];
	if (dirs) bits.push(`${dirs} ${dirs === 1 ? 'directorate' : 'directorates'}`);
	if (teams) bits.push(`${teams} team ${teams === 1 ? 'office' : 'offices'}`);
	return `${OFFICE_TYPE_LABELS[office.type]} · ${bits.join(' · ')}`;
}

// ── Role permissions (Paper R01) ─────────────────────────────────────────

export const PERMISSION_LABELS: Record<string, string> = {
	view_own_wallet: 'View own wallet',
	view_own_financials: 'View own financials',
	export_own_statement: 'Export own statement',
	initiate_own_withdrawal: 'Withdraw from own wallet',
	manage_own_payout_accounts: 'Manage own payout accounts',
	transfer_between_own_pockets: 'Move between own pockets',
	view_managed_wallets: 'View managed wallets',
	record_income: 'Record income',
	approve_withdrawal: 'Approve withdrawals',
	withdraw_on_behalf: 'Withdraw on behalf',
	transfer_between_pockets_on_behalf: 'Move pockets on behalf',
	approve_pocket_transfer: 'Approve pocket moves',
	perform_currency_conversion: 'Convert currency',
	manual_credit_debit_adjustment: 'Credit / debit adjustment',
	record_returned_funds: 'Record returned funds',
	view_scoped_financial_reports: 'View financial reports',
	export_scoped_reports: 'Export reports',
	invite_members: 'Invite members',
	manage_members: 'Manage members',
	move_membership: 'Move membership',
	suspend_membership: 'Suspend membership',
	end_membership: 'End membership',
	manage_access_rules: 'Manage access rules',
	manage_subscription: 'Manage subscription',
	manage_role_permissions: 'Manage role permissions',
	manage_security_settings: 'Manage security settings',
	configure_adjustment_evidence_requirement: 'Adjustment evidence rule',
	reverse_transaction: 'Reverse transactions',
	transfer_presidency: 'Transfer presidency',
	deactivate_tenant: 'Deactivate workspace',
	manage_allocation: 'Pockets & split',
	review_financial_evidence: 'Review financial evidence'
};

export const permissionLabel = (key: string) => PERMISSION_LABELS[key] ?? key.replaceAll('_', ' ');

export const PERMISSION_GROUPS: ReadonlyArray<{ title: string; keys: readonly string[] }> = [
	{
		title: 'Own wallet',
		keys: [
			'view_own_wallet',
			'view_own_financials',
			'export_own_statement',
			'initiate_own_withdrawal',
			'manage_own_payout_accounts',
			'transfer_between_own_pockets'
		]
	},
	{
		title: 'Money',
		keys: [
			'view_managed_wallets',
			'record_income',
			'approve_withdrawal',
			'withdraw_on_behalf',
			'transfer_between_pockets_on_behalf',
			'approve_pocket_transfer',
			'perform_currency_conversion',
			'manual_credit_debit_adjustment',
			'record_returned_funds'
		]
	},
	{ title: 'Reports', keys: ['view_scoped_financial_reports', 'export_scoped_reports'] },
	{
		title: 'People',
		keys: [
			'invite_members',
			'manage_members',
			'move_membership',
			'suspend_membership',
			'end_membership',
			'manage_access_rules'
		]
	},
	{
		title: 'Governance',
		keys: [
			'manage_subscription',
			'manage_role_permissions',
			'manage_security_settings',
			'configure_adjustment_evidence_requirement',
			'reverse_transaction',
			'transfer_presidency',
			'deactivate_tenant',
			'manage_allocation'
		]
	}
];

/** Grouped keys; anything the catalogue adds later lands in Governance. */
export function groupPermissions(keys: ReadonlyArray<string>) {
	const known = new Set(PERMISSION_GROUPS.flatMap((g) => g.keys));
	const extra = keys.filter((k) => !known.has(k) && k !== 'review_financial_evidence');
	return PERMISSION_GROUPS.map((group) => ({
		title: group.title,
		keys: [
			...group.keys.filter((k) => keys.includes(k)),
			...(group.title === 'Governance' ? extra : [])
		]
	})).filter((g) => g.keys.length > 0);
}

export const PERMISSION_SCOPE: Record<string, string> = {
	self: 'Self',
	office: 'Office',
	tenant: 'Workspace',
	assignment: 'Assigned'
};

export const ROLE_ORDER: readonly Role[] = [
	'member',
	'team_leader',
	'director',
	'world_team_member',
	'president_team_member'
];

/** Column headings in the matrix ("World Team" / "President"). */
export const ROLE_COLUMN: Record<Role, string> = {
	...ROLE_LABELS,
	president_team_member: 'President'
};

// ── Audit log (Paper F05) ────────────────────────────────────────────────

const AUDIT_SENTENCES: Record<string, string> = {
	'tenant.created': 'Started the network',
	'tenant.activated': 'Activated the network',
	'office.created': 'Created an office',
	'office.renamed': 'Renamed an office',
	'office.placed': 'Moved an office in the tree',
	'office.closed': 'Closed an office',
	'office.leader_added': 'Added an office leader',
	'office.leader_replaced': 'Replaced an office leader',
	'membership.added': 'Added a member',
	'membership.moved': 'Moved a membership',
	'membership.suspended': 'Suspended a membership',
	'membership.active': 'Reactivated a membership',
	'membership.ended': 'Ended a membership',
	'membership.role_changed': 'Changed a member’s role',
	'president.added': 'Added a President Team Member',
	'role_permission.changed': 'Changed a role permission',
	'access.assigned': 'Gave cross-access',
	'access.revoked': 'Revoked cross-access',
	'reviewer.assigned': 'Assigned an evidence reviewer',
	'reviewer.ended': 'Removed an evidence reviewer',
	'invitation.created': 'Invited someone',
	'invitation.revoked': 'Revoked an invitation',
	'invitation.reissued': 'Resent an invitation',
	'invitation.accepted': 'Accepted an invitation',
	'allocation.changed': 'Changed the pockets & split'
};

const AREA_LABELS: Record<string, string> = {
	tenant: 'Network',
	office: 'Office',
	membership: 'Membership',
	president: 'President Team',
	role_permission: 'Roles',
	access: 'Access',
	reviewer: 'Reviewers',
	invitation: 'Invitations',
	allocation: 'Pockets'
};

export function auditSentence(event: Pick<AuditEvent, 'action' | 'after'>): string {
	const known = AUDIT_SENTENCES[event.action];
	if (event.action === 'role_permission.changed' && isRecord(event.after)) {
		return `${event.after.allowed ? 'Allowed' : 'Removed'} a role permission`;
	}
	if (known) return known;
	const [area = '', verb = ''] = event.action.split('.');
	return `${AREA_LABELS[area] ?? area.replaceAll('_', ' ')} · ${verb.replaceAll('_', ' ')}`;
}

export const auditArea = (action: string) => {
	const area = action.split('.')[0] ?? '';
	return AREA_LABELS[area] ?? area.replaceAll('_', ' ');
};

/** Safe before/after values flattened to "key: value" pairs for the detail pane. */
export function auditFacts(value: unknown): Array<[string, string]> {
	if (!isRecord(value)) return [];
	return Object.entries(value)
		.filter(([, v]) => v === null || ['string', 'number', 'boolean'].includes(typeof v))
		.map(([k, v]) => [k, v === null ? '—' : String(v)]);
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
	typeof value === 'object' && value !== null && !Array.isArray(value);

// ── Refusals ─────────────────────────────────────────────────────────────

export type Outcome =
	| { readonly kind: 'pin'; readonly text: string }
	| { readonly kind: 'locked' }
	| { readonly kind: 'message'; readonly text: string };

const CONFLICTS: Record<string, string> = {
	has_child_offices: 'Move or close the offices under it first.',
	office_not_empty: 'Move or end its members first. Leaders end with the office.',
	office_closed: 'That office is closed.',
	membership_not_active: 'That membership isn’t active.',
	membership_ended: 'That membership has already ended.',
	president_membership: 'President Team memberships are managed separately.',
	not_a_current_leader: 'That person no longer leads this office.',
	subject_not_member: 'That person isn’t an active member of this network.',
	already_reviewer: 'That person is already a reviewer.',
	account_not_active: 'That account isn’t active.'
};

/** What to tell the leader when an org command did not go through. */
export function describeOrgFailure(failure: ApiFailure | undefined): Outcome {
	if (failure?._tag !== 'BackendError') {
		return { kind: 'message', text: 'We couldn’t confirm that. Try again.' };
	}
	const details = failure.details;
	switch (failure.code) {
		case 'step_up_required':
			return { kind: 'pin', text: 'Enter your PIN to confirm.' };
		case 'pin_incorrect': {
			const left = Number(details.attemptsRemaining);
			return {
				kind: 'pin',
				text: Number.isInteger(left)
					? `That PIN is incorrect. ${left} ${left === 1 ? 'try' : 'tries'} left.`
					: 'That PIN is incorrect.'
			};
		}
		case 'pin_locked':
			return { kind: 'locked' };
		case 'conflict':
			return {
				kind: 'message',
				text:
					CONFLICTS[String(details.reason)] ?? 'That changed in the meantime. Reload and try again.'
			};
		case 'last_leader':
			return {
				kind: 'message',
				text: 'An office keeps at least one leader. Replace them instead.'
			};
		case 'last_president':
			return { kind: 'message', text: 'The network keeps at least one President Team Member.' };
		case 'membership_exists':
			return { kind: 'message', text: 'That person already holds this role here.' };
		case 'role_office_mismatch':
			return { kind: 'message', text: 'That role doesn’t fit this office.' };
		case 'hierarchy_invalid':
			return { kind: 'message', text: 'An office sits under a higher kind of office.' };
		case 'scope_exceeds_authority':
			return { kind: 'message', text: 'That’s outside what you manage.' };
		case 'permission_not_grantable':
			return { kind: 'message', text: 'That permission can’t be given this way.' };
		case 'self_target_forbidden':
			return { kind: 'message', text: 'You can’t do that to your own membership.' };
		case 'authorization_denied':
			return { kind: 'message', text: 'You don’t have permission to do that here.' };
		case 'not_found':
			return { kind: 'message', text: 'We couldn’t find that. Check the UID or reload.' };
		case 'idempotency_conflict':
			return { kind: 'message', text: 'Something changed. Try again.' };
		case 'validation_error':
			if (details.field === 'reason') {
				return { kind: 'message', text: 'Give a reason (3–500 characters).' };
			}
			return { kind: 'message', text: failure.message };
		default:
			return { kind: 'message', text: failure.message };
	}
}

/** Whether the next try must reuse the same idempotency key (outcome unknown, W-00). */
export const keepsKey = (failure: ApiFailure | undefined) =>
	!failure || failure._tag !== 'BackendError' || failure.code === 'internal_error';
