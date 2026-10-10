// Open founder sign-up is withdrawn (Blueprint 19, owner decision 2026-10-10):
// founders apply first. Old links land on the application.
import { redirect } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = () => redirect(308, '/apply');
