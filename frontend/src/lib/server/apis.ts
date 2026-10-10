// SecurityApi and OrgApi (plan §5.2): one method per route the app uses. Each
// method validates its input with the contract schema before dispatch and
// decodes the response. Reads retry at most twice on transient failures; PIN
// commands never retry (each attempt counts, Blueprint 01 B4).

import { Context, Effect, Layer, Schedule, Schema } from 'effect';
import { BackendError, isRetryableRead } from '#lib/contract/errors.js';
import {
	AcceptedInvitation,
	AcceptInvitationRequest,
	CreatedInvitation,
	CreateInvitationRequest,
	IdempotencyKey,
	InvitationPage,
	InviteEmail,
	InvitationPreview,
	InvitationRoutes,
	InvitationTokenRequest,
	MyInvitations,
	ReissuedInvitation,
	ReissueInvitationRequest,
	Reason,
	RevokedInvitation,
	RevokeInvitationRequest,
	VerificationSent,
	type InvitationStatus,
	type MyInvitation
} from '#lib/contract/invitations.js';
import {
	Capabilities,
	Offices,
	OrgRoutes,
	StoppedOperations,
	Workspaces,
	type Workspace
} from '#lib/contract/org.js';
import {
	AppBootstrap,
	Pin,
	PinResetRequested,
	PinSetRequest,
	PinVerifyRequest,
	PasswordChangeAuthorized,
	PasswordChanged,
	Revoked,
	SecurityOverview,
	SecurityRoutes,
	Sessions,
	SecurityState,
	SignInRecorded,
	type SignInMethod
} from '#lib/contract/security.js';
import { Role, Uuid } from '#lib/contract/common.js';
import { EdgeTransport, type EdgeFailure } from './edge';

const readPolicy = {
	times: 2,
	while: isRetryableRead,
	schedule: Schedule.exponential('200 millis').pipe(Schedule.jittered)
};

/** Local validation failure, shaped exactly like the Edge's own `validation_error`. */
const localValidation = (field: string, reason?: string) =>
	new BackendError({
		status: 400,
		code: 'validation_error',
		message: 'The request is invalid.',
		retryable: false,
		details: reason ? { field, reason } : { field },
		requestId: null
	});

/** Same order and rules as _shared/validate.ts matchingPins()/pin(). */
export function validate<S extends typeof PinSetRequest | typeof PinVerifyRequest>(
	schema: S,
	input: { pin: string; pinConfirm?: string }
): Effect.Effect<S['Type'], BackendError> {
	if (!Schema.is(Pin)(input.pin)) return Effect.fail(localValidation('pin'));
	if (schema === PinVerifyRequest) return Effect.succeed({ pin: input.pin } as S['Type']);
	if (!Schema.is(Pin)(input.pinConfirm)) return Effect.fail(localValidation('pinConfirm'));
	if (input.pinConfirm !== input.pin) {
		return Effect.fail(localValidation('pinConfirm', 'mismatch'));
	}
	return Effect.succeed({ pin: input.pin, pinConfirm: input.pinConfirm } as S['Type']);
}

export interface SecurityApiShape {
	readonly state: Effect.Effect<SecurityState, EdgeFailure>;
	/** Blueprint 20: state, profile, workspace, capabilities and brand in one read. */
	readonly bootstrap: (membershipId: string | null) => Effect.Effect<AppBootstrap, EdgeFailure>;
	readonly setPin: (input: {
		pin: string;
		pinConfirm: string;
	}) => Effect.Effect<SecurityState, EdgeFailure>;
	readonly verifyPin: (input: { pin: string }) => Effect.Effect<SecurityState, EdgeFailure>;
	readonly requestPinReset: Effect.Effect<PinResetRequested, EdgeFailure>;
	readonly completePinReset: (input: {
		pin: string;
		pinConfirm: string;
	}) => Effect.Effect<SecurityState, EdgeFailure>;
	/** Blueprint 10: signed-in devices, signing them out, changing the PIN. */
	readonly sessions: Effect.Effect<typeof Sessions.Type, EdgeFailure>;
	readonly revokeSessions: (
		input: { sessionId: string } | { allOthers: true }
	) => Effect.Effect<typeof Revoked.Type, EdgeFailure>;
	/** Never retried: a wrong current PIN counts against the 5 attempts. */
	readonly changePin: (input: {
		currentPin: string;
		pin: string;
		pinConfirm: string;
	}) => Effect.Effect<SecurityState, EdgeFailure>;
	/** Blueprint 14: record a new Auth session (before the PIN). Never retried. */
	readonly recordSignIn: (
		input: {
			method: SignInMethod;
			ip: string | null;
			city: string | null;
			country: string | null;
			device: string;
			userAgent: string | null;
		},
		appServerSecret: string
	) => Effect.Effect<typeof SignInRecorded.Type, EdgeFailure>;
	readonly overview: Effect.Effect<SecurityOverview, EdgeFailure>;
	/** Never retried: a wrong PIN counts against the 5 attempts. */
	readonly authorizePasswordChange: (input: {
		pin: string;
	}) => Effect.Effect<typeof PasswordChangeAuthorized.Type, EdgeFailure>;
	readonly recordPasswordChange: (
		input: { changeId: string } | { recovery: true }
	) => Effect.Effect<PasswordChanged, EdgeFailure>;
}

export class SecurityApi extends Context.Service<SecurityApi, SecurityApiShape>()('SecurityApi') {}

export const SecurityApiLive = Layer.effect(
	SecurityApi,
	Effect.gen(function* () {
		const edge = yield* EdgeTransport;
		return {
			state: edge
				.call({ fn: 'security', route: SecurityRoutes.state }, SecurityState)
				.pipe(Effect.retry(readPolicy)),
			bootstrap: (membershipId) =>
				edge
					.call(
						{
							fn: 'security',
							route: SecurityRoutes.bootstrap,
							...(membershipId ? { membershipId } : {})
						},
						AppBootstrap
					)
					.pipe(Effect.retry(readPolicy)),
			setPin: (input) =>
				validate(PinSetRequest, input).pipe(
					Effect.flatMap((body) =>
						edge.call({ fn: 'security', route: SecurityRoutes.pinSet, body }, SecurityState)
					)
				),
			verifyPin: (input) =>
				validate(PinVerifyRequest, input).pipe(
					Effect.flatMap((body) =>
						edge.call({ fn: 'security', route: SecurityRoutes.pinVerify, body }, SecurityState)
					)
				),
			requestPinReset: edge.call(
				{ fn: 'security', route: SecurityRoutes.pinResetRequest, body: {} },
				PinResetRequested
			),
			completePinReset: (input) =>
				validate(PinSetRequest, input).pipe(
					Effect.flatMap((body) =>
						edge.call(
							{ fn: 'security', route: SecurityRoutes.pinResetComplete, body },
							SecurityState
						)
					)
				),
			sessions: edge
				.call({ fn: 'security', route: SecurityRoutes.sessions }, Sessions)
				.pipe(Effect.retry(readPolicy)),
			revokeSessions: (input) =>
				edge.call({ fn: 'security', route: SecurityRoutes.sessionsRevoke, body: input }, Revoked),
			changePin: (input) =>
				(Schema.is(Pin)(input.currentPin)
					? validate(PinSetRequest, { pin: input.pin, pinConfirm: input.pinConfirm })
					: Effect.fail(localValidation('currentPin'))
				).pipe(
					Effect.flatMap((pins) =>
						input.currentPin === pins.pin
							? Effect.fail(localValidation('pin', 'same_pin'))
							: Effect.succeed({ currentPin: input.currentPin, ...pins })
					),
					Effect.flatMap((body) =>
						edge.call({ fn: 'security', route: SecurityRoutes.pinChange, body }, SecurityState)
					)
				),
			recordSignIn: (input, appServerSecret) =>
				edge.call(
					{ fn: 'security', route: SecurityRoutes.signIns, body: input, appServerSecret },
					SignInRecorded
				),
			overview: edge
				.call({ fn: 'security', route: SecurityRoutes.overview }, SecurityOverview)
				.pipe(Effect.retry(readPolicy)),
			authorizePasswordChange: (input) =>
				validate(PinVerifyRequest, input).pipe(
					Effect.flatMap((body) =>
						edge.call(
							{ fn: 'security', route: SecurityRoutes.passwordAuthorize, body },
							PasswordChangeAuthorized
						)
					)
				),
			recordPasswordChange: (input) =>
				edge.call(
					{ fn: 'security', route: SecurityRoutes.passwordChanged, body: input },
					PasswordChanged
				)
		};
	})
);

export interface OrgApiShape {
	readonly workspaces: Effect.Effect<ReadonlyArray<Workspace>, EdgeFailure>;
	readonly capabilities: (membershipId: string) => Effect.Effect<Capabilities, EdgeFailure>;
	/** Active offices in the workspace's subtree (first page, up to 100). */
	readonly activeOffices: (membershipId: string) => Effect.Effect<typeof Offices.Type, EdgeFailure>;
	/** Blueprint 18: operations stopped for this workspace's network. */
	readonly stoppedOperations: (
		membershipId: string
	) => Effect.Effect<typeof StoppedOperations.Type, EdgeFailure>;
}

export class OrgApi extends Context.Service<OrgApi, OrgApiShape>()('OrgApi') {}

export const OrgApiLive = Layer.effect(
	OrgApi,
	Effect.gen(function* () {
		const edge = yield* EdgeTransport;
		return {
			workspaces: edge
				.call({ fn: 'org', route: OrgRoutes.workspaces }, Workspaces)
				.pipe(Effect.retry(readPolicy)),
			capabilities: (membershipId) =>
				edge
					.call({ fn: 'org', route: OrgRoutes.capabilities, membershipId }, Capabilities)
					.pipe(Effect.retry(readPolicy)),
			activeOffices: (membershipId) =>
				edge
					.call(
						{
							fn: 'org',
							route: OrgRoutes.offices,
							membershipId,
							query: { status: 'active', limit: '100' }
						},
						Offices
					)
					.pipe(Effect.retry(readPolicy)),
			stoppedOperations: (membershipId) =>
				edge
					.call({ fn: 'org', route: OrgRoutes.operations, membershipId }, StoppedOperations)
					.pipe(Effect.retry(readPolicy))
		};
	})
);

export interface InvitationsApiShape {
	readonly mine: Effect.Effect<ReadonlyArray<MyInvitation>, EdgeFailure>;
	/** Never retried: the caller keeps the idempotency key and resubmits (W-00). */
	readonly accept: (
		input:
			{ invitationId: string; idempotencyKey: string } | { token: string; idempotencyKey: string }
	) => Effect.Effect<AcceptedInvitation, EdgeFailure>;
	/** Public (no session): the email the link is bound to. */
	readonly preview: (token: string) => Effect.Effect<InvitationPreview, EdgeFailure>;
	/** Public (no session): Auth emails that address a sign-in link. Never retried. */
	readonly verifyEmail: (token: string) => Effect.Effect<void, EdgeFailure>;
	/** The leader's invitations in the workspace (newest first). */
	readonly list: (
		membershipId: string,
		query: { status?: InvitationStatus; cursor?: string; limit?: number }
	) => Effect.Effect<InvitationPage, EdgeFailure>;
	/** Commands below are never retried: the caller keeps its idempotency key (W-00). */
	readonly create: (
		membershipId: string,
		input: {
			readonly officeId: string;
			readonly role: string;
			readonly email: string;
			readonly reason?: string;
			readonly idempotencyKey: string;
		}
	) => Effect.Effect<typeof CreatedInvitation.Type, EdgeFailure>;
	readonly reissue: (
		membershipId: string,
		invitationId: string,
		input: { idempotencyKey: string }
	) => Effect.Effect<ReissuedInvitation, EdgeFailure>;
	readonly revoke: (
		membershipId: string,
		invitationId: string,
		input: { reason: string; idempotencyKey: string }
	) => Effect.Effect<RevokedInvitation, EdgeFailure>;
}

/**
 * Decodes a command body locally. On failure the first field (in the given
 * order) that is present-but-invalid, or required-but-missing, is reported
 * exactly like the Edge's own `validation_error`.
 */
const decodeBody = <S extends Schema.ConstraintDecoder<unknown>>(
	schema: S,
	input: Readonly<Record<string, unknown>>,
	fields: ReadonlyArray<readonly [name: string, check: (value: unknown) => boolean]>
): Effect.Effect<S['Type'], BackendError> =>
	Schema.decodeUnknownEffect(schema)(input).pipe(
		Effect.mapError(() => localValidation(fields.find(([n, ok]) => !ok(input[n]))?.[0] ?? 'body'))
	) as Effect.Effect<S['Type'], BackendError>;

const isKey = Schema.is(IdempotencyKey);
const optional = (check: (value: unknown) => boolean) => (value: unknown) =>
	value === undefined || check(value);

const invitationIdOk = (id: string) =>
	Schema.is(Uuid)(id) ? Effect.succeed(id) : Effect.fail(localValidation('invitationId'));

const tokenBody = (token: string) =>
	Schema.decodeUnknownEffect(InvitationTokenRequest)({ token }).pipe(
		Effect.mapError(() => localValidation('token'))
	);

export class InvitationsApi extends Context.Service<InvitationsApi, InvitationsApiShape>()(
	'InvitationsApi'
) {}

export const InvitationsApiLive = Layer.effect(
	InvitationsApi,
	Effect.gen(function* () {
		const edge = yield* EdgeTransport;
		return {
			mine: edge
				.call({ fn: 'invitations', route: InvitationRoutes.mine }, MyInvitations)
				.pipe(Effect.retry(readPolicy)),
			accept: (input) =>
				Schema.decodeUnknownEffect(AcceptInvitationRequest)(input).pipe(
					Effect.mapError(() => localValidation('token' in input ? 'token' : 'invitationId')),
					Effect.flatMap((body) =>
						edge.call(
							{ fn: 'invitations', route: InvitationRoutes.accept, body },
							AcceptedInvitation
						)
					)
				),
			preview: (token) =>
				tokenBody(token).pipe(
					Effect.flatMap((body) =>
						edge.call(
							{ fn: 'invitations', route: InvitationRoutes.preview, body },
							InvitationPreview
						)
					)
				),
			verifyEmail: (token) =>
				tokenBody(token).pipe(
					Effect.flatMap((body) =>
						edge.call(
							{ fn: 'invitations', route: InvitationRoutes.verifyEmail, body },
							VerificationSent
						)
					),
					Effect.asVoid
				),
			list: (membershipId, query) => {
				const params: Record<string, string> = {};
				if (query.status) params.status = query.status;
				if (query.cursor) params.cursor = query.cursor;
				if (query.limit) params.limit = String(query.limit);
				return edge
					.call(
						{ fn: 'invitations', route: InvitationRoutes.list, membershipId, query: params },
						InvitationPage
					)
					.pipe(Effect.retry(readPolicy));
			},
			create: (membershipId, input) =>
				decodeBody(CreateInvitationRequest, input, [
					['officeId', Schema.is(Uuid)],
					['role', Schema.is(Role)],
					['email', Schema.is(InviteEmail)],
					['reason', optional(Schema.is(Reason))],
					['idempotencyKey', isKey]
				]).pipe(
					Effect.flatMap((body) =>
						edge.call(
							{ fn: 'invitations', route: InvitationRoutes.create, body, membershipId },
							CreatedInvitation
						)
					)
				),
			reissue: (membershipId, invitationId, input) =>
				invitationIdOk(invitationId).pipe(
					Effect.andThen(decodeBody(ReissueInvitationRequest, input, [['idempotencyKey', isKey]])),
					Effect.flatMap((body) =>
						edge.call(
							{
								fn: 'invitations',
								route: InvitationRoutes.reissue(invitationId),
								body,
								membershipId
							},
							ReissuedInvitation
						)
					)
				),
			revoke: (membershipId, invitationId, input) =>
				invitationIdOk(invitationId).pipe(
					Effect.andThen(
						decodeBody(RevokeInvitationRequest, input, [
							['reason', Schema.is(Reason)],
							['idempotencyKey', isKey]
						])
					),
					Effect.flatMap((body) =>
						edge.call(
							{
								fn: 'invitations',
								route: InvitationRoutes.revoke(invitationId),
								body,
								membershipId
							},
							RevokedInvitation
						)
					)
				)
		};
	})
);
