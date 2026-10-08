// `identity` Edge Function contract (Blueprint 06), derived from
// backend/supabase/functions/identity/handler.ts and the api.* identity and
// profile commands. The photo storage key never reaches the browser.

import { Schema } from 'effect';
import { IsoDateTime, Role, Uid, Uuid } from './common';

export const RANKS = [
	'Member',
	'Distributor',
	'Manager',
	'Senior Manager',
	'Executive Manager',
	'Director',
	'Emerald Director',
	'Sapphire Director',
	'Ruby Director 1',
	'Ruby Director 2',
	'Ruby Director 3',
	'Ruby Director 4',
	'Ruby Director 5',
	'Diamond Director'
] as const;
export const Rank = Schema.Literals(RANKS);
export type Rank = typeof Rank.Type;

export const NIN_PATTERN = /^[0-9]{11}$/;
export const PHONE_PATTERN = /^\+?[0-9]{7,15}$/;

export const LegalName = Schema.Struct({
	given: Schema.String,
	middle: Schema.Array(Schema.String),
	surname: Schema.String
});
export type LegalName = typeof LegalName.Type;

export const IdentityState = Schema.Struct({
	status: Schema.Literals(['unverified', 'verified', 'review_pending']),
	method: Schema.NullOr(Schema.Literals(['provider', 'leader_review'])),
	verifiedAt: Schema.NullOr(IsoDateTime),
	legalName: Schema.NullOr(LegalName),
	ninLast4: Schema.NullOr(Schema.String),
	failedChecks: Schema.Int,
	checksRemaining: Schema.Int,
	review: Schema.NullOr(
		Schema.Struct({
			status: Schema.Literals(['pending', 'approved', 'rejected']),
			requestedAt: IsoDateTime,
			decidedAt: Schema.NullOr(IsoDateTime)
		})
	)
});
export type IdentityState = typeof IdentityState.Type;

export const Profile = Schema.Struct({
	uid: Uid,
	displayName: Schema.NullOr(Schema.String),
	firstName: Schema.NullOr(Schema.String),
	lastName: Schema.NullOr(Schema.String),
	phone: Schema.NullOr(Schema.String),
	phoneSource: Schema.NullOr(Schema.Literals(['nin', 'self'])),
	rank: Schema.NullOr(Rank),
	hasPhoto: Schema.Boolean,
	photoUpdatedAt: Schema.NullOr(IsoDateTime),
	identity: IdentityState
});
export type Profile = typeof Profile.Type;

/** Name shown in the app: chosen display name, else the locked first + last name. */
export const shownName = (p: Pick<Profile, 'displayName' | 'firstName' | 'lastName'>) =>
	p.displayName?.trim() || [p.firstName, p.lastName].filter(Boolean).join(' ') || null;

export const PhotoKey = Schema.Struct({ photoKey: Schema.NullOr(Schema.String) });
export const PhotoSet = Schema.Struct({
	photoKey: Schema.String,
	previousPhotoKey: Schema.NullOr(Schema.String)
});

export const NinVerified = Schema.Struct({
	status: Schema.Literal('verified'),
	identity: IdentityState
});

export const ReviewRequested = Schema.Struct({
	reviewId: Uuid,
	status: Schema.Literal('pending'),
	requestedAt: IsoDateTime
});

export const OnboardingWorkspace = Schema.Struct({
	membershipId: Uuid,
	tenantName: Schema.String,
	officeName: Schema.NullOr(Schema.String),
	role: Role
});
export type OnboardingWorkspace = typeof OnboardingWorkspace.Type;

export const PendingReview = Schema.Struct({
	reviewId: Uuid,
	tenantId: Uuid,
	requester: Schema.Struct({ uid: Uid, name: Schema.NullOr(Schema.String) }),
	officeName: Schema.NullOr(Schema.String),
	role: Role,
	ninLast4: Schema.String,
	legalName: LegalName,
	requestedAt: IsoDateTime
});
export type PendingReview = typeof PendingReview.Type;
export const PendingReviews = Schema.Array(PendingReview);

export const ReviewDecided = Schema.Struct({
	reviewId: Uuid,
	status: Schema.Literals(['approved', 'rejected']),
	decidedAt: IsoDateTime
});

export const IdentityRoutes = {
	profile: { method: 'GET', path: '/profile' },
	photoKey: { method: 'GET', path: '/profile/photo-key' },
	updateProfile: { method: 'PATCH', path: '/profile' },
	setPhoto: { method: 'POST', path: '/profile/photo' },
	welcome: { method: 'GET', path: '/onboarding/workspace' },
	verifyNin: { method: 'POST', path: '/nin/verify' },
	requestReview: { method: 'POST', path: '/nin/review' },
	reviews: { method: 'GET', path: '/nin/reviews' }
} as const;

export const decideRoute = (reviewId: string) =>
	({ method: 'POST', path: `/nin/reviews/${reviewId}/decide` }) as const;
