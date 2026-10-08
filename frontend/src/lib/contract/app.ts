// Contract of the app server's own same-origin JSON endpoints (decision 36).
// The browser decodes these with Effect Schema exactly like the server decodes
// the Edge Functions.

import { Schema } from 'effect';
import { ActivityItem, Allocation, AllocationVersion, WalletNetwork } from './ledger';
import { IdempotencyKey, InvitationPage, InvitationStatus } from './invitations';
import { OfficeType, PIN_PATTERN, Role, Uuid } from './common';
import { ACCOUNT_NUMBER_PATTERN, Bank, PayoutAccount } from './payout';
import { Capabilities, Workspace } from './org';
import { SecurityState } from './security';

/** GET /api/session: who is signed in, the gate, and the selected workspace. */
export const SessionView = Schema.Struct({
	state: SecurityState,
	workspace: Schema.NullOr(Workspace),
	capabilities: Schema.NullOr(Capabilities),
	/** Own name and photo flag (Blueprint 06); null when unavailable. Never cached on device. */
	profile: Schema.NullOr(
		Schema.Struct({ name: Schema.NullOr(Schema.String), hasPhoto: Schema.Boolean })
	)
});
export type SessionView = typeof SessionView.Type;

/**
 * GET /api/home: the selected network's slice of the person's own wallet
 * (W-07), its latest activity and the split percentages. `network` is null
 * when the person has no wallet here (e.g. President Team only).
 */
export const HomeView = Schema.Struct({
	network: Schema.NullOr(WalletNetwork),
	activity: Schema.Array(ActivityItem),
	split: Schema.NullOr(
		Schema.Array(Schema.Struct({ pocketId: Schema.String, percent: Schema.String }))
	)
});
export type HomeView = typeof HomeView.Type;

/** GET /api/split: the network's live split and its history (L01). */
export const SplitView = Schema.Struct({
	allocation: Allocation,
	versions: Schema.Array(AllocationVersion),
	canEdit: Schema.Boolean
});
export type SplitView = typeof SplitView.Type;

/** The optional PIN typed in a confirm dialog (step-up, A-05). */
export const OptionalPin = Schema.optionalKey(Schema.String.check(Schema.isPattern(PIN_PATTERN)));

/** PUT /api/split (L02): reason + PIN dialog. */
export const SplitCommand = Schema.Struct({
	expectedVersion: Schema.Int,
	pockets: Schema.Array(
		Schema.Struct({
			pocketId: Schema.NullOr(Uuid),
			name: Schema.String,
			basisPoints: Schema.Int
		})
	),
	reason: Schema.String,
	pin: OptionalPin,
	idempotencyKey: IdempotencyKey
});
export type SplitCommand = typeof SplitCommand.Type;

/** POST /api/nin-reviews/:id (Blueprint 06): approve or reject with reason + PIN. */
export const ReviewDecisionCommand = Schema.Struct({
	decision: Schema.Literals(['approve', 'reject']),
	reason: Schema.String,
	pin: OptionalPin,
	idempotencyKey: IdempotencyKey
});
export type ReviewDecisionCommand = typeof ReviewDecisionCommand.Type;

/** GET /api/payout-accounts (Y02): the person's own accounts, primary first. */
export const PayoutAccountsView = Schema.Struct({ items: Schema.Array(PayoutAccount) });
export type PayoutAccountsView = typeof PayoutAccountsView.Type;

/** GET /api/payout-accounts/banks: the Paystack bank list. */
export const BanksView = Schema.Struct({ banks: Schema.Array(Bank) });
export type BanksView = typeof BanksView.Type;

/** POST /api/payout-accounts/lookup: name lookup (step-up). Not confirmation. */
export const PayoutLookupCommand = Schema.Struct({
	bankCode: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(20)),
	accountNumber: Schema.String.check(Schema.isPattern(ACCOUNT_NUMBER_PATTERN)),
	/** Replace (W-17, Blueprint 10): the active account the new one replaces. */
	replacesPayoutAccountId: Schema.optionalKey(Uuid),
	pin: OptionalPin,
	idempotencyKey: IdempotencyKey
});
export type PayoutLookupCommand = typeof PayoutLookupCommand.Type;

/** POST /api/payout-accounts: explicit save of a resolved lookup (step-up). */
export const PayoutConfirmCommand = Schema.Struct({
	lookupId: Uuid,
	/** Required (3–500 characters) only and always for a replacement (W-17 Q8). */
	reason: Schema.optionalKey(Schema.String),
	pin: OptionalPin,
	idempotencyKey: IdempotencyKey
});
export type PayoutConfirmCommand = typeof PayoutConfirmCommand.Type;

/** POST /api/payout-accounts/:id/primary (PIN only). */
export const PayoutPrimaryCommand = Schema.Struct({
	pin: OptionalPin,
	idempotencyKey: IdempotencyKey
});
export type PayoutPrimaryCommand = typeof PayoutPrimaryCommand.Type;

/** POST /api/payout-accounts/:id/deactivate (reason + PIN). */
export const PayoutRemoveCommand = Schema.Struct({
	reason: Schema.String,
	pin: OptionalPin,
	idempotencyKey: IdempotencyKey
});
export type PayoutRemoveCommand = typeof PayoutRemoveCommand.Type;

/** An office the leader can invite into (I01 "Invite a member"). */
export const InviteOffice = Schema.Struct({
	officeId: Uuid,
	name: Schema.String,
	type: OfficeType
});
export type InviteOffice = typeof InviteOffice.Type;

/**
 * GET /api/invitations (I01): one page of the leader's invitations. `offices`
 * comes with the first page only (null on later pages, or when the offices
 * read is unavailable, e.g. the network is not active).
 */
export const InvitationsView = Schema.Struct({
	page: InvitationPage,
	offices: Schema.NullOr(Schema.Array(InviteOffice))
});
export type InvitationsView = typeof InvitationsView.Type;

/** Query of GET /api/invitations; the cursor is the backend's opaque one. */
export const InvitationsQuery = Schema.Struct({
	status: Schema.optionalKey(InvitationStatus),
	cursor: Schema.optionalKey(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(500)))
});

/** POST /api/invitations: create, with reason + PIN for leader roles. */
export const CreateInvitationCommand = Schema.Struct({
	officeId: Uuid,
	role: Role,
	email: Schema.String,
	reason: Schema.optionalKey(Schema.String),
	pin: OptionalPin,
	idempotencyKey: IdempotencyKey
});
export type CreateInvitationCommand = typeof CreateInvitationCommand.Type;

/** POST /api/invitations/:id/reissue (I01 "Resend link"); PIN only when asked. */
export const ReissueCommand = Schema.Struct({ pin: OptionalPin, idempotencyKey: IdempotencyKey });
export type ReissueCommand = typeof ReissueCommand.Type;

/** POST /api/invitations/:id/revoke (I02): reason, PIN only when asked. */
export const RevokeCommand = Schema.Struct({
	reason: Schema.String,
	pin: OptionalPin,
	idempotencyKey: IdempotencyKey
});
export type RevokeCommand = typeof RevokeCommand.Type;

export const AppRoutes = {
	split: { method: 'GET', path: '/api/split' },
	saveSplit: { method: 'PUT', path: '/api/split' },
	session: { method: 'GET', path: '/api/session' },
	home: { method: 'GET', path: '/api/home' },
	payoutAccounts: { method: 'GET', path: '/api/payout-accounts' },
	payoutBanks: { method: 'GET', path: '/api/payout-accounts/banks' },
	payoutLookup: { method: 'POST', path: '/api/payout-accounts/lookup' },
	payoutConfirm: { method: 'POST', path: '/api/payout-accounts' },
	invitations: { method: 'GET', path: '/api/invitations' },
	createInvitation: { method: 'POST', path: '/api/invitations' },
	reissueInvitation: (id: string) =>
		({ method: 'POST', path: `/api/invitations/${id}/reissue` }) as const,
	revokeInvitation: (id: string) =>
		({ method: 'POST', path: `/api/invitations/${id}/revoke` }) as const
} as const;

/** Same-origin per-account commands; the id is the account's UUID, never its number. */
export const payoutPrimaryPath = (payoutAccountId: string) =>
	`/api/payout-accounts/${payoutAccountId}/primary`;
export const payoutRemovePath = (payoutAccountId: string) =>
	`/api/payout-accounts/${payoutAccountId}/deactivate`;
