// Wire envelope (backend _shared/http.ts success()/failure()) and the decoding
// pipeline every response goes through: envelope first, then `data` against the
// route schema. Used by the app server (Edge responses) and by the browser
// (same-origin JSON endpoints, which relay the same envelope).

import { Effect, Schema } from 'effect';
import { BackendError, ContractViolation, ERROR_CODES, TransportError } from './errors';

export const SuccessEnvelope = Schema.Struct({
	ok: Schema.Literal(true),
	data: Schema.Unknown,
	requestId: Schema.String
});

export const FailureBody = Schema.Struct({
	code: Schema.String,
	message: Schema.String,
	retryable: Schema.Boolean,
	details: Schema.Record(Schema.String, Schema.Unknown)
});

export const FailureEnvelope = Schema.Struct({
	ok: Schema.Literal(false),
	error: FailureBody,
	requestId: Schema.String
});

export const Envelope = Schema.Union([SuccessEnvelope, FailureEnvelope]);
export type Envelope = typeof Envelope.Type;

const decodeEnvelopeSync = Schema.decodeUnknownOption(Envelope);

/**
 * Turns an HTTP status + parsed JSON body (or `undefined` when the body was not
 * JSON) into the route's `data`, or a typed failure.
 */
export function decodeResponse<S extends Schema.ConstraintDecoder<unknown>>(
	route: string,
	status: number,
	body: unknown,
	schema: S
): Effect.Effect<S['Type'], BackendError | TransportError | ContractViolation> {
	const envelope = decodeEnvelopeSync(body);
	if (envelope._tag === 'None') {
		return Effect.fail(new TransportError({ reason: 'non_envelope', status }));
	}
	const value = envelope.value;
	if (!value.ok) {
		if (!(ERROR_CODES as readonly string[]).includes(value.error.code)) {
			return Effect.fail(
				new ContractViolation({
					route,
					requestId: value.requestId,
					summary: 'unknown error code'
				})
			);
		}
		return Effect.fail(
			new BackendError({
				status,
				code: value.error.code as BackendError['code'],
				message: value.error.message,
				retryable: value.error.retryable,
				details: value.error.details,
				requestId: value.requestId
			})
		);
	}
	return Schema.decodeUnknownEffect(schema)(value.data).pipe(
		Effect.mapError(
			() =>
				new ContractViolation({
					route,
					requestId: value.requestId,
					summary: 'response data does not match the contract'
				})
		)
	);
}

/** Builds the same envelope shape for responses relayed by the app server. */
export const successBody = (data: unknown, requestId: string) => ({ ok: true as const, data, requestId });

export const failureBody = (error: BackendError) => ({
	ok: false as const,
	error: {
		code: error.code,
		message: error.message,
		retryable: error.retryable,
		details: error.details
	},
	requestId: error.requestId ?? ''
});
