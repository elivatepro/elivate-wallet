// Shared pieces of the slice 08 money reads (Blueprint 08): the selected
// workspace from the cookie, and the activity query parsed from a same-origin
// URL. Everything is validated here before it reaches the Edge.

import type { RequestEvent } from '@sveltejs/kit';
import { Effect } from 'effect';
import { UUID_PATTERN } from '#lib/contract/common.js';
import { BackendError } from '#lib/contract/errors.js';
import type { ActivityQuery } from '#lib/contract/ledger.js';
import type { Workspace } from '#lib/contract/org.js';
import { OrgApi } from './apis';
import { readWorkspace } from './cookies';

export const workspaceGone = () =>
	new BackendError({
		status: 403,
		code: 'workspace_invalid',
		message: 'Choose one of your active workspaces.',
		retryable: false,
		details: {},
		requestId: null
	});

/** The selected workspace, re-read from the backend (never trusted from the cookie alone). */
export const currentWorkspace = (membershipId: string) =>
	Effect.gen(function* () {
		const workspace = (yield* (yield* OrgApi).workspaces).find(
			(w) => w.membershipId === membershipId
		);
		return workspace ?? (yield* Effect.fail(workspaceGone()));
	}) satisfies Effect.Effect<Workspace, unknown, OrgApi>;

export const workspaceCookie = (event: RequestEvent) => readWorkspace(event.cookies);

const DATE = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;
const TZ = /^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+){0,2}$/;

const RULES: Record<string, (v: string) => boolean> = {
	q: (v) => v.trim().length > 0 && v.length <= 100,
	direction: (v) => v === 'in' || v === 'out',
	currency: (v) => v === 'NGN' || v === 'USD',
	status: (v) => /^[a-z_]{1,30}$/.test(v),
	type: (v) => /^[a-z_]{1,30}$/.test(v),
	pocketId: (v) => UUID_PATTERN.test(v),
	from: (v) => DATE.test(v),
	to: (v) => DATE.test(v),
	tz: (v) => v.length <= 64 && TZ.test(v),
	cursor: (v) => v.length > 0 && v.length <= 500
};

/** Parses the activity filters; returns the offending field name on a bad value. */
export function parseActivityQuery(
	params: URLSearchParams,
	extra: readonly string[] = []
): { query: ActivityQuery } | { invalid: string } {
	const query: Record<string, string> = {};
	for (const [key, value] of params) {
		if (extra.includes(key)) continue;
		const rule = RULES[key];
		if (!rule || !rule(value)) return { invalid: key };
		query[key] = value;
	}
	return { query: query as ActivityQuery };
}
