// Blueprint 20 B8: answered by scripts/precache-plugin.ts at build time.
declare module 'virtual:ew-precache' {
	/** The shell's `_app/immutable/...` files; null in dev (no client build yet). */
	export const shellFiles: string[] | null;
}
