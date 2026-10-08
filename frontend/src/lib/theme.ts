export const THEMES = ['dark', 'light', 'system'] as const;
export type Theme = (typeof THEMES)[number];

/** Dark is the default (P-06). */
export const parseTheme = (value: string | null | undefined): Theme =>
	(THEMES as readonly string[]).includes(value ?? '') ? (value as Theme) : 'dark';
