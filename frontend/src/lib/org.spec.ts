import { describe, expect, it } from 'vitest';
import { BackendError } from '#lib/contract/errors.js';
import type { OfficeRow } from '#lib/contract/org-admin.js';
import {
	auditFacts,
	auditSentence,
	describeOrgFailure,
	fundsRow,
	groupPermissions,
	initials,
	keepsKey,
	officeCountLine,
	officeSubline,
	officeTree,
	PERMISSION_GROUPS,
	searchPermissions
} from './org';

const office = (
	id: string,
	name: string,
	type: OfficeRow['type'],
	parent: string | null
): OfficeRow => ({
	id,
	name,
	type,
	status: 'active',
	parentOfficeId: parent,
	leaderCount: 1,
	memberCount: 1,
	childCount: 0,
	leaders: []
});

const backend = (code: BackendError['code'], details: Record<string, unknown> = {}) =>
	new BackendError({
		status: 409,
		code,
		message: 'msg',
		retryable: false,
		details,
		requestId: 'r'
	});

describe('officeTree', () => {
	it('orders depth-first with siblings by name', () => {
		const rows = officeTree([
			office('t2', 'Ibadan', 'team_leader', 'd'),
			office('w', 'World', 'world_team', null),
			office('d', 'South-West', 'director', 'w'),
			office('t1', 'Abeokuta', 'team_leader', 'd')
		]);
		expect(rows.map((r) => [r.office.id, r.depth])).toEqual([
			['w', 0],
			['d', 1],
			['t1', 2],
			['t2', 2]
		]);
	});

	it('puts an office whose parent is not visible at the top', () => {
		const rows = officeTree([office('t', 'Lagos', 'team_leader', 'hidden')]);
		expect(rows).toEqual([{ office: expect.objectContaining({ id: 't' }), depth: 0 }]);
	});
});

describe('labels', () => {
	it('counts kinds without zeroes', () => {
		const all = [
			office('w', 'W', 'world_team', null),
			office('d', 'D', 'director', 'w'),
			office('t', 'T', 'team_leader', 'd'),
			office('u', 'U', 'team_leader', 'd')
		];
		expect(officeCountLine(all)).toBe('1 World Team · 1 directorate · 2 team offices');
		expect(officeSubline(all[1]!, all)).toBe('Directorate · 2 team offices');
		expect(officeSubline(all[2]!, all)).toBe('Team office');
	});

	it('makes initials from names or UIDs', () => {
		expect(initials({ uid: 'EW-48213', name: 'Adaeze  Nwosu' })).toBe('AN');
		expect(initials({ uid: 'EW-48213', name: null })).toBe('EW');
		expect(initials(null)).toBe('?');
	});

	it('groups permissions and keeps unknown keys', () => {
		const groups = groupPermissions(['record_income', 'review_financial_evidence', 'future_key']);
		expect(groups).toEqual([
			{ title: 'Money', keys: ['record_income'] },
			{ title: 'Governance', keys: ['future_key'] }
		]);
	});

	it('writes audit sentences and safe facts', () => {
		expect(auditSentence({ action: 'office.closed', after: null })).toBe('Closed an office');
		expect(auditSentence({ action: 'role_permission.changed', after: { allowed: false } })).toBe(
			'Removed a role permission'
		);
		expect(auditSentence({ action: 'widget.paid', after: null })).toBe('widget · paid');
		expect(auditFacts({ status: 'closed', nested: { a: 1 }, n: null })).toEqual([
			['status', 'closed'],
			['n', '—']
		]);
	});
});

describe('describeOrgFailure', () => {
	it('asks for the PIN and maps conflicts', () => {
		expect(describeOrgFailure(backend('step_up_required')).kind).toBe('pin');
		expect(describeOrgFailure(backend('conflict', { reason: 'office_not_empty' }))).toEqual({
			kind: 'message',
			text: 'Move or end its active members first. Leaders and suspended members are archived.'
		});
		expect(describeOrgFailure(backend('last_leader')).kind).toBe('message');
		expect(describeOrgFailure(undefined).kind).toBe('message');
	});

	it('keeps the key only when the outcome is unknown', () => {
		expect(keepsKey(undefined)).toBe(true);
		expect(keepsKey(backend('internal_error'))).toBe(true);
		expect(keepsKey(backend('conflict'))).toBe(false);
	});
});

describe('permission labels (slice 21)', () => {
	it('labels every catalogued permission, the Blueprint 17 keys included', async () => {
		const { permissionLabel } = await import('./org.js');
		expect(permissionLabel('manage_team_settings')).toBe('Team settings & branding');
		expect(permissionLabel('request_restore')).toBe('Request a restore');
	});
});

describe('funds not managed (Blueprint 22)', () => {
	const actions = { suspend: false, move: false, end: false, changeRole: false };
	const director = { role: 'director' as const, actions: { ...actions, funds: true } };

	it('offers the switch to the President Team on a director with an empty wallet', () => {
		expect(fundsRow({ ...director, fundsNotManaged: false, fundsBlocked: null })).toEqual({
			notManaged: false,
			blocked: false,
			action: 'set'
		});
		expect(fundsRow({ ...director, fundsNotManaged: true, fundsBlocked: null })?.action).toBe(
			'clear'
		);
	});

	it('shows why it is blocked while the wallet holds money', () => {
		expect(
			fundsRow({ ...director, fundsNotManaged: false, fundsBlocked: 'wallet_not_empty' })
		).toEqual({ notManaged: false, blocked: true, action: null });
	});

	it('shows the state to others only once switched, and never for other roles', () => {
		const leader = { role: 'director' as const, actions };
		expect(fundsRow({ ...leader, fundsNotManaged: false })).toBeNull();
		expect(fundsRow({ ...leader, fundsNotManaged: true })).toEqual({
			notManaged: true,
			blocked: false,
			action: null
		});
		expect(fundsRow({ role: 'member', actions: { ...actions, funds: true } })).toBeNull();
	});

	it('explains a refused switch', () => {
		const refused = (reason: string) =>
			describeOrgFailure({
				_tag: 'BackendError',
				status: 409,
				code: 'conflict',
				message: '',
				retryable: false,
				details: { reason },
				requestId: null
			} as never);
		expect(refused('wallet_not_empty').kind).toBe('message');
		expect(refused('wallet_not_empty')).toMatchObject({ text: expect.stringContaining('money') });
	});
});

describe('searchPermissions (Blueprint 37)', () => {
	const all = PERMISSION_GROUPS;
	it('keeps matching permissions in their groups', () => {
		expect(searchPermissions(all, 'withdraw')).toEqual([
			{ title: 'Own wallet', total: 6, keys: ['initiate_own_withdrawal'] },
			{ title: 'Money', total: 9, keys: ['approve_withdrawal', 'withdraw_on_behalf'] }
		]);
	});
	it('needs every word, in any order and case', () => {
		expect(searchPermissions(all, '  BEHALF withdraw ').flatMap((g) => g.keys)).toEqual([
			'withdraw_on_behalf'
		]);
	});
	it('matches the label as shown', () => {
		expect(searchPermissions(all, 'approve identity').flatMap((g) => g.keys)).toEqual([
			'review_identity'
		]);
	});
	it('an empty query keeps everything; no match keeps nothing', () => {
		expect(searchPermissions(all, '').flatMap((g) => g.keys)).toEqual(all.flatMap((g) => g.keys));
		expect(searchPermissions(all, 'zzz')).toEqual([]);
	});
});
