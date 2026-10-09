import { describe, expect, it } from 'vitest';
import { BackendError } from '#lib/contract/errors.js';
import type { OfficeRow } from '#lib/contract/org-admin.js';
import {
	auditFacts,
	auditSentence,
	describeOrgFailure,
	groupPermissions,
	initials,
	keepsKey,
	officeCountLine,
	officeSubline,
	officeTree
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
		expect(auditSentence({ action: 'billing.paid', after: null })).toBe('billing · paid');
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
