// AdminApi (Blueprint 18): one method per `admin` Edge Function route the
// platform Admin app uses. Every call carries the app-server secret (only
// this server holds it); the database checks the platform-admin role. Reads
// retry at most twice on transient failures; commands never retry (the page
// keeps its idempotency key and resubmits, W-00).

import { Context, Effect, Layer, Schedule, Schema } from 'effect';
import { BackendError, isRetryableRead } from '#lib/contract/errors.js';
import {
	AccountDetail,
	AccountPage,
	AccountStatusRequest,
	ActivateRequest,
	AdminChangeRequest,
	AdminMe,
	AdminRoutes,
	Admins,
	AdvanceRestoreRequest,
	AuditPage,
	CommandResult,
	DeadLetters,
	NetworkDetail,
	NetworkPage,
	NinDecisionRequest,
	NinReviews,
	Overview,
	ReasonRequest,
	RestoreDetail,
	Restores,
	RestoreSource,
	SearchResults,
	SetSwitchRequest,
	SwitchChanged,
	Switches,
	type AuditGroup,
	type NetworkState
} from '#lib/contract/admin.js';
import { AllocationVersions } from '#lib/contract/ledger.js';
import type { AccountStatus } from '#lib/contract/common.js';
import { appServerSecret } from './config';
import { EdgeTransport, type EdgeFailure, type EdgeRoute } from './edge';

const readPolicy = {
	times: 2,
	while: isRetryableRead,
	schedule: Schedule.exponential('200 millis').pipe(Schedule.jittered)
};

const invalid = (field: string) =>
	new BackendError({
		status: 400,
		code: 'validation_error',
		message: 'The request is invalid.',
		retryable: false,
		details: { field },
		requestId: null
	});

/** Without the secret the admin function refuses everything: say so plainly. */
const unconfigured = new BackendError({
	status: 503,
	code: 'internal_error',
	message: 'Admin is not configured on this server.',
	retryable: false,
	details: { reason: 'app_server_secret_missing' },
	requestId: null
});

type Query = Readonly<Record<string, string | null | undefined>>;
const clean = (query: Query): Record<string, string> =>
	Object.fromEntries(
		Object.entries(query).filter(
			(e): e is [string, string] => typeof e[1] === 'string' && e[1] !== ''
		)
	);

export interface AdminApiShape {
	readonly me: Effect.Effect<AdminMe, EdgeFailure>;
	readonly overview: Effect.Effect<Overview, EdgeFailure>;
	readonly search: (q: string) => Effect.Effect<SearchResults, EdgeFailure>;
	readonly networks: (query: {
		q?: string | null;
		state?: NetworkState | null;
		cursor?: string | null;
	}) => Effect.Effect<NetworkPage, EdgeFailure>;
	readonly network: (id: string) => Effect.Effect<NetworkDetail, EdgeFailure>;
	readonly allocationVersions: (
		id: string
	) => Effect.Effect<typeof AllocationVersions.Type, EdgeFailure>;
	readonly activate: (
		id: string,
		input: typeof ActivateRequest.Type
	) => Effect.Effect<typeof CommandResult.Type, EdgeFailure>;
	readonly accounts: (query: {
		q?: string | null;
		status?: AccountStatus | null;
		cursor?: string | null;
	}) => Effect.Effect<AccountPage, EdgeFailure>;
	readonly account: (uid: string) => Effect.Effect<AccountDetail, EdgeFailure>;
	readonly setAccountStatus: (
		uid: string,
		input: typeof AccountStatusRequest.Type
	) => Effect.Effect<typeof CommandResult.Type, EdgeFailure>;
	readonly switches: (tenantId?: string | null) => Effect.Effect<Switches, EdgeFailure>;
	readonly setSwitch: (
		input: typeof SetSwitchRequest.Type
	) => Effect.Effect<typeof SwitchChanged.Type, EdgeFailure>;
	readonly audit: (query: {
		q?: string | null;
		group?: AuditGroup | null;
		actor?: string | null;
		tenantId?: string | null;
		from?: string | null;
		to?: string | null;
		cursor?: string | null;
	}) => Effect.Effect<AuditPage, EdgeFailure>;
	readonly admins: Effect.Effect<typeof Admins.Type, EdgeFailure>;
	readonly grantAdmin: (
		input: typeof AdminChangeRequest.Type
	) => Effect.Effect<typeof CommandResult.Type, EdgeFailure>;
	readonly revokeAdmin: (
		input: typeof AdminChangeRequest.Type
	) => Effect.Effect<typeof CommandResult.Type, EdgeFailure>;
	readonly restores: Effect.Effect<typeof Restores.Type, EdgeFailure>;
	readonly restore: (id: string) => Effect.Effect<RestoreDetail, EdgeFailure>;
	readonly advanceRestore: (
		id: string,
		input: typeof AdvanceRestoreRequest.Type
	) => Effect.Effect<typeof CommandResult.Type, EdgeFailure>;
	readonly restoreSource: (id: string) => Effect.Effect<RestoreSource, EdgeFailure>;
	readonly restoreRows: (
		id: string,
		section: string,
		rows: ReadonlyArray<Record<string, unknown>>
	) => Effect.Effect<typeof CommandResult.Type, EdgeFailure>;
	readonly restoreValidated: (
		id: string,
		report: {
			ok: boolean;
			failReason: string | null;
			sections: ReadonlyArray<{ section: string; rows: number; sha256Ok: boolean }>;
		}
	) => Effect.Effect<typeof CommandResult.Type, EdgeFailure>;
	readonly deadLetters: Effect.Effect<typeof DeadLetters.Type, EdgeFailure>;
	readonly requeue: (
		id: string,
		input: typeof ReasonRequest.Type
	) => Effect.Effect<typeof CommandResult.Type, EdgeFailure>;
	readonly ninReviews: Effect.Effect<typeof NinReviews.Type, EdgeFailure>;
	readonly decideNin: (
		id: string,
		input: typeof NinDecisionRequest.Type
	) => Effect.Effect<typeof CommandResult.Type, EdgeFailure>;
}

export class AdminApi extends Context.Service<AdminApi, AdminApiShape>()('AdminApi') {}

export const AdminApiLive = Layer.effect(
	AdminApi,
	Effect.gen(function* () {
		const edge = yield* EdgeTransport;
		const secret = appServerSecret();

		const read = <S extends Schema.ConstraintDecoder<unknown>>(
			route: EdgeRoute,
			schema: S,
			query: Query = {}
		) =>
			secret
				? edge
						.call({ fn: 'admin', route, query: clean(query), appServerSecret: secret }, schema)
						.pipe(Effect.retry(readPolicy))
				: Effect.fail(unconfigured);

		const command = <S extends Schema.ConstraintDecoder<unknown>>(
			route: EdgeRoute,
			body: unknown,
			schema: S
		) =>
			secret
				? edge.call({ fn: 'admin', route, body, appServerSecret: secret }, schema)
				: Effect.fail(unconfigured);

		/** Validates a request body locally before it is sent (same rules as the Edge). */
		const checked = <I, A>(
			schema: Schema.Codec<A, I>,
			input: unknown,
			field = 'body'
		): Effect.Effect<A, BackendError> =>
			Schema.is(schema)(input) ? Effect.succeed(input as A) : Effect.fail(invalid(field));

		return {
			me: read(AdminRoutes.me, AdminMe),
			overview: read(AdminRoutes.overview, Overview),
			search: (q) => read(AdminRoutes.search, SearchResults, { q }),
			networks: (query) => read(AdminRoutes.tenants, NetworkPage, query),
			network: (id) => read(AdminRoutes.tenant(id), NetworkDetail),
			allocationVersions: (id) => read(AdminRoutes.allocationVersions(id), AllocationVersions),
			activate: (id, input) =>
				checked(ActivateRequest, input, 'reason').pipe(
					Effect.flatMap((body) => command(AdminRoutes.activate(id), body, CommandResult))
				),
			accounts: (query) => read(AdminRoutes.accounts, AccountPage, query),
			account: (uid) => read(AdminRoutes.account(uid), AccountDetail),
			setAccountStatus: (uid, input) =>
				checked(AccountStatusRequest, input, 'reason').pipe(
					Effect.flatMap((body) => command(AdminRoutes.accountStatus(uid), body, CommandResult))
				),
			switches: (tenantId) => read(AdminRoutes.switches, Switches, tenantId ? { tenantId } : {}),
			setSwitch: (input) =>
				checked(SetSwitchRequest, input, 'reason').pipe(
					Effect.flatMap((body) => command(AdminRoutes.setSwitch, body, SwitchChanged))
				),
			audit: (query) => read(AdminRoutes.audit, AuditPage, query),
			admins: read(AdminRoutes.admins, Admins),
			grantAdmin: (input) =>
				checked(AdminChangeRequest, input, 'targetUid').pipe(
					Effect.flatMap((body) => command(AdminRoutes.grantAdmin, body, CommandResult))
				),
			revokeAdmin: (input) =>
				checked(AdminChangeRequest, input, 'targetUid').pipe(
					Effect.flatMap((body) => command(AdminRoutes.revokeAdmin, body, CommandResult))
				),
			restores: read(AdminRoutes.restores, Restores),
			restore: (id) => read(AdminRoutes.restore(id), RestoreDetail),
			advanceRestore: (id, input) =>
				checked(AdvanceRestoreRequest, input, 'reason').pipe(
					Effect.flatMap((body) => command(AdminRoutes.advanceRestore(id), body, CommandResult))
				),
			restoreSource: (id) => command(AdminRoutes.restoreSource(id), {}, RestoreSource),
			restoreRows: (id, section, rows) =>
				command(AdminRoutes.restoreRows(id), { section, rows }, CommandResult),
			restoreValidated: (id, report) =>
				command(AdminRoutes.restoreValidated(id), report, CommandResult),
			deadLetters: read(AdminRoutes.outbox, DeadLetters, { limit: '100' }),
			requeue: (id, input) =>
				checked(ReasonRequest, input, 'reason').pipe(
					Effect.flatMap((body) => command(AdminRoutes.requeue(id), body, CommandResult))
				),
			ninReviews: read(AdminRoutes.ninReviews, NinReviews),
			decideNin: (id, input) =>
				checked(NinDecisionRequest, input, 'reason').pipe(
					Effect.flatMap((body) => command(AdminRoutes.decideNin(id), body, CommandResult))
				)
		} satisfies AdminApiShape;
	})
);
