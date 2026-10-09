// Profile & security (Blueprint 10): the same-origin endpoints the account
// pages use, and the `security` routes they relay. Account-level, so no
// workspace is involved; the backend still checks the session and PIN gate.

import { Schema } from 'effect';
import { IdempotencyKey } from './invitations';
import { Profile, Rank } from './identity';
import { Pin, Sessions } from './security';
import { Uuid } from './common';

/** GET /api/account: own profile, sign-in email and signed-in devices. */
export const AccountView = Schema.Struct({
	profile: Profile,
	email: Schema.NullOr(Schema.String),
	sessions: Sessions
});
export type AccountView = typeof AccountView.Type;

/** POST /api/account/sessions/revoke: exactly one of the two (Blueprint 01 B4). */
export const RevokeSessionsCommand = Schema.Union([
	Schema.Struct({ sessionId: Uuid }),
	Schema.Struct({ allOthers: Schema.Literal(true) })
]);
export type RevokeSessionsCommand = typeof RevokeSessionsCommand.Type;

/** POST /api/account/pin (S05/S06): current PIN, then the new PIN twice. */
export const ChangePinCommand = Schema.Struct({ currentPin: Pin, pin: Pin, pinConfirm: Pin });
export type ChangePinCommand = typeof ChangePinCommand.Type;

/** PATCH /api/account/profile: the fields Blueprint 06 lets a person edit. */
export const ProfileEditCommand = Schema.Struct({
	displayName: Schema.optionalKey(Schema.NullOr(Schema.String)),
	phone: Schema.optionalKey(Schema.String),
	rank: Schema.optionalKey(Rank),
	idempotencyKey: IdempotencyKey
});
export type ProfileEditCommand = typeof ProfileEditCommand.Type;

export const AccountRoutes = {
	view: { method: 'GET', path: '/api/account' },
	revokeSessions: { method: 'POST', path: '/api/account/sessions/revoke' },
	changePin: { method: 'POST', path: '/api/account/pin' },
	editProfile: { method: 'PATCH', path: '/api/account/profile' }
} as const;
