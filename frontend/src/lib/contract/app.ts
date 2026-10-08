// Contract of the app server's own same-origin JSON endpoints (decision 36).
// The browser decodes these with Effect Schema exactly like the server decodes
// the Edge Functions.

import { Schema } from 'effect';
import { ActivityItem, Allocation, AllocationVersion, WalletNetwork } from './ledger';
import { IdempotencyKey } from './invitations';
import { PIN_PATTERN, Uuid } from './common';
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

export const AppRoutes = {
	split: { method: 'GET', path: '/api/split' },
	saveSplit: { method: 'PUT', path: '/api/split' },
	session: { method: 'GET', path: '/api/session' },
	home: { method: 'GET', path: '/api/home' }
} as const;
