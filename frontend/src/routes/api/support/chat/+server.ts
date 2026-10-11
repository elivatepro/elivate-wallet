// Support chat (Blueprint 17, W-21; Paper WK01; slice 34): what the browser
// needs to open Elivate's Chatwoot chat, loaded only when someone presses
// Start a chat. The UID is signed for Chatwoot identity validation, so nobody
// can pose as someone else. Slice 34 (owner decision 2026-10-11): support also
// sees the name, email and account context (role, office, network, plan,
// status). Never money, bank details, evidence, PINs or tokens.
import { Effect, Option, Schema } from 'effect';
import type { AppBootstrap } from '#lib/contract/security.js';
import { Profile, shownName } from '#lib/contract/identity.js';
import { Brand } from '#lib/contract/settings.js';
import { SecurityApi } from '#lib/server/apis.js';
import { BillingApi } from '#lib/server/apis-billing.js';
import { chatwootConfig } from '#lib/server/config.js';
import { relayRead } from '#lib/server/money-endpoints.js';
import { ROLE_LABELS } from '#lib/labels.js';
import type { RequestHandler } from './$types';

const decodeProfile = Schema.decodeUnknownOption(Profile);
const decodeBrand = Schema.decodeUnknownOption(Brand);

async function sign(secret: string, value: string): Promise<string> {
	const key = await crypto.subtle.importKey(
		'raw',
		new TextEncoder().encode(secret),
		{ name: 'HMAC', hash: 'SHA-256' },
		false,
		['sign']
	);
	const mac = new Uint8Array(
		await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(value))
	);
	return Array.from(mac, (b) => b.toString(16).padStart(2, '0')).join('');
}

/** The Chatwoot contact attributes support reads (all strings, none secret). */
function chatContext(boot: AppBootstrap, plan: string | null): Record<string, string> {
	const workspace = boot.workspace;
	const context: Record<string, string> = {
		uid: boot.state.uid,
		account_status: boot.state.accountStatus,
		security_gate: boot.state.gate
	};
	if (workspace) {
		context.network_id = workspace.tenantId;
		context.network_status = workspace.tenantStatus;
		context.role = ROLE_LABELS[workspace.role];
		if (workspace.officeName) {
			context.office = workspace.officeType
				? `${workspace.officeName} (${workspace.officeType})`
				: workspace.officeName;
		}
	}
	if (plan) context.plan = plan;
	return context;
}

export const GET: RequestHandler = (event) =>
	relayRead(event, {}, (membershipId) =>
		Effect.gen(function* () {
			const config = chatwootConfig();
			if (!config) return { available: false as const };
			const session = yield* Effect.promise(() => event.locals.session());
			const boot = yield* (yield* SecurityApi).bootstrap(membershipId);
			const brand = Option.getOrNull(decodeBrand(boot.brand));
			const profile = Option.getOrNull(decodeProfile(boot.profile));
			// Billing reads are for the Billing Owner and manage_subscription only:
			// anyone else simply has no plan line (no refused call to log).
			const caps = boot.capabilities;
			const plan =
				caps && (caps.billingOwner || caps.permissions.includes('manage_subscription'))
					? yield* (yield* BillingApi).overview(membershipId).pipe(
							Effect.map((o) => `${o.plan.name} · ${o.status}`),
							// Unreadable just now: say so, so support can tell it from "no access".
							Effect.catch((failure) =>
								Effect.succeed(
									`unavailable (${failure._tag === 'BackendError' ? failure.code : failure._tag})`
								)
							)
						)
					: null;
			const identifierHash = yield* Effect.promise(() => sign(config.hmacToken, boot.state.uid));
			return {
				available: true as const,
				baseUrl: config.baseUrl,
				websiteToken: config.websiteToken,
				identifier: boot.state.uid,
				identifierHash,
				network: brand?.name ?? boot.workspace?.tenantName ?? '',
				name: profile ? shownName(profile) : null,
				email: session?.email ?? null,
				context: chatContext(boot, plan)
			};
		})
	);
