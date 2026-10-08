import { defineEnvVars } from '@sveltejs/kit/env';

// Server-only configuration. In the hybrid model (decision 36) the browser never
// talks to Supabase, so neither value is public. Both may be absent at build
// time (the prerendered app shell needs neither); the server fails closed when
// a request needs them and they are missing.
const optionalUrl = (value: string | undefined): string | undefined => {
	if (value === undefined || value === '') return undefined;
	const url = new URL(value);
	if (url.protocol !== 'https:' && url.hostname !== '127.0.0.1' && url.hostname !== 'localhost') {
		throw new Error('SUPABASE_URL must use https outside local development');
	}
	return url.origin;
};

export const variables = defineEnvVars({
	SUPABASE_URL: {
		description: 'Supabase project API origin (local: http://127.0.0.1:54321).',
		schema: optionalUrl
	},
	SUPABASE_PUBLISHABLE_KEY: {
		description: 'Supabase publishable (anon) key. Never a secret or service-role key.',
		schema: (value: string | undefined) => (value === '' ? undefined : value)
	}
});
