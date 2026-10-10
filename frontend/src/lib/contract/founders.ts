// Founder entry (Blueprint 19): the public application and the founder
// invitation link (`/founder#t=…`), both on the `invitations` Edge Function.
// Derived from backend/supabase/functions/invitations/handler.ts and the
// api.* founder functions (20261009190100_founder_applications.sql).

import { Schema } from 'effect';
import { IdempotencyKey, InvitationToken } from './invitations';

export const FOUNDER_RANKS = ['ruby_director_4', 'ruby_director_5', 'diamond_director'] as const;
export const FounderRank = Schema.Literals(FOUNDER_RANKS);
export type FounderRank = typeof FounderRank.Type;

/** Same rule as the database: digits with an optional +, 7–15 long, once spaces are gone. */
export const FOUNDER_PHONE_PATTERN = /^\+?[0-9]{7,15}$/;
export const EMAIL_PATTERN = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

/** Sent cleaned by the Wallet server: trimmed, email lower-cased, phone without spaces. */
export const FounderApplicationRequest = Schema.Struct({
	fullName: Schema.String.check(Schema.isMinLength(2), Schema.isMaxLength(100)),
	email: Schema.String.check(Schema.isMaxLength(254), Schema.isPattern(EMAIL_PATTERN)),
	phone: Schema.String.check(Schema.isPattern(FOUNDER_PHONE_PATTERN)),
	teamName: Schema.String.check(Schema.isMinLength(2), Schema.isMaxLength(100)),
	rank: FounderRank
});
export type FounderApplicationRequest = typeof FounderApplicationRequest.Type;

/** Always the same reply, stored or not (W-01: no enumeration). */
export const ApplicationReceived = Schema.Struct({ received: Schema.Literal(true) });

export const FounderPreview = Schema.Struct({ email: Schema.String, teamName: Schema.String });
export type FounderPreview = typeof FounderPreview.Type;

export const AcceptFounderRequest = Schema.Struct({
	token: InvitationToken,
	idempotencyKey: IdempotencyKey
});

export const AcceptedFounder = Schema.Struct({
	applicationId: Schema.String,
	founder: Schema.Literal(true)
});

export const FounderRoutes = {
	apply: { method: 'POST', path: '/founder-applications' },
	preview: { method: 'POST', path: '/founder/preview' },
	verifyEmail: { method: 'POST', path: '/founder/verify-email' },
	accept: { method: 'POST', path: '/founder/accept' }
} as const;
