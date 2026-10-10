import { Effect } from 'effect';
import { AUDIT_GROUPS, type AuditGroup } from '#lib/contract/admin.js';
import { UID_PATTERN, UUID_PATTERN } from '#lib/contract/common.js';
import { AdminApi } from '#lib/server/apis-admin.js';
import { adminCall, adminPage } from '#lib/server/admin.js';
import type { PageServerLoad } from './$types';

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const CURSOR = /^[A-Za-z0-9+/=]{1,400}$/;

const validDate = (value: string | null): string | null =>
	value && DATE.test(value) && !Number.isNaN(Date.parse(`${value}T00:00:00Z`)) ? value : null;

export const load: PageServerLoad = (event) =>
	adminPage(event, async (session) => {
		const params = event.url.searchParams;
		// Invalid filter values are dropped here so the API never refuses the page.
		const q = (params.get('q') ?? '').trim().slice(0, 100) || null;
		const actorRaw = (params.get('actor') ?? '').trim().toUpperCase();
		const actor = UID_PATTERN.test(actorRaw) ? actorRaw : null;
		const groupRaw = params.get('group') ?? '';
		const group = (AUDIT_GROUPS as readonly string[]).includes(groupRaw)
			? (groupRaw as AuditGroup)
			: null;
		const tenantRaw = (params.get('tenantId') ?? '').toLowerCase();
		const tenantId = UUID_PATTERN.test(tenantRaw) ? tenantRaw : null;
		let from = validDate(params.get('from'));
		let to = validDate(params.get('to'));
		if (from && to && to < from) [from, to] = [to, from];
		const cursorRaw = params.get('cursor');
		const cursor = cursorRaw && CURSOR.test(cursorRaw) ? cursorRaw : null;

		const { page, networkName } = await adminCall(
			event,
			session,
			Effect.gen(function* () {
				const api = yield* AdminApi;
				const page = yield* api.audit({ q, group, actor, tenantId, from, to, cursor });
				const networkName = tenantId
					? (page.items.find((e) => e.tenantId === tenantId)?.network ??
						(yield* api.network(tenantId)).name)
					: null;
				return { page, networkName };
			})
		);

		return {
			title: 'Audit',
			filters: { q, actor, actorRaw, group, tenantId, from, to, cursor },
			networkName,
			items: page.items,
			nextCursor: page.nextCursor
		};
	});
