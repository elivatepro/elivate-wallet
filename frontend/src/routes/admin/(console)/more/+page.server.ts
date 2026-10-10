import { adminPage } from '#lib/server/admin.js';
import type { PageServerLoad } from './$types';

// Blueprint 20 B7: the admin gate runs on this request too (no parent()).
export const load: PageServerLoad = (event) => adminPage(event, async () => ({ title: 'More' }));
