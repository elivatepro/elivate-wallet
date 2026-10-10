// Every console page: signed in, PIN verified, platform admin (requireAdmin).
import { requireAdmin } from '#lib/server/admin.js';
import type { LayoutServerLoad } from './$types';

const hm = new Intl.DateTimeFormat('en-GB', {
	hour: '2-digit',
	minute: '2-digit',
	hour12: false,
	timeZone: 'Africa/Lagos'
});

export const load: LayoutServerLoad = async (event) => {
	const { me } = await requireAdmin(event);
	const until = me.stepUpExpiresAt ? new Date(me.stepUpExpiresAt) : null;
	return {
		me: { uid: me.uid, name: me.name },
		stepUpUntil: until && until.getTime() > Date.now() ? hm.format(until) : null
	};
};
