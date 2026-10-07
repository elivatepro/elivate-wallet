// command_api is a service-only transport schema, excluded from client generated types.
export type CommandClient = Readonly<{
  schema: (name: "command_api") => Readonly<{
    rpc: (
      name: string,
      args: Readonly<Record<string, unknown>>,
    ) => Promise<
      Readonly<{ data: unknown; error: Readonly<{ code?: string }> | null }>
    >;
  }>;
}>;
