// Platform Admin app (Blueprint 18, W-23/W-24): routes on the `admin` Edge
// Function and the shapes they return. Every value here is already masked or
// allowlisted by the database: no PINs, NINs, full account numbers, IPs or
// evidence ever arrive.

import { Schema } from 'effect';
import {
	AccountStatus,
	IDEMPOTENCY_KEY_PATTERN,
	IsoDateTime,
	OfficeType,
	Person,
	Role,
	TenantStatus,
	Uid,
	Uuid
} from './common';

const IdempotencyKey = Schema.String.check(Schema.isPattern(IDEMPOTENCY_KEY_PATTERN));
const Json = Schema.Unknown;

export const AdminRoutes = {
	me: { method: 'GET', path: '/me' },
	overview: { method: 'GET', path: '/overview' },
	search: { method: 'GET', path: '/search' },
	tenants: { method: 'GET', path: '/tenants' },
	tenant: (id: string) => ({ method: 'GET', path: `/tenants/${id}` }) as const,
	allocationVersions: (id: string) =>
		({ method: 'GET', path: `/tenants/${id}/allocation-versions` }) as const,
	activate: (id: string) => ({ method: 'POST', path: `/tenants/${id}/activate` }) as const,
	accounts: { method: 'GET', path: '/accounts' },
	account: (uid: string) => ({ method: 'GET', path: `/accounts/${uid}` }) as const,
	accountStatus: (uid: string) => ({ method: 'POST', path: `/accounts/${uid}/status` }) as const,
	switches: { method: 'GET', path: '/switches' },
	setSwitch: { method: 'POST', path: '/switches' },
	audit: { method: 'GET', path: '/audit' },
	admins: { method: 'GET', path: '/admins' },
	grantAdmin: { method: 'POST', path: '/admins/grant' },
	revokeAdmin: { method: 'POST', path: '/admins/revoke' },
	restores: { method: 'GET', path: '/restores' },
	restore: (id: string) => ({ method: 'GET', path: `/restores/${id}` }) as const,
	advanceRestore: (id: string) => ({ method: 'POST', path: `/restores/${id}/advance` }) as const,
	restoreSource: (id: string) => ({ method: 'POST', path: `/restores/${id}/source` }) as const,
	restoreRows: (id: string) => ({ method: 'POST', path: `/restores/${id}/rows` }) as const,
	restoreValidated: (id: string) =>
		({ method: 'POST', path: `/restores/${id}/validated` }) as const,
	outbox: { method: 'GET', path: '/outbox' },
	requeue: (id: string) => ({ method: 'POST', path: `/outbox/${id}/requeue` }) as const,
	ninReviews: { method: 'GET', path: '/nin/reviews' },
	decideNin: (id: string) => ({ method: 'POST', path: `/nin/reviews/${id}/decide` }) as const
} as const;

// ── Shared pieces ─────────────────────────────────────────────────────────

/** The eight kill switches (owner answer Q4), in display order. */
export const SWITCH_KEYS = [
	'withdrawals',
	'transfers',
	'payouts',
	'conversion',
	'income',
	'adjustments',
	'reversals',
	'returned_funds'
] as const;
export const SwitchKey = Schema.Literals(SWITCH_KEYS);
export type SwitchKey = typeof SwitchKey.Type;

export const SWITCH_LABELS: Readonly<Record<SwitchKey, { name: string; detail: string }>> = {
	withdrawals: { name: 'Withdrawals', detail: 'New withdrawal requests and approvals' },
	transfers: { name: 'Transfers', detail: 'New pocket transfers' },
	payouts: { name: 'Payout recording', detail: 'Recording new payouts and corrections' },
	conversion: { name: 'Conversion', detail: 'New currency conversions' },
	income: { name: 'Income', detail: 'New income recordings' },
	adjustments: { name: 'Adjustments', detail: 'New adjustments' },
	reversals: { name: 'Reversals', detail: 'New reversals' },
	returned_funds: { name: 'Returned funds', detail: 'Recording returned funds' }
};

export const NETWORK_STATES = [
	'active',
	'trial',
	'paused',
	'pending_payment',
	'deactivated'
] as const;
export const NetworkState = Schema.Literals(NETWORK_STATES);
export type NetworkState = typeof NetworkState.Type;

export const NETWORK_STATE_LABELS: Readonly<Record<NetworkState, string>> = {
	active: 'Active',
	trial: 'Trial',
	paused: 'Paused',
	pending_payment: 'Waiting for payment',
	deactivated: 'Deactivated'
};

export const AUDIT_GROUPS = ['controls', 'accounts', 'money', 'backups', 'network'] as const;
export const AuditGroup = Schema.Literals(AUDIT_GROUPS);
export type AuditGroup = typeof AuditGroup.Type;

export const Plan = Schema.Struct({
	key: Schema.String,
	name: Schema.String,
	seatCap: Schema.NullOr(Schema.Int),
	price: Schema.optional(Schema.String),
	currency: Schema.optional(Schema.String)
});

export const NetworkRow = Schema.Struct({
	tenantId: Uuid,
	name: Schema.String,
	shortName: Schema.String,
	state: NetworkState,
	kind: Schema.NullOr(Schema.Literals(['trial', 'paid', 'complimentary', 'development'])),
	plan: Schema.NullOr(Plan),
	periodEnd: Schema.NullOr(IsoDateTime),
	seats: Schema.Struct({ used: Schema.Int, cap: Schema.NullOr(Schema.Int) }),
	officeCount: Schema.Int,
	presidents: Schema.Array(Person),
	founder: Person,
	createdAt: IsoDateTime
});
export type NetworkRow = typeof NetworkRow.Type;

export const Switch = Schema.Struct({
	key: SwitchKey,
	tenantId: Schema.NullOr(Uuid),
	stopped: Schema.Boolean,
	reason: Schema.NullOr(Schema.String),
	changedBy: Person,
	changedAt: Schema.NullOr(IsoDateTime)
});
export type Switch = typeof Switch.Type;

export const AccountRow = Schema.Struct({
	uid: Uid,
	name: Schema.NullOr(Schema.String),
	email: Schema.NullOr(Schema.String),
	status: AccountStatus,
	networks: Schema.Array(Schema.String),
	lastSignInAt: Schema.NullOr(IsoDateTime),
	pin: Schema.Literals(['set', 'locked', 'not_set']),
	isAdmin: Schema.Boolean,
	createdAt: IsoDateTime
});
export type AccountRow = typeof AccountRow.Type;

const Page = <S extends Schema.Top>(item: S) =>
	Schema.Struct({
		items: Schema.Array(item),
		nextCursor: Schema.NullOr(Schema.String),
		counts: Schema.Record(Schema.String, Schema.Int)
	});

// ── Responses ─────────────────────────────────────────────────────────────

export const AdminMe = Schema.Struct({
	uid: Uid,
	name: Schema.NullOr(Schema.String),
	isAdmin: Schema.Boolean,
	stepUpExpiresAt: Schema.NullOr(IsoDateTime)
});
export type AdminMe = typeof AdminMe.Type;

export const Overview = Schema.Struct({
	networks: Schema.Struct({
		total: Schema.Int,
		byState: Schema.Record(Schema.String, Schema.Int)
	}),
	accounts: Schema.Struct({
		total: Schema.Int,
		byStatus: Schema.Record(Schema.String, Schema.Int)
	}),
	recentNetworks: Schema.Array(NetworkRow),
	switches: Schema.Array(Switch),
	networkStops: Schema.Int,
	openRestores: Schema.Array(
		Schema.Struct({
			restoreId: Uuid,
			reference: Schema.String,
			status: Schema.String,
			network: Schema.NullOr(Schema.String),
			createdAt: IsoDateTime
		})
	),
	failedEmails: Schema.Int,
	ninReviews: Schema.Int
});
export type Overview = typeof Overview.Type;

export const NetworkPage = Page(NetworkRow);
export type NetworkPage = typeof NetworkPage.Type;

export const NetworkDetail = Schema.Struct({
	...NetworkRow.fields,
	status: TenantStatus,
	activatedAt: Schema.NullOr(IsoDateTime),
	activationSource: Schema.NullOr(Schema.String),
	subscription: Schema.NullOr(
		Schema.Struct({
			status: Schema.String,
			kind: Schema.String,
			periodStart: Schema.NullOr(IsoDateTime),
			periodEnd: Schema.NullOr(IsoDateTime),
			pausedAt: Schema.NullOr(IsoDateTime),
			autoRenew: Schema.Boolean,
			owner: Json
		})
	),
	organization: Schema.Struct({
		offices: Schema.Int,
		byType: Schema.Record(Schema.String, Schema.Int),
		memberships: Schema.Int,
		people: Schema.Int
	}),
	stopped: Schema.Array(SwitchKey),
	openRestore: Schema.NullOr(
		Schema.Struct({ restoreId: Uuid, reference: Schema.String, status: Schema.String })
	)
});
export type NetworkDetail = typeof NetworkDetail.Type;

export const AccountPage = Page(AccountRow);
export type AccountPage = typeof AccountPage.Type;

export const AccountDetail = Schema.Struct({
	...AccountRow.fields,
	phone: Schema.NullOr(Schema.String),
	memberships: Schema.Array(
		Schema.Struct({
			membershipId: Uuid,
			network: Schema.NullOr(Schema.String),
			tenantId: Uuid,
			office: Schema.NullOr(Schema.String),
			role: Role,
			status: Schema.Literals(['active', 'suspended', 'ended']),
			startedAt: IsoDateTime,
			endedAt: Schema.NullOr(IsoDateTime)
		})
	),
	statusHistory: Schema.Array(
		Schema.Struct({
			from: AccountStatus,
			to: AccountStatus,
			reason: Schema.String,
			actor: Person,
			at: IsoDateTime
		})
	),
	security: Schema.Struct({
		pin: Schema.Literals(['set', 'locked', 'not_set']),
		activeSessions: Schema.Int,
		lastSignInAt: Schema.NullOr(IsoDateTime),
		unusualSignIns7d: Schema.Int
	})
});
export type AccountDetail = typeof AccountDetail.Type;

export const SearchResults = Schema.Struct({
	query: Schema.String,
	accounts: Schema.Array(Schema.Struct({ ...AccountRow.fields, matchedOn: Schema.String })),
	bankAccounts: Schema.Array(
		Schema.Struct({
			owner: Person,
			bankName: Schema.String,
			last4: Schema.String,
			status: Schema.String
		})
	),
	references: Schema.Array(
		Schema.Struct({
			reference: Schema.String,
			kind: Schema.String,
			status: Schema.String,
			network: Schema.NullOr(Schema.String),
			tenantId: Uuid,
			owner: Person
		})
	),
	networks: Schema.Array(NetworkRow),
	offices: Schema.Array(
		Schema.Struct({
			officeId: Uuid,
			name: Schema.String,
			type: OfficeType,
			status: Schema.String,
			network: Schema.NullOr(Schema.String),
			tenantId: Uuid
		})
	)
});
export type SearchResults = typeof SearchResults.Type;

export const Switches = Schema.Struct({
	platform: Schema.Array(Switch),
	networks: Schema.Array(
		Schema.Struct({ ...Switch.fields, network: Schema.optional(Schema.NullOr(Schema.String)) })
	)
});
export type Switches = typeof Switches.Type;

export const SwitchChanged = Schema.Struct({
	switch: Switch,
	changed: Schema.Boolean,
	replayed: Schema.Boolean
});

export const AuditEvent = Schema.Struct({
	eventId: Schema.String,
	at: IsoDateTime,
	actor: Person,
	actorIsAdmin: Schema.Boolean,
	action: Schema.String,
	group: AuditGroup,
	network: Schema.NullOr(Schema.String),
	tenantId: Schema.NullOr(Uuid),
	targetType: Schema.NullOr(Schema.String),
	targetId: Schema.NullOr(Schema.String),
	target: Person,
	reason: Schema.NullOr(Schema.String),
	before: Json,
	after: Json,
	requestId: Schema.NullOr(Schema.String)
});
export type AuditEvent = typeof AuditEvent.Type;

export const AuditPage = Schema.Struct({
	items: Schema.Array(AuditEvent),
	nextCursor: Schema.NullOr(Schema.String)
});
export type AuditPage = typeof AuditPage.Type;

export const AdminRow = Schema.Struct({
	uid: Uid,
	name: Schema.NullOr(Schema.String),
	grantedBy: Person,
	grantedAt: IsoDateTime,
	lastSignInAt: Schema.NullOr(IsoDateTime),
	isYou: Schema.Boolean
});
export const Admins = Schema.Array(AdminRow);
export type AdminRow = typeof AdminRow.Type;

export const RestoreStatus = Schema.Literals([
	'requested',
	'validating',
	'in_review',
	'restoring',
	'completed',
	'rejected',
	'cancelled',
	'failed'
]);
export type RestoreStatus = typeof RestoreStatus.Type;

export const RestoreRow = Schema.Struct({
	restoreId: Uuid,
	reference: Schema.String,
	status: RestoreStatus,
	statusReason: Schema.NullOr(Schema.String),
	reason: Schema.String,
	backup: Schema.Struct({
		backupId: Uuid,
		readyAt: Schema.NullOr(IsoDateTime),
		byteSize: Schema.NullOr(Schema.Number),
		sha256: Schema.NullOr(Schema.String)
	}),
	requestedBy: Person,
	createdAt: IsoDateTime,
	updatedAt: IsoDateTime,
	network: Schema.NullOr(Schema.String),
	tenantId: Uuid,
	operator: Person,
	finishedAt: Schema.NullOr(IsoDateTime)
});
export type RestoreRow = typeof RestoreRow.Type;
export const Restores = Schema.Array(RestoreRow);

export const Difference = Schema.Struct({
	section: Schema.String,
	archive: Schema.Int,
	now: Schema.Int,
	added: Schema.Int,
	removed: Schema.Int,
	changed: Schema.Int,
	onRestore: Schema.Literals(['manual', 'kept'])
});
export type Difference = typeof Difference.Type;

export const RestoreDetail = Schema.Struct({
	...RestoreRow.fields,
	validation: Schema.NullOr(
		Schema.Struct({
			ok: Schema.Boolean,
			failReason: Schema.NullOr(Schema.String),
			files: Schema.Int,
			rows: Schema.Int,
			checkedAt: IsoDateTime,
			checkedBy: Person
		})
	),
	differences: Schema.NullOr(Schema.Array(Difference)),
	events: Schema.Array(
		Schema.Struct({
			from: Schema.NullOr(Schema.String),
			to: Schema.String,
			reason: Schema.NullOr(Schema.String),
			actor: Person,
			at: IsoDateTime
		})
	)
});
export type RestoreDetail = typeof RestoreDetail.Type;

export const RestoreSource = Schema.Struct({
	restoreId: Uuid,
	objectKey: Schema.String.check(
		Schema.isPattern(/^backups\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9]+\.zip$/)
	),
	byteSize: Schema.Number,
	sha256: Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/)),
	recordCount: Schema.Int,
	files: Schema.Array(
		Schema.Struct({
			section: Schema.String,
			rows: Schema.Int,
			sha256: Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/))
		})
	),
	counts: Schema.Record(Schema.String, Schema.Int)
});
export type RestoreSource = typeof RestoreSource.Type;

export const RestoreChanged = Schema.Struct({ restore: Json });

export const DeadLetter = Schema.Struct({
	eventId: Uuid,
	template: Schema.String,
	tenantId: Schema.NullOr(Uuid),
	cycle: Schema.Int,
	attempts: Schema.Int,
	lastErrorCode: Schema.NullOr(Schema.String),
	occurredAt: IsoDateTime,
	deadLetteredAt: IsoDateTime
});
export type DeadLetter = typeof DeadLetter.Type;
export const DeadLetters = Schema.Array(DeadLetter);

export const NinReview = Schema.Struct({
	reviewId: Uuid,
	tenantId: Uuid,
	requester: Schema.Struct({ uid: Uid, name: Schema.NullOr(Schema.String) }),
	officeName: Schema.NullOr(Schema.String),
	role: Role,
	ninLast4: Schema.String,
	legalName: Schema.Struct({
		given: Schema.String,
		middle: Schema.NullOr(Schema.Array(Schema.String)),
		surname: Schema.String
	}),
	requestedAt: IsoDateTime
});
export type NinReview = typeof NinReview.Type;
export const NinReviews = Schema.Array(NinReview);

/** Commands answer with free-form objects; pages reload after a change. */
export const CommandResult = Schema.Record(Schema.String, Schema.Unknown);

// ── Requests ──────────────────────────────────────────────────────────────

export const Reason = Schema.String.check(Schema.isMinLength(3), Schema.isMaxLength(500));

export const SetSwitchRequest = Schema.Struct({
	key: SwitchKey,
	tenantId: Schema.NullOr(Uuid),
	stopped: Schema.Boolean,
	reason: Reason,
	idempotencyKey: IdempotencyKey
});

export const AccountStatusRequest = Schema.Struct({
	status: AccountStatus,
	reason: Reason,
	idempotencyKey: IdempotencyKey
});

export const ActivateRequest = Schema.Struct({
	until: Schema.NullOr(Schema.String.check(Schema.isPattern(/^\d{4}-\d{2}-\d{2}$/))),
	reason: Reason,
	idempotencyKey: IdempotencyKey
});

export const AdminChangeRequest = Schema.Struct({
	targetUid: Uid,
	reason: Reason,
	idempotencyKey: IdempotencyKey
});

export const AdvanceRestoreRequest = Schema.Struct({
	status: Schema.Literals(['validating', 'restoring', 'completed', 'rejected', 'failed']),
	reason: Reason,
	idempotencyKey: IdempotencyKey
});

export const ReasonRequest = Schema.Struct({ reason: Reason, idempotencyKey: IdempotencyKey });

export const NinDecisionRequest = Schema.Struct({
	decision: Schema.Literals(['approve', 'reject']),
	reason: Reason,
	idempotencyKey: IdempotencyKey
});
