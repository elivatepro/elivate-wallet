// `security` Edge Function contract (plan §6.1), derived from
// backend/supabase/functions/security/handler.ts and the api.* functions on main.

import { Schema } from 'effect';
import { AccountStatus, IsoDateTime, PIN_PATTERN, Uid, Uuid } from './common';

export const Gate = Schema.Literals(['pin_setup_required', 'pin_locked', 'pin_required', 'ready']);
export type Gate = typeof Gate.Type;

export const SecurityState = Schema.Struct({
	gate: Gate,
	uid: Uid,
	accountStatus: AccountStatus,
	attemptsRemaining: Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 5 })),
	stepUpExpiresAt: Schema.NullOr(IsoDateTime)
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
	passwordChanged: { method: 'POST', path: '/password/changed' }
} as const;
