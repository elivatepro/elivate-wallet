// FoundersApi (Blueprint 19): the public founder application (sent with the
// app-server secret, after Turnstile) and the founder invitation link. Nothing
// here retries a command: the page keeps its idempotency key (W-00).

import { Context, Effect, Layer, Schema } from 'effect';
import { BackendError } from '#lib/contract/errors.js';
import {
	AcceptedFounder,
	AcceptFounderRequest,
	ApplicationReceived,
	FounderApplicationRequest,
	FounderPreview,
	FounderRoutes
} from '#lib/contract/founders.js';
import { InvitationTokenRequest, VerificationSent } from '#lib/contract/invitations.js';
import { appServerSecret } from './config';
import { EdgeTransport, type EdgeFailure } from './edge';

const invalid = (field: string) =>
	new BackendError({
		status: 400,
		code: 'validation_error',
		message: 'The request is invalid.',
		retryable: false,
		details: { field },
		requestId: null
	});

const unconfigured = new BackendError({
	status: 503,
	code: 'internal_error',
	message: 'Applications are not configured on this server.',
	retryable: false,
	details: { reason: 'app_server_secret_missing' },
	requestId: null
});

export interface FoundersApiShape {
	/** Public; the reply never says whether a new application was stored. */
	readonly apply: (input: FounderApplicationRequest) => Effect.Effect<void, EdgeFailure>;
	/** Public: the email the founder link is bound to, and the team name. */
	readonly preview: (token: string) => Effect.Effect<FounderPreview, EdgeFailure>;
	/** Public: Auth emails that address a sign-in link landing on /founder. */
	readonly verifyEmail: (token: string) => Effect.Effect<void, EdgeFailure>;
	readonly accept: (input: {
		token: string;
		idempotencyKey: string;
	}) => Effect.Effect<typeof AcceptedFounder.Type, EdgeFailure>;
}

export class FoundersApi extends Context.Service<FoundersApi, FoundersApiShape>()('FoundersApi') {}

const fields = ['fullName', 'email', 'phone', 'teamName', 'rank'] as const;

export const FoundersApiLive = Layer.effect(
	FoundersApi,
	Effect.gen(function* () {
		const edge = yield* EdgeTransport;
		const tokenBody = (token: string): Effect.Effect<{ token: string }, BackendError> =>
			Schema.is(InvitationTokenRequest)({ token })
				? Effect.succeed({ token })
				: Effect.fail(invalid('token'));
		return {
			apply: (input) => {
				const secret = appServerSecret();
				if (!secret) return Effect.fail(unconfigured);
				if (!Schema.is(FounderApplicationRequest)(input)) {
					const bad = fields.find(
						(f) => !Schema.is(FounderApplicationRequest.fields[f])(input[f])
					);
					return Effect.fail(invalid(bad ?? 'body'));
				}
				return edge
					.call(
						{ fn: 'invitations', route: FounderRoutes.apply, body: input, appServerSecret: secret },
						ApplicationReceived
					)
					.pipe(Effect.asVoid);
			},
			preview: (token) =>
				tokenBody(token).pipe(
					Effect.flatMap((body) =>
						edge.call({ fn: 'invitations', route: FounderRoutes.preview, body }, FounderPreview)
					)
				),
			verifyEmail: (token) =>
				tokenBody(token).pipe(
					Effect.flatMap((body) =>
						edge.call(
							{ fn: 'invitations', route: FounderRoutes.verifyEmail, body },
							VerificationSent
						)
					),
					Effect.asVoid
				),
			accept: (input) =>
				Schema.is(AcceptFounderRequest)(input)
					? edge.call(
							{ fn: 'invitations', route: FounderRoutes.accept, body: input },
							AcceptedFounder
						)
					: Effect.fail(invalid('token'))
		};
	})
);
