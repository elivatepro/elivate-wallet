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
	current: Schema.Boolean
});
export const Sessions = Schema.Array(SessionSummary);

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
	sessionsRevoke: { method: 'POST', path: '/sessions/revoke' }
} as const;
