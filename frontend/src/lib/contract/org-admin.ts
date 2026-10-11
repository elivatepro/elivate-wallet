// Org management contract (Blueprint 07): the `org` Edge Function's office,
// member, role-policy, access, reviewer and audit routes, the ledger's office
// totals read, and the app server's own /api/org/* endpoints. Derived from
// backend/supabase/functions/org/handler.ts and the api.* JSON builders.

import { Schema } from 'effect';
import { IdempotencyKey, InviteEmail, Reason } from './invitations';
import { Currency, Money } from './ledger';
import { IsoDateTime, OfficeType, PIN_PATTERN, Person, Role, Uid, Uuid } from './common';

const Pin = Schema.optionalKey(Schema.String.check(Schema.isPattern(PIN_PATTERN)));
const Name = Schema.String.check(Schema.isMinLength(2), Schema.isMaxLength(100));
const Page = <S extends Schema.Top>(item: S) =>
	Schema.Struct({ items: Schema.Array(item), nextCursor: Schema.NullOr(Schema.String) });

export const MembershipStatus = Schema.Literals(['active', 'suspended', 'ended']);
export type MembershipStatus = typeof MembershipStatus.Type;
export const OfficeStatus = Schema.Literals(['active', 'closed']);

// ── Edge responses ───────────────────────────────────────────────────────

/** GET /offices row (api.list_offices). */
export const OfficeRow = Schema.Struct({
	id: Uuid,
	name: Schema.String,
	type: OfficeType,
	status: OfficeStatus,
	parentOfficeId: Schema.NullOr(Uuid),
	leaderCount: Schema.Int,
	memberCount: Schema.Int,
	childCount: Schema.Int,
	leaders: Schema.Array(Person)
});
export type OfficeRow = typeof OfficeRow.Type;
export const OfficeRows = Page(OfficeRow);

export const Leader = Schema.Struct({ membershipId: Uuid, person: Person, startedAt: IsoDateTime });
export type Leader = typeof Leader.Type;

const OfficeRef = Schema.Struct({ id: Uuid, name: Schema.String, type: OfficeType });

/** Blueprint 27: an open leader invitation (waiting office, or a pending replacement). */
export const PendingLeader = Schema.Struct({
	invitationId: Uuid,
	email: Schema.String,
	expiresAt: IsoDateTime,
	/** The leader this invitation replaces when accepted; null for a new leader. */
	replaces: Person
});
export type PendingLeader = typeof PendingLeader.Type;

/** GET /people (api.find_people): the person picker's matches. */
export const FoundPerson = Schema.Struct({
	uid: Uid,
	name: Schema.NullOr(Schema.String),
	inNetwork: Schema.Boolean,
	role: Schema.NullOr(Role),
	officeName: Schema.NullOr(Schema.String)
});
export type FoundPerson = typeof FoundPerson.Type;
export const FoundPeople = Schema.Struct({
	items: Schema.Array(FoundPerson),
	/** The query was a full email address that no account uses. */
	noAccount: Schema.Boolean
});
export type FoundPeople = typeof FoundPeople.Type;

/** GET /offices/:id (api.office_detail). */
export const OfficeDetail = Schema.Struct({
	id: Uuid,
	name: Schema.String,
	type: OfficeType,
	status: OfficeStatus,
	parentOfficeId: Schema.NullOr(Uuid),
	createdAt: IsoDateTime,
	leaders: Schema.Array(Leader),
	path: Schema.Array(OfficeRef),
	children: Schema.Array(OfficeRef),
	memberCount: Schema.Int,
	ownMemberCount: Schema.Int,
	pendingInvitations: Schema.Int,
	/**
	 * Blueprint 27: open leader invitations; null when the viewer may not invite
	 * there (not shown, not "none"). Optional: copies saved before it have none.
	 */
	pendingLeaders: Schema.optional(Schema.NullOr(Schema.Array(PendingLeader))),
	/** Set once the office is closed (from the network audit log). */
	closure: Schema.NullOr(
		Schema.Struct({ at: IsoDateTime, reason: Schema.NullOr(Schema.String), by: Person })
	),
	canManage: Schema.Boolean,
	canLeadAssign: Schema.Boolean
});
export type OfficeDetail = typeof OfficeDetail.Type;

/** GET /ledger/offices/:id/totals (api.office_totals), subtree per currency. */
export const OfficeTotals = Schema.Struct({
	officeId: Uuid,
	currencies: Schema.Array(
		Schema.Struct({ currency: Currency, posted: Money, reserved: Money, available: Money })
	),
	distinctMembers: Schema.Int
});
export type OfficeTotals = typeof OfficeTotals.Type;

/** GET /members row (api.list_members). */
export const MemberRow = Schema.Struct({
	membershipId: Uuid,
	person: Person,
	emailMasked: Schema.NullOr(Schema.String),
	role: Role,
	status: MembershipStatus,
	officeId: Schema.NullOr(Uuid),
	officeName: Schema.NullOr(Schema.String),
	isPrimary: Schema.Boolean,
	startedAt: IsoDateTime,
	endedAt: Schema.NullOr(IsoDateTime)
});
export type MemberRow = typeof MemberRow.Type;
export const MemberRows = Page(MemberRow);

/** GET /memberships/:id (api.member_detail). */
export const MemberDetail = Schema.Struct({
	membershipId: Uuid,
	person: Person,
	emailMasked: Schema.NullOr(Schema.String),
	role: Role,
	status: MembershipStatus,
	isPrimary: Schema.Boolean,
	startedAt: IsoDateTime,
	endedAt: Schema.NullOr(IsoDateTime),
	office: Schema.NullOr(
		Schema.Struct({ id: Uuid, name: Schema.String, type: OfficeType, status: OfficeStatus })
	),
	officeLeaders: Schema.Array(Leader),
	isSelf: Schema.Boolean,
	walletId: Schema.NullOr(Uuid),
	/** Blueprint 22: the director's funds are not managed (no wallet use). */
	fundsNotManaged: Schema.optional(Schema.Boolean),
	/** Why the switch can't be turned on now (President Team view only). */
	fundsBlocked: Schema.optional(Schema.NullOr(Schema.Literal('wallet_not_empty'))),
	memberships: Schema.Array(
		Schema.Struct({
			membershipId: Uuid,
			role: Role,
			status: MembershipStatus,
			isPrimary: Schema.Boolean,
			officeId: Schema.NullOr(Uuid),
			officeName: Schema.NullOr(Schema.String)
		})
	),
	history: Schema.Array(
		Schema.Struct({
			action: Schema.String,
			fromStatus: Schema.NullOr(MembershipStatus),
			toStatus: MembershipStatus,
			at: IsoDateTime,
			actor: Person
		})
	),
	actions: Schema.Struct({
		suspend: Schema.Boolean,
		move: Schema.Boolean,
		end: Schema.Boolean,
		changeRole: Schema.Boolean,
		/** Blueprint 22: President Team, a director's funds switch. */
		funds: Schema.optional(Schema.Boolean)
	})
});
export type MemberDetail = typeof MemberDetail.Type;

/** GET /ledger/wallets/:walletId: only the per-currency totals are used here. */
export const ManagedWalletTotals = Schema.Struct({
	walletId: Uuid,
	networks: Schema.Array(
		Schema.Struct({
			tenantId: Uuid,
			currencies: Schema.Array(
				Schema.Struct({ currency: Currency, posted: Money, reserved: Money, available: Money })
			)
		})
	)
});

export const RolePermission = Schema.Struct({
	permission: Schema.String,
	role: Role,
	allowed: Schema.Boolean,
	editable: Schema.Boolean
});
export type RolePermission = typeof RolePermission.Type;
export const RolePermissions = Schema.Array(RolePermission);

export const AccessRule = Schema.Struct({
	permission: Schema.String,
	effect: Schema.Literals(['allow', 'deny']),
	scopeType: Schema.Literals(['tenant', 'office_subtree', 'member']),
	scopeOfficeId: Schema.NullOr(Uuid),
	scopeOfficeName: Schema.NullOr(Schema.String),
	scopePerson: Person,
	startsAt: IsoDateTime,
	expiresAt: Schema.NullOr(IsoDateTime)
});
export const AccessAssignment = Schema.Struct({
	id: Uuid,
	subject: Person,
	createdBy: Person,
	reason: Schema.String,
	createdAt: IsoDateTime,
	revokedAt: Schema.NullOr(IsoDateTime),
	revokeReason: Schema.NullOr(Schema.String),
	rules: Schema.Array(AccessRule)
});
export type AccessAssignment = typeof AccessAssignment.Type;
export const AccessAssignments = Page(AccessAssignment);

export const Reviewer = Schema.Struct({
	assignmentId: Uuid,
	membershipId: Uuid,
	person: Person,
	role: Role,
	officeName: Schema.NullOr(Schema.String),
	reason: Schema.String,
	assignedAt: IsoDateTime,
	assignedBy: Person
});
export type Reviewer = typeof Reviewer.Type;
export const Reviewers = Schema.Array(Reviewer);

export const AuditEvent = Schema.Struct({
	id: Schema.Union([Schema.Int, Schema.String]),
	at: IsoDateTime,
	actor: Person,
	action: Schema.String,
	targetType: Schema.NullOr(Schema.String),
	targetId: Schema.NullOr(Schema.String),
	reason: Schema.NullOr(Schema.String),
	before: Schema.NullOr(Schema.Unknown),
	after: Schema.NullOr(Schema.Unknown)
});
export type AuditEvent = typeof AuditEvent.Type;
export const AuditEvents = Page(AuditEvent);

/** Every org command returns a JSON object; the UI reloads the read afterwards. */
export const CommandResult = Schema.Record(Schema.String, Schema.Unknown);

export const OrgAdminRoutes = {
	offices: { method: 'GET', path: '/offices' },
	createOffice: { method: 'POST', path: '/offices' },
	office: (id: string) => ({ method: 'GET', path: `/offices/${id}` }) as const,
	renameOffice: (id: string) => ({ method: 'PATCH', path: `/offices/${id}` }) as const,
	closeOffice: (id: string) => ({ method: 'POST', path: `/offices/${id}/close` }) as const,
	placeOffice: (id: string) => ({ method: 'POST', path: `/offices/${id}/place` }) as const,
	addLeader: (id: string) => ({ method: 'POST', path: `/offices/${id}/leaders` }) as const,
	replaceLeader: (id: string) =>
		({ method: 'POST', path: `/offices/${id}/leaders/replace` }) as const,
	members: { method: 'GET', path: '/members' },
	member: (id: string) => ({ method: 'GET', path: `/memberships/${id}` }) as const,
	membershipAction: (id: string, action: MembershipAction) =>
		({ method: 'POST', path: `/memberships/${id}/${action}` }) as const,
	presidents: { method: 'POST', path: '/presidents' },
	removePresident: (id: string) => ({ method: 'DELETE', path: `/presidents/${id}` }) as const,
	rolePermissions: { method: 'GET', path: '/role-permissions' },
	setRolePermission: { method: 'PUT', path: '/role-permissions' },
	access: { method: 'GET', path: '/access' },
	createAccess: { method: 'POST', path: '/access' },
	revokeAccess: (id: string) => ({ method: 'POST', path: `/access/${id}/revoke` }) as const,
	reviewers: { method: 'GET', path: '/reviewers' },
	assignReviewer: { method: 'POST', path: '/reviewers' },
	endReviewer: (id: string) => ({ method: 'DELETE', path: `/reviewers/${id}` }) as const,
	audit: { method: 'GET', path: '/audit' },
	officeTotals: (id: string) => ({ method: 'GET', path: `/offices/${id}/totals` }) as const,
	wallet: (id: string) => ({ method: 'GET', path: `/wallets/${id}` }) as const,
	// Blueprint 27: the picker's search (org) and leaders invited by email
	// (the `invitations` function, which issues the link).
	people: { method: 'GET', path: '/people' },
	inviteOffice: { method: 'POST', path: '/office' },
	inviteLeader: { method: 'POST', path: '/' }
} as const;

export type MembershipAction = 'suspend' | 'reactivate' | 'end' | 'move' | 'role' | 'funds';

// ── App server endpoints (/api/org/*) ────────────────────────────────────

/** GET /api/org/offices: every visible office plus subtree money per office. */
export const OfficesView = Schema.Struct({
	offices: Schema.Array(OfficeRow),
	/** officeId → totals; missing when the read was unavailable or not permitted. */
	totals: Schema.Record(Uuid, OfficeTotals),
	canCreate: Schema.Boolean,
	truncated: Schema.Boolean
});
export type OfficesView = typeof OfficesView.Type;

/** GET /api/org/offices/:id */
export const OfficeView = Schema.Struct({
	office: OfficeDetail,
	totals: Schema.NullOr(OfficeTotals),
	members: Schema.NullOr(MemberRows),
	isPresident: Schema.Boolean,
	/** Where the President Team may place this office (N04): strictly higher kinds. */
	parents: Schema.Array(
		Schema.Struct({
			id: Uuid,
			name: Schema.String,
			type: OfficeType,
			parentName: Schema.NullOr(Schema.String)
		})
	)
});
export type OfficeView = typeof OfficeView.Type;

/** GET /api/org/members/:id */
export const MemberView = Schema.Struct({
	member: MemberDetail,
	balances: Schema.NullOr(
		Schema.Array(Schema.Struct({ currency: Currency, posted: Money, available: Money }))
	),
	/** Opens Member wallets (Blueprint 08, Q05) when the leader may see the wallet. */
	walletId: Schema.optionalKey(Schema.NullOr(Uuid)),
	offices: Schema.Array(Schema.Struct({ id: Uuid, name: Schema.String, type: OfficeType }))
});
export type MemberView = typeof MemberView.Type;

/** GET /api/org/access */
export const AccessView = Schema.Struct({
	rolePermissions: Schema.NullOr(RolePermissions),
	assignments: Schema.NullOr(AccessAssignments),
	reviewers: Schema.NullOr(Reviewers),
	canEditRoles: Schema.Boolean,
	canManageAccess: Schema.Boolean,
	isPresident: Schema.Boolean,
	offices: Schema.Array(Schema.Struct({ id: Uuid, name: Schema.String, type: OfficeType }))
});
export type AccessView = typeof AccessView.Type;

const Command = <F extends Schema.Struct.Fields>(fields: F) =>
	Schema.Struct({ ...fields, pin: Pin, idempotencyKey: IdempotencyKey });

export const CreateOfficeCommand = Command({
	type: OfficeType,
	name: Name,
	parentOfficeId: Schema.NullOr(Uuid),
	leaderUids: Schema.Array(Uid).check(Schema.isMinLength(1), Schema.isMaxLength(20))
});
/** Blueprint 27: a new office whose leader is invited by email (reason filled in). */
export const CreateOfficeInviteCommand = Command({
	type: OfficeType,
	name: Name,
	parentOfficeId: Schema.NullOr(Uuid),
	email: InviteEmail
});
/** Blueprint 27: add a leader by email, or replace one (on accept). */
export const InviteLeaderCommand = Command({
	/** The office's leader role (the backend refuses a mismatch). */
	role: Schema.Literals(['team_leader', 'director', 'world_team_member']),
	email: InviteEmail,
	reason: Reason,
	replacesMembershipId: Schema.optionalKey(Uuid)
});
export const RenameOfficeCommand = Command({ name: Name });
export const ReasonCommand = Command({ reason: Reason });
export const PlaceCommand = Command({ parentOfficeId: Schema.NullOr(Uuid), reason: Reason });
export const AddLeaderCommand = Command({ leaderUid: Uid, reason: Reason });
export const ReplaceLeaderCommand = Command({
	outgoingMembershipId: Uuid,
	incomingUid: Uid,
	reason: Reason
});
export const MoveCommand = Command({ toOfficeId: Uuid, reason: Reason });
/** Blueprint 22: "funds not managed" on (true) or off for a director. */
export const FundsCommand = Command({ notManaged: Schema.Boolean, reason: Reason });
export const RoleCommand = Command({
	role: Schema.Literals(['member', 'team_leader', 'director', 'world_team_member']),
	reason: Reason
});
export const RoleChangesCommand = Schema.Struct({
	changes: Schema.Array(
		Schema.Struct({
			role: Role,
			permission: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(60)),
			allowed: Schema.Boolean,
			idempotencyKey: IdempotencyKey
		})
	).check(Schema.isMinLength(1), Schema.isMaxLength(40)),
	reason: Reason,
	pin: Pin
});
export const CreateAccessCommand = Command({
	subjectUid: Uid,
	rules: Schema.Array(
		Schema.Struct({
			permission: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(60)),
			effect: Schema.Literals(['allow', 'deny']),
			scopeType: Schema.Literals(['tenant', 'office_subtree', 'member']),
			scopeOfficeId: Schema.optionalKey(Uuid),
			scopeUid: Schema.optionalKey(Uid),
			startsAt: Schema.optionalKey(IsoDateTime),
			expiresAt: Schema.optionalKey(IsoDateTime)
		})
	).check(Schema.isMinLength(1), Schema.isMaxLength(50)),
	reason: Reason
});
export const AssignReviewerCommand = Command({ membershipId: Uuid, reason: Reason });
export const AddPresidentCommand = Command({ memberUid: Uid, reason: Reason });

export const AppOrgRoutes = {
	offices: '/api/org/offices',
	office: (id: string) => `/api/org/offices/${id}`,
	officeClose: (id: string) => `/api/org/offices/${id}/close`,
	officePlace: (id: string) => `/api/org/offices/${id}/place`,
	officeLeaders: (id: string) => `/api/org/offices/${id}/leaders`,
	officeLeaderReplace: (id: string) => `/api/org/offices/${id}/leaders/replace`,
	officeLeaderInvite: (id: string) => `/api/org/offices/${id}/leaders/invite`,
	officesInvite: '/api/org/offices/invite',
	people: '/api/org/people',
	members: '/api/org/members',
	member: (id: string) => `/api/org/members/${id}`,
	memberAction: (id: string, action: MembershipAction) => `/api/org/members/${id}/${action}`,
	access: '/api/org/access',
	rolePermissions: '/api/org/role-permissions',
	accessRevoke: (id: string) => `/api/org/access/${id}/revoke`,
	reviewers: '/api/org/reviewers',
	reviewerEnd: (id: string) => `/api/org/reviewers/${id}/end`,
	presidents: '/api/org/presidents',
	presidentRemove: (id: string) => `/api/org/presidents/${id}/remove`,
	audit: '/api/org/audit'
} as const;
