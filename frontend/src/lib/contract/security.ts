// `security` Edge Function contract (plan §6.1), derived from
// backend/supabase/functions/security/handler.ts and the api.* functions on main.

import { Schema } from 'effect';
import { AccountStatus, IsoDateTime, PIN_PATTERN, Uid, Uuid } from './common';
import { Capabilities, Workspace } from './org';

export const Gate = Schema.Literals([
	'pin_setup_required',
	'pin_locked',
	'pin_required',
	// Blueprint 22: the PIN is fine but the setup for the person's role is not.
	'profile_required',
	'ready'
]);
export type Gate = typeof Gate.Type;

/** Blueprint 22: the setup the person owes (identity.setup_state). */
export const SetupLevel = Schema.Literals(['wallet', 'light', 'none']);
export type SetupLevel = typeof SetupLevel.Type;
export const SetupStep = Schema.Literals(['identity', 'profile', 'bank']);
export type SetupStep = typeof SetupStep.Type;
export const Setup = Schema.Struct({
	level: SetupLevel,
	next: Schema.NullOr(SetupStep),
	/** The membership the bank step uses; null below the wallet level. */
	walletMembershipId: Schema.NullOr(Uuid)
});
export type Setup = typeof Setup.Type;

export const SecurityState = Schema.Struct({
	gate: Gate,
	uid: Uid,
	accountStatus: AccountStatus,
	attemptsRemaining: Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 5 })),
	stepUpExpiresAt: Schema.NullOr(IsoDateTime),
	setup: Schema.optional(Setup)
});
export type SecurityState = typeof SecurityState.Type;

export const PinResetRequested = Schema.Struct({ expiresAt: IsoDateTime });
export type PinResetRequested = typeof PinResetRequested.Type;

export const SessionSummary = Schema.Struct({
	sessionId: Uuid,
	createdAt: IsoDateTime,
	lastActiveAt: Schema.NullOr(IsoDateTime),
	userAgent: Schema.NullOr(Schema.String),
	current: Schema.Boolean,
	// Blueprint 14: approximate location from the sign-in (never the IP).
	city: Schema.NullOr(Schema.String),
	country: Schema.NullOr(Schema.String),
	/** Why this session's sign-in was unusual; empty when it wasn't. */
	reasons: Schema.Array(Schema.Literals(['new_location', 'new_device']))
});
export const Sessions = Schema.Array(SessionSummary);

/** Blueprint 14: how the app server signed this session in. */
export const SignInMethod = Schema.Literals(['password', 'email_link', 'recovery', 'sign_up']);
export type SignInMethod = typeof SignInMethod.Type;

export const SignInRecorded = Schema.Struct({ unusual: Schema.Boolean });

export const UnusualSignIn = Schema.Struct({
	signInId: Uuid,
	signedInAt: IsoDateTime,
	device: Schema.String,
	city: Schema.NullOr(Schema.String),
	country: Schema.NullOr(Schema.String),
	reasons: Schema.Array(Schema.Literals(['new_location', 'new_device'])),
	current: Schema.Boolean,
	signedIn: Schema.Boolean
});
export type UnusualSignIn = typeof UnusualSignIn.Type;

/** GET /overview (Paper B09, Z07): last password change and unusual sign-ins. */
export const SecurityOverview = Schema.Struct({
	passwordChangedAt: Schema.NullOr(IsoDateTime),
	unusualSignIns: Schema.Array(UnusualSignIn)
});
export type SecurityOverview = typeof SecurityOverview.Type;

export const PasswordChangeAuthorized = Schema.Struct({ changeId: Uuid });
export const PasswordChanged = Schema.Struct({ changedAt: IsoDateTime });
export type PasswordChanged = typeof PasswordChanged.Type;

export const Revoked = Schema.Struct({ revoked: Schema.Int });

/** Request shapes. Encoded locally with the same rules the Edge applies. */
export const Pin = Schema.String.check(Schema.isPattern(PIN_PATTERN));

/** `pinConfirm` must also equal `pin` (checked in server/apis.ts validate()). */
export const PinSetRequest = Schema.Struct({ pin: Pin, pinConfirm: Pin });
export const PinVerifyRequest = Schema.Struct({ pin: Pin });

/** Routes the app uses, with method + path exactly as the handler matches them. */
export const SecurityRoutes = {
	state: { method: 'GET', path: '/state' },
	pinSet: { method: 'POST', path: '/pin/set' },
	pinVerify: { method: 'POST', path: '/pin/verify' },
	pinResetRequest: { method: 'POST', path: '/pin/reset/request' },
	pinResetComplete: { method: 'POST', path: '/pin/reset/complete' },
	sessions: { method: 'GET', path: '/sessions' },
	sessionsRevoke: { method: 'POST', path: '/sessions/revoke' },
	// Blueprint 10.
	pinChange: { method: 'POST', path: '/pin/change' },
	// Blueprint 14.
	signIns: { method: 'POST', path: '/sign-ins' },
	overview: { method: 'GET', path: '/overview' },
	passwordAuthorize: { method: 'POST', path: '/password/authorize' },
	passwordChanged: { method: 'POST', path: '/password/changed' },
	// Blueprint 20 (X-Membership optional).
	bootstrap: { method: 'GET', path: '/bootstrap' }
} as const;

/**
 * GET /security/bootstrap (Blueprint 20, api.app_bootstrap): opening the app
 * in one read. Before the PIN gate is ready only `state` is filled. The
 * profile (GET /identity/profile's shape) and the brand are niceties: the app
 * server decodes them on their own and drops them on any mismatch, as it did
 * when they were separate reads.
 */
export const AppBootstrap = Schema.Struct({
	state: SecurityState,
	profile: Schema.Unknown,
	workspace: Schema.NullOr(Workspace),
	capabilities: Schema.NullOr(Capabilities),
	brand: Schema.Unknown
});
export type AppBootstrap = typeof AppBootstrap.Type;
